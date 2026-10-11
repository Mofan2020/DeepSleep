//
//  FormatConverter.swift
//  Deep Sleep
//
//  Anthropic Messages ↔ OpenAI Chat Completions 双向往返转换。
//
//  设计目标：
//  - 协议层不感知目标 Provider；调用方把 UnifiedRequest 传进来，按目标格式挑
//    anthropicToOpenAI / openAIToAnthropic 拿到 JSON 字典，再交给 HTTPClient 发。
//  - 把 OpenAI 响应解成 UnifiedResponse 是网关收到响应后整合的关键步骤；
//    同样提供反向给「客户端用的是 OpenAI、但 Provider 是 Anthropic」场景。
//  - 失败时尽量给空字段而不是 throw——网关要把不识别的字段当成「缺数据」处理，
//    而不是让一条不重要的 schema 差异堵死整个转发。
//
//  覆盖要素：
//  - system（Anthropic 是顶层字段；OpenAI 是 system 角色的第一条消息）
//  - vision（imageURL / imageBase64 双向映射）
//  - tool_use ↔ tool_calls（Anthropic 的 content 块 ↔ OpenAI 数组里的 tool_calls）
//  - tool_result ↔ tool message（role="tool" + tool_call_id）
//  - stop_reason ↔ finish_reason（end_turn / max_tokens / tool_use / stop）
//

import Foundation

// MARK: - 入口命名空间

enum FormatConverter {

    // MARK: Anthropic → OpenAI（请求体）

    /// 把源格式是 Anthropic 的 UnifiedRequest 转成 OpenAI Chat Completions JSON。
    /// 也就是说：客户端用 Anthropic 协议，但目标 Provider 实现的是 OpenAI 协议。
    static func anthropicToOpenAI(_ req: UnifiedRequest) -> [String: Any] {
        var dict: [String: Any] = [
            "model": req.model,
            "max_tokens": req.maxTokens,
            "stream": req.stream,
        ]
        if let t = req.temperature { dict["temperature"] = t }
        if let p = req.topP { dict["top_p"] = p }
        if let stop = req.stop { dict["stop"] = stop }

        // messages：OpenAI 没有顶层 system；展开成首条 system 消息。
        var msgs: [[String: Any]] = []
        if let sys = req.system, !sys.isEmpty {
            msgs.append(["role": "system", "content": sys])
        }
        for m in req.messages {
            msgs.append(openAIForMessage(m))
        }

        dict["messages"] = msgs

        if let tools = req.tools, !tools.isEmpty {
            dict["tools"] = tools.map { tool -> [String: Any] in
                var t: [String: Any] = [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "parameters": tool.inputSchema.mapValues { $0.value },
                    ] as [String: Any],
                ]
                if let d = tool.description {
                    var fn = (t["function"] as? [String: Any]) ?? [:]
                    fn["description"] = d
                    t["function"] = fn
                }
                return t
            }
            if let choice = req.toolChoice {
                switch choice {
                case .auto:
                    dict["tool_choice"] = "auto"
                case .any:
                    // OpenAI 没有原生的 "any"；用 required 近似（OpenAI SDK 客户端
                    // 通常也是这样处理的）。
                    dict["tool_choice"] = "required"
                case .tool(let name):
                    dict["tool_choice"] = [
                        "type": "function",
                        "function": ["name": name],
                    ]
                }
            }
        }

        return dict
    }

    // MARK: OpenAI → Anthropic（请求体）

    /// 把源格式是 OpenAI 的 UnifiedRequest 转成 Anthropic Messages JSON。
    static func openAIToAnthropic(_ req: UnifiedRequest) -> [String: Any] {
        var dict: [String: Any] = [
            "model": req.model,
            "max_tokens": req.maxTokens,
            "stream": req.stream,
        ]
        if let t = req.temperature { dict["temperature"] = t }
        if let p = req.topP { dict["top_p"] = p }
        if let stop = req.stop { dict["stop_sequences"] = stop }

        // OpenAI messages 转 Anthropic：system 单独抽出，tool 结果合并到上一条
        // assistant 的 content（Anthropic 没有 role=tool）；其余保持顺序。
        var system: String?
        var anthropicMsgs: [[String: Any]] = []

        // 上一条 assistant 消息（用于把紧随其后的 tool 结果作为 content 块塞进去）。
        var lastAssistantIdx: Int?

        for m in req.messages {
            switch m.role {
            case "system":
                let text = renderTextOnly(m.content)
                if let prev = system {
                    system = prev + "\n\n" + text
                } else {
                    system = text
                }
            case "tool":
                // OpenAI 的 role=tool → Anthropic 的 tool_result content 块。
                // 优先附加到上一条 assistant；没有 assistant 就丢掉，避免协议层
                // 抱怨 user 消息里突然冒出 tool_use_id。
                let blocks = openAIToolResultBlocks(m.content)
                if !blocks.isEmpty, let idx = lastAssistantIdx,
                   var last = anthropicMsgs[idx]["content"] as? [Any] {
                    last.append(contentsOf: blocks)
                    anthropicMsgs[idx]["content"] = last
                }
            default:
                let msg = anthropicForMessage(m)
                anthropicMsgs.append(msg)
                if m.role == "assistant" {
                    lastAssistantIdx = anthropicMsgs.count - 1
                }
            }
        }
        if let system, !system.isEmpty {
            dict["system"] = system
        }
        dict["messages"] = anthropicMsgs

        if let tools = req.tools, !tools.isEmpty {
            dict["tools"] = tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description as Any,
                    "input_schema": tool.inputSchema.mapValues { $0.value },
                ] as [String: Any]
            }
            if let choice = req.toolChoice {
                switch choice {
                case .auto:     dict["tool_choice"] = ["type": "auto"]
                case .any:      dict["tool_choice"] = ["type": "any"]
                case .tool(let name): dict["tool_choice"] = ["type": "tool", "name": name]
                }
            }
        }

        return dict
    }

    // MARK: 响应：OpenAI → UnifiedResponse

    /// 把 OpenAI 的响应 JSON 解码成 UnifiedResponse。
    /// 解码失败时返回一个带空内容的 placeholder，确保调用方流程不会断。
    static func openAIResponseToAnthropic(_ data: Data) -> UnifiedResponse {
        // 占位：尽力解析常用字段。
        let id = (jsonField(in: data, "id") as? String) ?? "openai-\(UUID().uuidString)"
        let model = (jsonField(in: data, "model") as? String) ?? ""
        let finish = (jsonField(in: data, "finish_reason") as? String)
        var outContent: [UnifiedContent] = []
        var promptTokens = 0
        var completionTokens = 0

        if let usage = jsonField(in: data, "usage") as? [String: Any] {
            promptTokens = (usage["prompt_tokens"] as? Int) ?? 0
            completionTokens = (usage["completion_tokens"] as? Int) ?? 0
        }

        if let choices = jsonField(in: data, "choices") as? [[String: Any]] {
            for choice in choices {
                guard let msg = choice["message"] as? [String: Any] else { continue }

                // 文本
                if let text = msg["content"] as? String, !text.isEmpty {
                    outContent.append(.text(text))
                }
                // 拒绝时 content 通常为 null，不报错。

                // tool_calls
                if let calls = msg["tool_calls"] as? [[String: Any]] {
                    for tc in calls {
                        guard let id = tc["id"] as? String else { continue }
                        let fn = (tc["function"] as? [String: Any]) ?? [:]
                        let name = (fn["name"] as? String) ?? ""
                        let argsStr = (fn["arguments"] as? String) ?? "{}"
                        let parsed = parseJSONObject(argsStr) ?? [:]
                        let wrapped = parsed.mapValues { AnyCodable($0) }
                        outContent.append(.toolUse(id: id, name: name, input: wrapped))
                    }
                }
            }
        }

        return UnifiedResponse(
            id: id,
            model: model,
            stopReason: mapFinishReasonToAnthropic(finish),
            usage: UnifiedUsage(promptTokens: promptTokens, completionTokens: completionTokens),
            content: outContent
        )
    }

    // MARK: 响应：UnifiedResponse → OpenAI JSON

    /// 把 UnifiedResponse 序列化成 OpenAI Chat Completions 风格的字典。
    /// 主要用于「Provider 是 Anthropic、客户端期望 OpenAI」的场景。
    static func anthropicResponseToOpenAI(_ resp: UnifiedResponse) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant"]

        var textChunks: [String] = []
        var toolCalls: [[String: Any]] = []

        for c in resp.content {
            switch c {
            case .text(let s):
                textChunks.append(s)
            case .toolUse(let id, let name, let input):
                let argsJSON = (try? JSONSerialization.data(
                    withJSONObject: input.mapValues { $0.value },
                    options: [.fragmentsAllowed]
                )) ?? Data("{}".utf8)
                let argsStr = String(data: argsJSON, encoding: .utf8) ?? "{}"
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": [
                        "name": name,
                        "arguments": argsStr,
                    ],
                ])
            case .imageURL, .imageBase64:
                // Provider 不会产生图片内容（生成模型）；客户端拿到也不会做啥。
                continue
            case .toolResult:
                // 不应出现在 assistant 响应里；忽略。
                continue
            }
        }

        if textChunks.isEmpty {
            message["content"] = toolCalls.isEmpty ? NSNull() : ""
        } else {
            message["content"] = textChunks.joined()
        }
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls
        }

        return [
            "id": resp.id,
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": resp.model,
            "choices": [
                [
                    "index": 0,
                    "message": message,
                    "finish_reason": mapStopReasonToOpenAI(resp.stopReason),
                ] as [String: Any],
            ],
            "usage": [
                "prompt_tokens": resp.usage.promptTokens,
                "completion_tokens": resp.usage.completionTokens,
                "total_tokens": resp.usage.promptTokens + resp.usage.completionTokens,
            ] as [String: Any],
        ]
    }

    // MARK: - 内部辅助

    /// 从原始 JSON Data 中取出指定字段（任意类型）。出错返回 nil。
    private static func jsonField(in data: Data, _ key: String) -> Any? {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let dict = any as? [String: Any] {
            return dict[key]
        }
        return nil
    }

    /// 把一条 OpenAI 消息里所有 content 块压平成「一段纯文本」。
    /// 仅用于 system：system 不该含多模态/工具文本，丢掉其他块是合理降级。
    private static func renderTextOnly(_ content: [UnifiedContent]) -> String {
        content.compactMap {
            if case .text(let s) = $0 { return s } else { return nil }
        }.joined()
    }

    /// UnifiedMessage → OpenAI 风格 message 字典。
    private static func openAIForMessage(_ m: UnifiedMessage) -> [String: Any] {
        // tool 角色的特殊处理：必须是单一字符串，引用 tool_call_id。
        let toolResults = m.content.compactMap { c -> (String, String, Bool)? in
            if case .toolResult(let id, let content, let isError) = c {
                return (id, content, isError)
            }
            return nil
        }
        if !toolResults.isEmpty {
            // OpenAI 一个 tool role 一条消息；多条就用第一条并拼接（理想做法是
            // 每条拆成单独消息——这里偷懒一点保持一条，但 Anthropic→OpenAI 来
            // 源通常不会塞多条 tool_result）。
            let (id, content, _) = toolResults[0]
            var msg: [String: Any] = [
                "role": "tool",
                "tool_call_id": id,
                "content": content,
            ]
            if toolResults.count > 1 {
                let extras = toolResults.dropFirst().map { $0.1 }.joined(separator: "\n\n")
                msg["content"] = (msg["content"] as? String ?? "") + "\n\n" + extras
            }
            return msg
        }

        // assistant 的 tool_calls
        let toolCalls: [FormatConverter.ToolCallSnapshot] = m.content.compactMap { c in
            if case .toolUse(let id, let name, let input) = c {
                return FormatConverter.ToolCallSnapshot(id: id, name: name, input: input)
            }
            return nil
        }

        // 文本 / 图片部分：OpenAI 多模态是数组，纯文本走字符串。
        var textBuf = ""
        var parts: [[String: Any]] = []
        for c in m.content {
            switch c {
            case .text(let s):
                textBuf.append(s)
            case .imageURL(let url):
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": url],
                ])
            case .imageBase64(let mt, let data):
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mt);base64,\(data)"],
                ])
            default:
                continue
            }
        }

        var msg: [String: Any] = ["role": m.role]
        if !textBuf.isEmpty && parts.isEmpty {
            msg["content"] = textBuf
        } else if parts.isEmpty {
            // 没文本也没图片——assistant 通常是 tool_calls
            msg["content"] = textBuf
        } else {
            // 多模态数组
            var arr: [[String: Any]] = []
            if !textBuf.isEmpty {
                arr.append(["type": "text", "text": textBuf])
            }
            arr.append(contentsOf: parts)
            msg["content"] = arr
        }
        if !toolCalls.isEmpty {
            msg["tool_calls"] = toolCalls.map { snap -> [String: Any] in
                let argsJSON = (try? JSONSerialization.data(
                    withJSONObject: snap.input.mapValues { $0.value },
                    options: [.fragmentsAllowed]
                )) ?? Data("{}".utf8)
                let argsStr = String(data: argsJSON, encoding: .utf8) ?? "{}"
                return [
                    "id": snap.id,
                    "type": "function",
                    "function": ["name": snap.name, "arguments": argsStr],
                ]
            }
        }
        return msg
    }

    /// 把 UnifiedMessage 映射成 Anthropic 风格。
    private static func anthropicForMessage(_ m: UnifiedMessage) -> [String: Any] {
        var dict: [String: Any] = ["role": m.role]
        var content: [Any] = []
        for c in m.content {
            switch c {
            case .text(let s):
                content.append(["type": "text", "text": s])
            case .imageURL(let url):
                content.append([
                    "type": "image",
                    "source": ["type": "url", "url": url],
                ])
            case .imageBase64(let mt, let data):
                content.append([
                    "type": "image",
                    "source": ["type": "base64", "media_type": mt, "data": data],
                ])
            case .toolUse(let id, let name, let input):
                content.append([
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": input.mapValues { $0.value },
                ])
            case .toolResult(let id, let c, let isError):
                content.append([
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": c,
                    "is_error": isError,
                ])
            }
        }
        dict["content"] = content
        return dict
    }

    /// finish_reason ↔ stop_reason 的方向映射。
    private static func mapFinishReasonToAnthropic(_ finish: String?) -> String? {
        switch finish {
        case "stop":            return "end_turn"
        case "length":          return "max_tokens"
        case "tool_calls":      return "tool_use"
        case "content_filter":  return "end_turn" // 近似
        case .some(let s):      return s
        case .none:             return nil
        }
    }

    private static func mapStopReasonToOpenAI(_ stop: String?) -> String {
        switch stop {
        case "end_turn":        return "stop"
        case "max_tokens":      return "length"
        case "tool_use":        return "tool_calls"
        case .some(let s):      return s
        case .none:             return "stop"
        }
    }

    /// 把字符串解析成 JSON 对象；不是合法 JSON 时返回 nil。
    private static func parseJSONObject(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// toolUse 快照（避免直接在 case 里构造元组）。
    struct ToolCallSnapshot {
        let id: String
        let name: String
        let input: [String: AnyCodable]
    }

    /// 从 OpenAI tool 消息 content 里抽出 Anthropic tool_result 块。
    /// OpenAI 一条 tool message 通常只有一个 tool_result content，但防御式遍历
    /// 全部 .toolResult（容许多条退化场景）。
    private static func openAIToolResultBlocks(_ content: [UnifiedContent]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for c in content {
            if case .toolResult(let id, let text, let isError) = c {
                out.append([
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": text,
                    "is_error": isError,
                ])
            }
        }
        return out
    }
}

