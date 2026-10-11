//
//  AnthropicProvider.swift
//  Deep Sleep
//
//  Anthropic Claude Messages API 适配层。
//
//  关键点：
//  - Chat endpoint: POST {base}/v1/messages（Anthropic 原生）
//  - Streaming: SSE，event: content_block_delta 等
//  - Quota: Anthropic 暂未对外暴露统一的 quota API；
//    海外 (api.anthropic.com) 需要 OAuth + Admin key 访问 console.anthropic.com 的 /admin/api；
//    国内 (api.anthropic.cn) dashboard /v1/dashboard/usage 走管理 token。
//    没有时返回空数组——让上层用「未配置」UI 兜底，而不是抛错。
//

import Foundation

final class AnthropicProvider: NSObject, LLMProvider, LLMProviderInit {

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

    func fetchQuota() async throws -> [QuotaWindow] {
        guard !apiKey.isEmpty else {
            throw LLMGatewayError.noAPIKey
        }
        let url = URL(string: "\(baseURL)/v1/dashboard/usage")!
        var req = HTTPRequest(url: url)
        req.headers["x-api-key"] = apiKey
        req.headers["anthropic-version"] = "2023-06-01"
        do {
            let resp = try await HTTPClient.shared.fetch(req)
            let data = try HTTPClient.ensureSuccess(resp)
            let parsed = try JSONDecoder().decode(AnthropicDashboardUsage.self, from: data)
            return [parseDashboard(parsed)]
        } catch let e as LLMGatewayError {
            // dashboard 不可用（未配管理 token / 海外区域）→ 不报错，返回空窗口。
            // 上层 UI 会用 .unknown 兜底。
            if case .httpStatus(let code, _) = e, code == 401 || code == 403 {
                return [emptyWindow()]
            }
            throw e
        }
    }

    func send(_ request: UnifiedRequest, stream: Bool) async throws -> SendResult {
        let body = try encodeMessages(request: request, stream: stream)
        var urlReq = HTTPRequest(
            url: URL(string: "\(baseURL)/v1/messages")!,
            method: "POST"
        )
        urlReq.headers["x-api-key"] = apiKey
        urlReq.headers["anthropic-version"] = "2023-06-01"
        urlReq.headers["content-type"] = "application/json"
        urlReq.body = body

        if stream {
            let (code, s) = try await HTTPClient.shared.stream(urlReq)
            guard (200..<300).contains(code) else {
                // 对错误体再 fetch 一次读 body
                let altReq = HTTPRequest(url: urlReq.url, method: "POST", headers: urlReq.headers, body: urlReq.body)
                let r = try await HTTPClient.shared.fetch(altReq)
                _ = try HTTPClient.ensureSuccess(r)
                throw LLMGatewayError.httpStatus(code, "<stream>")
            }
            return .stream(AnthropicStreamDecoder.stream(from: s))
        } else {
            let resp = try await HTTPClient.shared.fetch(urlReq)
            let data = try HTTPClient.ensureSuccess(resp)
            let decoded = try JSONDecoder().decode(AnthropicMessage.self, from: data)
            return .single(convert(decoded))
        }
    }

    func listModels() async throws -> [ModelInfo] {
        return [
            ModelInfo(name: "claude-3-5-sonnet-20241022",
                      displayName: "Claude 3.5 Sonnet",
                      contextWindow: 200_000,
                      supportsVision: true,
                      supportsTools: true),
            ModelInfo(name: "claude-3-5-haiku-20241022",
                      displayName: "Claude 3.5 Haiku",
                      contextWindow: 200_000,
                      supportsVision: false,
                      supportsTools: true),
            ModelInfo(name: "claude-3-opus-20240229",
                      displayName: "Claude 3 Opus",
                      contextWindow: 200_000,
                      supportsVision: true,
                      supportsTools: true),
        ]
    }

    // MARK: - 内部

    private func emptyWindow() -> QuotaWindow {
        QuotaWindow(
            providerId: config.id,
            capturedAt: Date(),
            fiveHourUsed: nil, fiveHourTotal: nil, fiveHourResetAt: nil,
            weeklyUsed: nil, weeklyTotal: nil, weeklyResetAt: nil,
            balanceAmount: nil, balanceCurrency: nil,
            windowStatus: .unknown
        )
    }

    private func parseDashboard(_ d: AnthropicDashboardUsage) -> QuotaWindow {
        // Anthropic dashboard 返回的字段没有统一规范；保守解析。
        return QuotaWindow(
            providerId: config.id,
            capturedAt: Date(),
            fiveHourUsed: d.fiveHourUsed,
            fiveHourTotal: d.fiveHourTotal,
            fiveHourResetAt: d.fiveHourResetAt,
            weeklyUsed: d.weeklyUsed,
            weeklyTotal: d.weeklyTotal,
            weeklyResetAt: d.weeklyResetAt,
            balanceAmount: d.balance,
            balanceCurrency: d.currency,
            windowStatus: .normal
        )
    }

    // MARK: - 编码

    private func encodeMessages(request: UnifiedRequest, stream: Bool) throws -> Data {
        var dict: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "messages": encodeMessagesTo(request.messages),
            "stream": stream,
        ]
        if let sys = request.system { dict["system"] = sys }
        if let t = request.temperature { dict["temperature"] = t }
        if let p = request.topP { dict["top_p"] = p }
        if let tools = request.tools {
            dict["tools"] = tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description as Any,
                    "input_schema": tool.inputSchema.mapValues { $0.value },
                ] as [String: Any]
            }
        }
        if let choice = request.toolChoice {
            switch choice {
            case .auto: dict["tool_choice"] = ["type": "auto"]
            case .any: dict["tool_choice"] = ["type": "any"]
            case .tool(let name): dict["tool_choice"] = ["type": "tool", "name": name]
            }
        }
        if let stop = request.stop { dict["stop_sequences"] = stop }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    private func encodeMessagesTo(_ msgs: [UnifiedMessage]) -> [[String: Any]] {
        msgs.map { m in
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
    }

    private func convert(_ m: AnthropicMessage) -> UnifiedResponse {
        var content: [UnifiedContent] = []
        for c in m.content {
            switch c {
            case .text(let s):
                content.append(.text(s))
            case .toolUse(let id, let name, let input):
                let wrapped = input.mapValues { AnyCodable($0.value) }
                content.append(.toolUse(id: id, name: name, input: wrapped))
            }
        }
        return UnifiedResponse(
            id: m.id,
            model: m.model,
            stopReason: m.stop_reason,
            usage: UnifiedUsage(promptTokens: m.usage.input_tokens,
                                completionTokens: m.usage.output_tokens),
            content: content
        )
    }
}

// MARK: - Anthropic 响应 schema

private struct AnthropicDashboardUsage: Codable {
    var fiveHourUsed: Double?
    var fiveHourTotal: Double?
    var fiveHourResetAt: Date?
    var weeklyUsed: Double?
    var weeklyTotal: Double?
    var weeklyResetAt: Date?
    var balance: Double?
    var currency: String?

    enum CodingKeys: String, CodingKey {
        case fiveHourUsed = "five_hour_used"
        case fiveHourTotal = "five_hour_total"
        case fiveHourResetAt = "five_hour_reset_at"
        case weeklyUsed = "weekly_used"
        case weeklyTotal = "weekly_total"
        case weeklyResetAt = "weekly_reset_at"
        case balance = "balance"
        case currency = "currency"
    }
}

private struct AnthropicMessage: Codable {
    var id: String
    var model: String
    var stop_reason: String?
    var usage: Usage
    var content: [Content]

    struct Usage: Codable {
        var input_tokens: Int
        var output_tokens: Int
    }

    enum Content: Codable {
        case text(String)
        case toolUse(id: String, name: String, input: [String: AnyCodable])

        enum CodingKeys: String, CodingKey { case type, text, id, name, input }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "text":
                let s = try c.decode(String.self, forKey: .text)
                self = .text(s)
            case "tool_use":
                let id = try c.decode(String.self, forKey: .id)
                let name = try c.decode(String.self, forKey: .name)
                let input = try c.decode([String: AnyCodable].self, forKey: .input)
                self = .toolUse(id: id, name: name, input: input)
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                    debugDescription: "unknown Anthropic content type: \(type)")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let s):
                try c.encode("text", forKey: .type)
                try c.encode(s, forKey: .text)
            case .toolUse(let id, let name, let input):
                try c.encode("tool_use", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(name, forKey: .name)
                try c.encode(input, forKey: .input)
            }
        }
    }
}

// MARK: - 流式解码

private enum AnthropicStreamDecoder {
    /// 把字节级 SSE 流转成 UnifiedStreamChunk。
    static func stream(from bytes: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<UnifiedStreamChunk, Error> {
        AsyncThrowingStream<UnifiedStreamChunk, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty { continue }
                        if trimmed.hasPrefix("data:") {
                            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" { continuation.finish(); return }
                            // 简化：忽略流式中的 tool-use delta；只发文本。
                            if let data = payload.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                if let type = json["type"] as? String {
                                    switch type {
                                    case "content_block_delta":
                                        if let delta = json["delta"] as? [String: Any],
                                           let text = delta["text"] as? String {
                                            continuation.yield(UnifiedStreamChunk(index: nil, deltaText: text,
                                                                                  toolCallDelta: nil,
                                                                                  finishReason: nil, usage: nil))
                                        }
                                    case "message_delta":
                                        if let delta = json["delta"] as? [String: Any],
                                           let stop = delta["stop_reason"] as? String {
                                            continuation.yield(UnifiedStreamChunk(index: nil, deltaText: nil,
                                                                                  toolCallDelta: nil,
                                                                                  finishReason: stop, usage: nil))
                                        }
                                    default:
                                        continue
                                    }
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension AsyncSequence where Element == Data {
    /// 把字节流切成 UTF-8 行（按 \n 分割）。流式 SSE 友好。
    var lines: AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    var pending = Data()
                    for try await chunk in self {
                        pending.append(chunk)
                        while let idx = pending.firstIndex(of: 0x0A) {
                            let lineData = pending.prefix(upTo: idx)
                            pending = pending.subdata(in: (idx + 1)..<pending.count)
                            if let s = String(data: lineData, encoding: .utf8) {
                                continuation.yield(s)
                            }
                        }
                    }
                    if !pending.isEmpty, let s = String(data: pending, encoding: .utf8) {
                        continuation.yield(s)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}