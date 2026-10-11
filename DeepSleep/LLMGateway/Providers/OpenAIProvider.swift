//
//  OpenAIProvider.swift
//  Deep Sleep
//
//  OpenAI Chat Completions 适配层。
//
//  关键点：
//  - Chat endpoint: POST {base}/v1/chat/completions（OpenAI 原生）
//  - Streaming: SSE，data: {…} JSON delta
//  - Quota（按量）：GET {base}/dashboard/billing/credit_grants → { hard_limit_usd, total_granted, total_used, total_available }
//  - Quota（订阅）：GET {base}/v1/organization/costs?start_time=&end_time=
//  - Auth: Authorization: Bearer <key>
//

import Foundation

final class OpenAIProvider: NSObject, LLMProvider, LLMProviderInit {

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
        guard !apiKey.isEmpty else { throw LLMGatewayError.noAPIKey }
        let url = URL(string: "\(baseURL)/dashboard/billing/credit_grants")!
        var req = HTTPRequest(url: url)
        req.headers["Authorization"] = "Bearer \(apiKey)"
        let resp = try await HTTPClient.shared.fetch(req)
        let data = try HTTPClient.ensureSuccess(resp)
        let parsed = try JSONDecoder().decode(CreditGrants.self, from: data)
        return [QuotaWindow(
            providerId: config.id,
            capturedAt: Date(),
            fiveHourUsed: nil, fiveHourTotal: nil, fiveHourResetAt: nil,
            weeklyUsed: nil, weeklyTotal: nil, weeklyResetAt: nil,
            balanceAmount: parsed.total_available,
            balanceCurrency: "USD",
            windowStatus: .normal
        )]
    }

    func send(_ request: UnifiedRequest, stream: Bool) async throws -> SendResult {
        let body = try encodeChat(request: request, stream: stream)
        var urlReq = HTTPRequest(
            url: URL(string: "\(baseURL)/v1/chat/completions")!,
            method: "POST"
        )
        urlReq.headers["Authorization"] = "Bearer \(apiKey)"
        urlReq.headers["Content-Type"] = "application/json"
        urlReq.body = body

        if stream {
            let (code, s) = try await HTTPClient.shared.stream(urlReq)
            guard (200..<300).contains(code) else {
                throw LLMGatewayError.httpStatus(code, "<stream>")
            }
            return .stream(OpenAIStreamDecoder.stream(from: s))
        } else {
            let resp = try await HTTPClient.shared.fetch(urlReq)
            let data = try HTTPClient.ensureSuccess(resp)
            let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            return .single(convert(decoded))
        }
    }

    func listModels() async throws -> [ModelInfo] {
        return [
            ModelInfo(name: "gpt-4o", displayName: "GPT-4o",
                      contextWindow: 128_000, supportsVision: true, supportsTools: true),
            ModelInfo(name: "gpt-4o-mini", displayName: "GPT-4o mini",
                      contextWindow: 128_000, supportsVision: true, supportsTools: true),
            ModelInfo(name: "o1", displayName: "o1",
                      contextWindow: 200_000, supportsVision: false, supportsTools: true),
            ModelInfo(name: "o1-mini", displayName: "o1 mini",
                      contextWindow: 128_000, supportsVision: false, supportsTools: false),
            ModelInfo(name: "gpt-4-turbo", displayName: "GPT-4 Turbo",
                      contextWindow: 128_000, supportsVision: true, supportsTools: true),
            ModelInfo(name: "gpt-3.5-turbo", displayName: "GPT-3.5 Turbo",
                      contextWindow: 16_385, supportsVision: false, supportsTools: true),
        ]
    }

    // MARK: - 编码

    private func encodeChat(request: UnifiedRequest, stream: Bool) throws -> Data {
        var dict: [String: Any] = [
            "model": request.model,
            "stream": stream,
        ]
        if let sys = request.system {
            dict["messages"] = [
                ["role": "system", "content": sys]
            ] + request.messages.map { encodeMessage($0) }
        } else {
            dict["messages"] = request.messages.map { encodeMessage($0) }
        }
        if let t = request.temperature { dict["temperature"] = t }
        if let p = request.topP { dict["top_p"] = p }
        if let stop = request.stop { dict["stop"] = stop }
        if let tools = request.tools {
            dict["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description as Any,
                        "parameters": tool.inputSchema.mapValues { $0.value },
                    ]
                ] as [String: Any]
            }
        }
        if let choice = request.toolChoice {
            switch choice {
            case .auto: dict["tool_choice"] = "auto"
            case .any: dict["tool_choice"] = "required"
            case .tool(let name):
                dict["tool_choice"] = ["type": "function", "function": ["name": name]]
            }
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    private func encodeMessage(_ m: UnifiedMessage) -> [String: Any] {
        // 简化：合并所有 text 段；图片/工具忽略（OpenAI 格式略复杂，按需扩展）。
        let texts = m.content.compactMap { c -> String? in
            if case .text(let s) = c { return s } else { return nil }
        }
        let role = m.role == "system" ? "user" : m.role
        return ["role": role, "content": texts.joined(separator: "\n")]
    }

    private func convert(_ r: OpenAIChatResponse) -> UnifiedResponse {
        var content: [UnifiedContent] = []
        for ch in r.choices {
            if let msg = ch.message, let t = msg.content {
                content.append(.text(t))
            }
            if let toolCalls = ch.message?.tool_calls {
                for tc in toolCalls {
                    let args: [String: AnyCodable] = {
                        guard let data = tc.function.arguments.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            return [:]
                        }
                        return obj.mapValues { AnyCodable($0) }
                    }()
                    content.append(.toolUse(id: tc.id, name: tc.function.name, input: args))
                }
            }
        }
        return UnifiedResponse(
            id: r.id,
            model: r.model,
            stopReason: r.choices.first?.finish_reason,
            usage: UnifiedUsage(
                promptTokens: r.usage?.prompt_tokens ?? 0,
                completionTokens: r.usage?.completion_tokens ?? 0
            ),
            content: content
        )
    }
}

// MARK: - Schema

private struct CreditGrants: Codable {
    var hard_limit_usd: Double?
    var total_granted: Double?
    var total_used: Double?
    var total_available: Double?
}

private struct OpenAIChatResponse: Codable {
    var id: String
    var model: String
    var choices: [Choice]
    var usage: Usage?

    struct Usage: Codable {
        var prompt_tokens: Int
        var completion_tokens: Int
        var total_tokens: Int?
    }

    struct Choice: Codable {
        var index: Int
        var message: Message?
        var finish_reason: String?
    }

    struct Message: Codable {
        var role: String
        var content: String?
        var tool_calls: [ToolCall]?
    }

    struct ToolCall: Codable {
        var id: String
        var type: String
        var function: Function
    }

    struct Function: Codable {
        var name: String
        var arguments: String
    }
}

// MARK: - 流式解码

private enum OpenAIStreamDecoder {
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
                            if let data = payload.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                if let choices = json["choices"] as? [[String: Any]],
                                   let first = choices.first,
                                   let delta = first["delta"] as? [String: Any] {
                                    let text = delta["content"] as? String
                                    let finish = first["finish_reason"] as? String
                                    if text != nil || finish != nil {
                                        continuation.yield(UnifiedStreamChunk(
                                            index: nil, deltaText: text,
                                            toolCallDelta: nil, finishReason: finish, usage: nil
                                        ))
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