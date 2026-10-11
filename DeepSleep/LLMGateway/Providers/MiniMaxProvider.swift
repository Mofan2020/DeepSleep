//
//  MiniMaxProvider.swift
//  Deep Sleep
//
//  MiniMax 适配层。基于 MiniMax 官方文档（2026-10-11 拉取）。
//  官方公开的 base URL 只有一套：`https://api.minimax.cn`，
//  其中 Anthropic 兼容路径为 `/anthropic/v1/messages`。
//
//  文档要点：
//  - Auth：Authorization: Bearer <MINIMAX_API_KEY>
//  - 支持模型：MiniMax-M3.1-Flash-Preview / MiniMax-M3 / MiniMax-M2.7 / M2.7-highspeed
//    / M2.5 / M2.5-highspeed / M2.1 / M2.1-highspeed / MiniMax-M2
//    （共 9 个，所有模型都支持工具调用；M3.1 / M3 支持文本+图片+视频+thinking）
//  - max_tokens：M3.1 / M3 推荐 131072，上限 524288；其他推荐 65536，上限 204800
//  - thinking：M3.1 强制开，`output_config.effort` 必填（默认 max）；
//              M3 默认关，省略时不开，传 adaptive 开启；
//              M2 系列强制开且不可关闭
//  - 流式 SSE：content_block_delta 含 thinking_delta 与 text_delta 两种 delta 类型
//  - 错误码：1008 余额不足、2056 M Plan 资源超额、2013 参数错误
//
//  重要约束：
//  - MiniMax **不公开** HTTP quota 查询 endpoint。文档只给出用量查看入口：
//      · 网页：https://platform.minimax.cn/console/usage
//      · CLI：`mmx quota`
//    因此本文件的 fetchQuota() 只返回一条「unknown」窗口，UI 显示提示用户去控制台
//    查看；不发起任何 quota 拉取请求。
//  - M3.1 必须传 `output_config.effort`，否则会返回 400：
//      "model MiniMax-M3.1-Flash-Preview requires adaptive thinking"。
//

import Foundation

final class MiniMaxProvider: NSObject, LLMProvider, LLMProviderInit {

    let platform: LLMPlatform
    let config: ProviderConfig
    let apiKey: String
    let baseURL: String

    init(config: ProviderConfig, apiKey: String, baseURL: String) {
        self.platform = config.platform
        self.config = config
        self.apiKey = apiKey
        self.baseURL = baseURL
        super.init()
    }

    // MARK: - quota

    func fetchQuota() async throws -> [QuotaWindow] {
        // MiniMax 官方不提供 HTTP quota 查询 endpoint。
        // 返回一条 status=unknown 的占位窗口，让 UI 能渲染"用量请到控制台查看"。
        return [QuotaWindow(
            providerId: config.id,
            capturedAt: Date(),
            fiveHourUsed: nil, fiveHourTotal: nil, fiveHourResetAt: nil,
            weeklyUsed: nil, weeklyTotal: nil, weeklyResetAt: nil,
            balanceAmount: nil, balanceCurrency: nil,
            windowStatus: .unknown
        )]
    }

    // MARK: - chat

    func send(_ request: UnifiedRequest, stream: Bool) async throws -> SendResult {
        if apiKey.isEmpty { throw LLMGatewayError.noAPIKey }

        // Anthropic 兼容请求体（content 数组化，thinking + output_config.effort）。
        var dict: [String: Any] = [
            "model": request.model,
            "max_tokens": maxTokensFor(request: request),
            "messages": messagesArray(request.messages),
            "stream": stream,
        ]
        if let sys = request.system { dict["system"] = sys }
        if let t = request.temperature { dict["temperature"] = t }
        if let p = request.topP { dict["top_p"] = p }
        if let tools = request.tools, !tools.isEmpty {
            dict["tools"] = toolsArray(tools)
        }
        if let choice = request.toolChoice {
            dict["tool_choice"] = toolChoiceJSON(choice)
        }

        // 模型特定的 thinking / effort 行为（按官方文档）：
        //   M3.1 强制开 + effort 默认 max（不传会 400）
        //   M3 默认关 + 传 effort 开启
        //   M2 系列强制开且不可关闭
        let modelLower = request.model.lowercased()
        if modelLower.contains("m3.1") {
            dict["thinking"] = ["type": "adaptive"]
            dict["output_config"] = [
                "effort": effortString(request.thinkingEffort) ?? "max"
            ]
        } else if modelLower.contains("m3") {
            if let _ = request.thinkingEffort {
                dict["thinking"] = ["type": "adaptive"]
            }
            if let eff = effortString(request.thinkingEffort) {
                dict["output_config"] = ["effort": eff]
            }
        } else if modelLower.hasPrefix("MiniMax-m2") {
            dict["thinking"] = ["type": "enabled"]
        }

        let body = try JSONSerialization.data(withJSONObject: dict)
        var urlReq = HTTPRequest(
            url: URL(string: "\(baseURL)/anthropic/v1/messages")!,
            method: "POST"
        )
        urlReq.headers["Authorization"] = "Bearer \(apiKey)"
        urlReq.headers["Content-Type"] = "application/json"
        urlReq.headers["x-api-key"] = apiKey  // MiniMax 同时识别 x-api-key
        urlReq.body = body

        if stream {
            let (code, s) = try await HTTPClient.shared.stream(urlReq)
            guard (200..<300).contains(code) else {
                throw LLMGatewayError.httpStatus(code, "<stream>")
            }
            return .stream(MiniMaxAnthropicStreamDecoder.stream(from: s))
        } else {
            let resp = try await HTTPClient.shared.fetch(urlReq)
            let data = try HTTPClient.ensureSuccess(resp)
            let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
            return .single(convert(decoded))
        }
    }

    // MARK: - models

    func listModels() async throws -> [ModelInfo] {
        return MiniMaxProvider.supportedModels
    }

    /// MiniMax 官方文档（2026-10-11 拉取）列出的全部支持模型。
    /// M3.1-Flash-Preview 仅 M Plan / MiniMax Code 提供，但 list 仍返回，
    /// 用普通 API Key 调用会返回 2056 / 1008，由 send 路径自然暴露。
    static let supportedModels: [ModelInfo] = [
        ModelInfo(name: "MiniMax-M3.1-Flash-Preview", displayName: "MiniMax-M3.1-Flash-Preview",
                  contextWindow: 1_000_000, supportsVision: true, supportsTools: true),
        ModelInfo(name: "MiniMax-M3",                displayName: "MiniMax-M3",
                  contextWindow: 1_000_000, supportsVision: true, supportsTools: true),
        ModelInfo(name: "MiniMax-M2.7",        displayName: "MiniMax-M2.7",
                  contextWindow: 204_800, supportsVision: false, supportsTools: true),
        ModelInfo(name: "MiniMax-M2.7-highspeed", displayName: "MiniMax-M2.7-highspeed",
                  contextWindow: 204_800, supportsVision: false, supportsTools: true),
        ModelInfo(name: "MiniMax-M2.5",        displayName: "MiniMax-M2.5",
                  contextWindow: 204_800, supportsVision: false, supportsTools: true),
        ModelInfo(name: "MiniMax-M2.5-highspeed", displayName: "MiniMax-M2.5-highspeed",
                  contextWindow: 204_800, supportsVision: false, supportsTools: true),
        ModelInfo(name: "MiniMax-M2.1",        displayName: "MiniMax-M2.1",
                  contextWindow: 204_800, supportsVision: false, supportsTools: true),
        ModelInfo(name: "MiniMax-M2.1-highspeed", displayName: "MiniMax-M2.1-highspeed",
                  contextWindow: 204_800, supportsVision: false, supportsTools: true),
        ModelInfo(name: "MiniMax-M2",          displayName: "MiniMax-M2",
                  contextWindow: 204_800, supportsVision: false, supportsTools: true),
    ]

    // MARK: - 内部

    /// M3.1 / M3 上限 524288；其他上限 204800。
    private func maxTokensFor(request: UnifiedRequest) -> Int {
        let cap: Int
        if request.model.lowercased().contains("m3") {
            cap = 524_288
        } else {
            cap = 204_800
        }
        return min(max(request.maxTokens, 1), cap)
    }

    private func effortString(_ e: UnifiedRequest.ThinkingEffort?) -> String? {
        guard let e else { return nil }
        switch e {
        case .low:    return "low"
        case .medium: return "medium"
        case .high:   return "high"
        case .xhigh:  return "xhigh"
        case .max:    return "max"
        }
    }

    /// Anthropic 兼容 messages 内容块数组。
    private func messagesArray(_ msgs: [UnifiedMessage]) -> [[String: Any]] {
        return msgs.map { m -> [String: Any] in
            let blocks = m.content.map { c -> [String: Any] in
                switch c {
                case .text(let s):
                    return ["type": "text", "text": s]
                case .imageURL(let url):
                    return ["type": "image", "source": ["type": "url", "url": url]]
                case .imageBase64(let mediaType, let data):
                    return ["type": "image",
                            "source": ["type": "base64",
                                       "media_type": mediaType,
                                       "data": data]]
                case .toolUse(let id, let name, let input):
                    var dict: [String: Any] = [
                        "type": "tool_use",
                        "id": id,
                        "name": name,
                    ]
                    if let json = try? JSONSerialization.data(withJSONObject: input.mapValues { $0.value }),
                       let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
                        dict["input"] = obj
                    } else {
                        dict["input"] = [:]
                    }
                    return dict
                case .toolResult(let toolUseId, let content, let isError):
                    return [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": content,
                        "is_error": isError,
                    ]
                }
            }
            // Anthropic 兼容格式要求 content 是数组；单段也按数组发。
            return ["role": m.role, "content": blocks]
        }
    }

    private func toolsArray(_ tools: [UnifiedTool]) -> [[String: Any]] {
        return tools.map { t in
            return [
                "name": t.name,
                "description": t.description ?? "",
                "input_schema": jsonObject(t.inputSchema.mapValues { $0.value }),
            ]
        }
    }

    private func toolChoiceJSON(_ c: UnifiedToolChoice) -> [String: Any] {
        switch c {
        case .auto:     return ["type": "auto"]
        case .any:      return ["type": "any"]
        case .tool(let name): return ["type": "tool", "name": name]
        }
    }

    private func jsonObject(_ any: Any?) -> Any {
        guard let any else { return NSNull() }
        if JSONSerialization.isValidJSONObject(any) { return any }
        return NSNull()
    }

    private func convert(_ m: MessagesResponse) -> UnifiedResponse {
        var content: [UnifiedContent] = []
        for c in m.content ?? [] {
            switch c.type {
            case "text":
                if let t = c.text { content.append(.text(t)) }
            case "thinking":
                // 非流式响应里的 thinking 块：折叠为可见文本占位，避免丢信息。
                if let t = c.thinking { content.append(.text(t)) }
            case "tool_use":
                if let id = c.id, let name = c.name {
                    let input = (c.input ?? [:]).mapValues { AnyCodable($0) }
                    content.append(.toolUse(id: id, name: name, input: input))
                }
            default:
                break
            }
        }
        return UnifiedResponse(
            id: m.id, model: m.model,
            stopReason: m.stop_reason,
            usage: UnifiedUsage(promptTokens: m.usage?.input_tokens ?? 0,
                                completionTokens: m.usage?.output_tokens ?? 0),
            content: content
        )
    }
}

// MARK: - Schema（非流式响应）

private struct MessagesResponse: Codable {
    var id: String
    var model: String
    var stop_reason: String?
    var usage: Usage?
    var content: [Content]?

    struct Usage: Codable {
        var input_tokens: Int
        var output_tokens: Int
        var cache_creation_input_tokens: Int?
        var cache_read_input_tokens: Int?
    }

    struct Content: Codable {
        var type: String?
        var text: String?
        var thinking: String?
        var id: String?
        var name: String?
        var input: [String: AnyCodable]?
    }
}

// MARK: - 流式解码
//
// MiniMax `/anthropic/v1/messages` 的 SSE 字段名 / 事件顺序与 Anthropic 完全一致，
// 唯一差异是 `content_block_delta` 有 `thinking_delta` 与 `text_delta` 两种类型。
// 这里与 AnthropicProvider 的解码器结构一致，但把 thinking 文本保留到
// UnifiedStreamChunk.thinkingText 字段，让 UI 可选择性展示。

enum MiniMaxAnthropicStreamDecoder {
    static func stream(
        from bytes: AsyncThrowingStream<Data, Error>
    ) -> AsyncThrowingStream<UnifiedStreamChunk, Error> {
        AsyncThrowingStream<UnifiedStreamChunk, Error> { continuation in
            let task = Task {
                do {
                    var pending = Data()
                    for try await chunk in bytes {
                        pending.append(chunk)
                        while let idx = pending.firstIndex(of: 0x0A) {
                            let lineData = pending.prefix(upTo: idx)
                            pending = pending.subdata(in: (idx + 1)..<pending.count)
                            let line = String(data: lineData, encoding: .utf8) ?? ""
                            if let chunk = parseLine(line) {
                                continuation.yield(chunk)
                            }
                        }
                    }
                    if !pending.isEmpty,
                       let s = String(data: pending, encoding: .utf8),
                       let chunk = parseLine(s) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func parseLine(_ raw: String) -> UnifiedStreamChunk? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return nil }
        guard let data = payload.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let type = json["type"] as? String ?? ""

        if type == "content_block_delta",
           let delta = json["delta"] as? [String: Any] {
            let deltaType = delta["type"] as? String ?? ""
            if deltaType == "text_delta", let text = delta["text"] as? String {
                return UnifiedStreamChunk(index: nil, deltaText: text,
                                           thinkingText: nil,
                                           toolCallDelta: nil, finishReason: nil, usage: nil)
            }
            if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String {
                return UnifiedStreamChunk(index: nil, deltaText: nil,
                                           thinkingText: thinking,
                                           toolCallDelta: nil, finishReason: nil, usage: nil)
            }
            if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                return UnifiedStreamChunk(index: nil, deltaText: nil, thinkingText: nil,
                                           toolCallDelta: UnifiedStreamChunk.ToolCallDelta(
                                               index: 0, id: nil,
                                               name: nil,
                                               argumentsFragment: partial),
                                           finishReason: nil, usage: nil)
            }
        }

        if type == "message_delta",
           let delta = json["delta"] as? [String: Any],
           let stop = delta["stop_reason"] as? String {
            return UnifiedStreamChunk(index: nil, deltaText: nil, thinkingText: nil,
                                       toolCallDelta: nil, finishReason: stop,
                                       usage: nil)
        }

        if type == "message_delta",
           let usage = json["usage"] as? [String: Any],
           let output = usage["output_tokens"] as? Int {
            return UnifiedStreamChunk(index: nil, deltaText: nil, thinkingText: nil,
                                       toolCallDelta: nil, finishReason: nil,
                                       usage: UnifiedUsage(promptTokens: 0,
                                                            completionTokens: output))
        }

        return nil
    }
}