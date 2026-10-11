//
//  StreamForwarder.swift
//  Deep Sleep
//
//  字节级 SSE 转发：把上游 AsyncThrowingStream<Data, Error> 解码为
//  UnifiedStreamChunk，并把 chunk 序列化成目标 SSE（OpenAI 风格或 Anthropic 风格）
//  按字节 yield 给下游。
//
//  设计：
//  - 入口统一为 UnifiedStreamChunk——上游字节流由 AnthropicStreamDecoder / OpenAI
//    的解码路径还原；这里只负责 chunk → 输出字节。
//  - 上游断开立即结束下游，不重试、不缓冲：流式响应的超时窗口非常敏感，重试
//    会让客户端把已经在飞的 chunk 误以为是重发，把响应接乱。
//  - 输出严格符合 SSE：`data: <json>\n\n`（每条事件空行结尾）。
//

import Foundation

enum StreamForwarder {

    // MARK: 上游 UnifiedStreamChunk → 下游字节（Anthropic 格式）

    /// 把 OpenAI 风格的 UnifiedStreamChunk 转成 Anthropic SSE 字节流。
    /// 第一条 chunk 之前先发 message_start；最后一条之后发 message_stop。
    static func translateOpenAIToAnthropic(
        _ upstream: AsyncThrowingStream<UnifiedStreamChunk, Error>
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    // 1) 头条 = message_start。
                    try continuation.yield(sse(event: nil,
                        data: jsonObjectToData(makeMessageStart())))

                    var sentText = false
                    var toolIndex = 0
                    var contentBlockIndex = 0
                    var stopReason: String?

                    // OpenAI 风格 chunk：第一个增量必须从空字符串开始（reset 标记），
                    // provider 这里已经处理过——不再额外插入空白 chunk。

                    var firstTextIndex: Int? = nil

                    for try await chunk in upstream {
                        // 文本增量：开一个 content_block_delta。
                        if let delta = chunk.deltaText, !delta.isEmpty {
                            if firstTextIndex == nil {
                                // 开文本块
                                try continuation.yield(sse(event: "content_block_start",
                                    data: jsonObjectToData([
                                        "index": contentBlockIndex,
                                        "type": "content_block_start",
                                        "content_block": ["type": "text", "text": ""],
                                    ])))
                                firstTextIndex = contentBlockIndex
                                contentBlockIndex += 1
                            }
                            try continuation.yield(sse(event: "content_block_delta",
                                data: jsonObjectToData([
                                    "index": firstTextIndex!,
                                    "type": "content_block_delta",
                                    "delta": ["type": "text_delta", "text": delta],
                                ])))
                            sentText = true
                        }

                        // 工具调用增量：每个 tool 一次 tool_use + 后续 input_json_delta。
                        if let tc = chunk.toolCallDelta {
                            // 首条：tool_use content_block_start
                            try continuation.yield(sse(event: "content_block_start",
                                data: jsonObjectToData([
                                    "index": contentBlockIndex,
                                    "type": "content_block_start",
                                    "content_block": [
                                        "type": "tool_use",
                                        "id": tc.id ?? "toolu_\(UUID().uuidString)",
                                        "name": tc.name ?? "",
                                        "input": [:],
                                    ],
                                ])))
                            let currentIndex = contentBlockIndex
                            contentBlockIndex += 1
                            toolIndex += 1
                            _ = toolIndex

                            // input_json_delta
                            if let frag = tc.argumentsFragment, !frag.isEmpty {
                                try continuation.yield(sse(event: "content_block_delta",
                                    data: jsonObjectToData([
                                        "index": currentIndex,
                                        "type": "content_block_delta",
                                        "delta": ["type": "input_json_delta", "partial_json": frag],
                                    ])))
                            }

                            // 关闭这个 content_block
                            try continuation.yield(sse(event: "content_block_stop",
                                data: jsonObjectToData([
                                    "index": currentIndex,
                                    "type": "content_block_stop",
                                ])))
                        }

                        // finish / usage
                        if let fin = chunk.finishReason {
                            stopReason = mapStopReasonToAnthropic(fin)
                        }
                        if let usage = chunk.usage {
                            try continuation.yield(sse(event: "message_delta",
                                data: jsonObjectToData([
                                    "type": "message_delta",
                                    "delta": ["stop_reason": stopReason as Any,
                                              "stop_sequence": NSNull()],
                                    "usage": ["output_tokens": usage.completionTokens],
                                ])))
                        }
                    }

                    // 关闭文本块（如果开了）
                    if let idx = firstTextIndex {
                        try continuation.yield(sse(event: "content_block_stop",
                            data: jsonObjectToData([
                                "index": idx,
                                "type": "content_block_stop",
                            ])))
                    }

                    // message_delta（如果上面 usage 没触发过）
                    if chunkUsageNeverSent(stopReason: stopReason) {
                        try continuation.yield(sse(event: "message_delta",
                            data: jsonObjectToData([
                                "type": "message_delta",
                                "delta": ["stop_reason": stopReason as Any,
                                          "stop_sequence": NSNull()],
                                "usage": ["output_tokens": 0],
                            ])))
                    }

                    // message_stop
                    try continuation.yield(sse(event: "message_stop",
                        data: jsonObjectToData([
                            "type": "message_stop",
                        ])))

                    _ = sentText // silences "never used" if logic shifts
                    continuation.finish()
                } catch {
                    // 上游断开：错误发生时把信息塞进 message_delta（end_turn）
                    // 然后发 message_stop，避免客户端挂死。
                    do {
                        try continuation.yield(sse(event: "message_delta",
                            data: jsonObjectToData([
                                "type": "message_delta",
                                "delta": ["stop_reason": "end_turn",
                                          "stop_sequence": NSNull()],
                                "usage": ["output_tokens": 0],
                            ])))
                        try continuation.yield(sse(event: "message_stop",
                            data: jsonObjectToData(["type": "message_stop"])))
                    } catch {}
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: 上游 UnifiedStreamChunk → 下游字节（OpenAI 格式）

    /// 把 Anthropic 风格的 UnifiedStreamChunk 转成 OpenAI Chat Completions SSE。
    static func translateAnthropicToOpenAI(
        _ upstream: AsyncThrowingStream<UnifiedStreamChunk, Error>
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var toolIndex = 0
                    for try await chunk in upstream {
                        var payload: [String: Any] = [
                            "object": "chat.completion.chunk",
                            "id": "chatcmpl-\(UUID().uuidString.prefix(12))",
                            "model": "gateway",
                            "choices": [
                                [
                                    "index": 0,
                                    "delta": buildOpenAIDelta(chunk: chunk,
                                                              toolIndex: &toolIndex),
                                    "finish_reason": NSNull(),
                                ] as [String: Any],
                            ],
                        ]
                        if let usage = chunk.usage {
                            payload["usage"] = [
                                "prompt_tokens": usage.promptTokens,
                                "completion_tokens": usage.completionTokens,
                                "total_tokens": usage.promptTokens + usage.completionTokens,
                            ]
                        }
                        if let fin = chunk.finishReason {
                            // OpenAI 一般在最后一个 chunk 上把 finish_reason 写进去。
                            var firstChoice = (payload["choices"] as! [[String: Any]])[0]
                            firstChoice["finish_reason"] = mapStopReasonToOpenAI(fin)
                            payload["choices"] = [firstChoice]
                        }
                        let out = "data: \(jsonObjectToString(payload))\n\n".data(using: .utf8) ?? Data()
                        try continuation.yield(out)
                    }
                    // [DONE] 哨兵。
                    let done = "data: [DONE]\n\n".data(using: .utf8) ?? Data()
                    try continuation.yield(done)
                    continuation.finish()
                } catch {
                    // 上游断开：尝试发 finish_reason=stop 后 [DONE]。
                    do {
                        let errPayload: [String: Any] = [
                            "object": "chat.completion.chunk",
                            "id": "chatcmpl-err",
                            "model": "gateway",
                            "choices": [[
                                "index": 0,
                                "delta": [String: Any](),
                                "finish_reason": "stop",
                            ] as [String: Any]],
                        ]
                        try continuation.yield(("data: \(jsonObjectToString(errPayload))\n\n"
                            ).data(using: .utf8) ?? Data())
                        try continuation.yield(("data: [DONE]\n\n").data(using: .utf8) ?? Data())
                    } catch {}
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 辅助

    /// 起始 message_start payload：固定 id + model + 空 usage。
    private static func makeMessageStart() -> [String: Any] {
        return [
            "type": "message_start",
            "message": [
                "id": "msg-\(UUID().uuidString.prefix(20))",
                "type": "message",
                "role": "assistant",
                "content": [],
                "model": "gateway",
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": ["input_tokens": 0, "output_tokens": 0],
            ],
        ]
    }

    private static func buildOpenAIDelta(
        chunk: UnifiedStreamChunk,
        toolIndex: inout Int
    ) -> [String: Any] {
        var delta: [String: Any] = [:]
        if let text = chunk.deltaText, !text.isEmpty {
            delta["content"] = text
        }
        if let tc = chunk.toolCallDelta {
            var call: [String: Any] = [
                "type": "function",
                "index": toolIndex,
            ]
            if let id = tc.id { call["id"] = id }
            if let name = tc.name { call["function"] = ["name": name, "arguments": ""] }
            if let frag = tc.argumentsFragment {
                var fn = (call["function"] as? [String: Any]) ?? [:]
                fn["arguments"] = frag
                call["function"] = fn
            }
            if call["function"] == nil && call["id"] == nil {
                // 没有 id / name，也没有 function：传 arguments 一项即可。
                if let frag = tc.argumentsFragment {
                    call["function"] = ["arguments": frag]
                }
            }
            delta["tool_calls"] = [call]
            toolIndex += 1
        }
        if delta.isEmpty {
            delta["role"] = "assistant"
        }
        return delta
    }

    private static func chunkUsageNeverSent(stopReason: String?) -> Bool {
        // 简化：如果有 stopReason 但没触发 usage，发出占位 message_delta 让
        // 客户端一定能看到 stop_reason。
        return stopReason != nil
    }

    /// 把 chunk 中的 stop_reason 字段映射到 Anthropic 风格。
    private static func mapStopReasonToAnthropic(_ s: String?) -> String? {
        switch s {
        case "stop":            return "end_turn"
        case "length":          return "max_tokens"
        case "tool_calls":      return "tool_use"
        case .some(let s):      return s
        case .none:             return nil
        }
    }

    private static func mapStopReasonToOpenAI(_ s: String?) -> String {
        switch s {
        case "end_turn":        return "stop"
        case "max_tokens":      return "length"
        case "tool_use":        return "tool_calls"
        case .some(let s):      return s
        case .none:             return "stop"
        }
    }

    /// 拼一段 SSE 字节：event: <name>\ndata: <json>\n\n（event 可省）。
    private static func sse(event: String?, data: Data) throws -> Data {
        if Task.isCancelled { throw CancellationError() }
        var out = Data()
        if let event, !event.isEmpty {
            out.append("event: \(event)\n".data(using: .utf8) ?? Data())
        }
        out.append("data: ".data(using: .utf8) ?? Data())
        out.append(data)
        out.append("\n\n".data(using: .utf8) ?? Data())
        return out
    }

    /// 把 dict 序列化成 Data。出问题时用空对象。
    private static func jsonObjectToData(_ obj: [String: Any]) -> Data {
        do {
            return try JSONSerialization.data(
                withJSONObject: obj,
                options: [.fragmentsAllowed]
            )
        } catch {
            return "{}".data(using: .utf8) ?? Data()
        }
    }

    private static func jsonObjectToString(_ obj: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.fragmentsAllowed]
        ), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}
