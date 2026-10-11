//
//  CohereProvider.swift
//  Deep Sleep
//
//  Cohere 适配层。
//
//  关键点：
//  - Chat endpoint: POST {base}/v1/chat（Cohere 原生协议；非 OpenAI 兼容）
//    body: { model, message, chat_history?, preamble?, temperature?, stream? }
//    返回：{ text, generation_id, finish_reason, meta: { tokens: { input_tokens, output_tokens } } }
//  - Streaming: SSE，event: text-generation 等
//  - Quota: GET {base}/v1/billing/usage → { total_dollar_value, total_token_count, ... }
//  - Auth: Bearer (trial 或 *-xxx)
//

import Foundation

final class CohereProvider: NSObject, LLMProvider, LLMProviderInit {

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
        var req = HTTPRequest(url: URL(string: "\(baseURL)/v1/billing/usage")!)
        req.headers["Authorization"] = "Bearer \(apiKey)"
        let resp = try await HTTPClient.shared.fetch(req)
        let data = try HTTPClient.ensureSuccess(resp)
        let parsed = try JSONDecoder().decode(BillingUsage.self, from: data)
        return [QuotaWindow(
            providerId: config.id,
            capturedAt: Date(),
            fiveHourUsed: nil, fiveHourTotal: nil, fiveHourResetAt: nil,
            weeklyUsed: nil, weeklyTotal: nil, weeklyResetAt: nil,
            balanceAmount: parsed.total_dollar_value,
            balanceCurrency: "USD",
            windowStatus: .normal
        )]
    }

    func send(_ request: UnifiedRequest, stream: Bool) async throws -> SendResult {
        let lastUserText: String = {
            // 取最后一条 user 消息的文本作为 message；之前的作为 chat_history
            for m in request.messages.reversed() where m.role == "user" {
                if let t = m.content.compactMap({ c -> String? in
                    if case .text(let s) = c { return s } else { return nil }
                }).first { return t }
            }
            return ""
        }()

        var history: [[String: Any]] = []
        for m in request.messages.dropLast() {
            if m.role == "user" || m.role == "assistant" {
                let texts = m.content.compactMap { c -> String? in
                    if case .text(let s) = c { return s } else { return nil }
                }
                let role = m.role == "user" ? "USER" : "CHATBOT"
                history.append(["role": role, "message": texts.joined(separator: "\n")])
            }
        }

        var dict: [String: Any] = [
            "model": request.model,
            "message": lastUserText,
            "stream": stream,
        ]
        if !history.isEmpty { dict["chat_history"] = history }
        if let sys = request.system { dict["preamble"] = sys }
        if let t = request.temperature { dict["temperature"] = t }
        let body = try JSONSerialization.data(withJSONObject: dict)

        var urlReq = HTTPRequest(url: URL(string: "\(baseURL)/v1/chat")!, method: "POST")
        urlReq.headers["Authorization"] = "Bearer \(apiKey)"
        urlReq.headers["Content-Type"] = "application/json"
        urlReq.body = body

        if stream {
            let (code, s) = try await HTTPClient.shared.stream(urlReq)
            guard (200..<300).contains(code) else {
                throw LLMGatewayError.httpStatus(code, "<stream>")
            }
            return .stream(CohereStreamDecoder.stream(from: s))
        } else {
            let resp = try await HTTPClient.shared.fetch(urlReq)
            let data = try HTTPClient.ensureSuccess(resp)
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            return .single(convert(decoded))
        }
    }

    func listModels() async throws -> [ModelInfo] {
        return [
            ModelInfo(name: "command-r-plus", displayName: "Command R+",
                      contextWindow: 128_000, supportsVision: false, supportsTools: true),
            ModelInfo(name: "command-r", displayName: "Command R",
                      contextWindow: 128_000, supportsVision: false, supportsTools: true),
            ModelInfo(name: "command-light", displayName: "Command Light",
                      contextWindow: 4_000, supportsVision: false, supportsTools: false),
            ModelInfo(name: "command", displayName: "Command",
                      contextWindow: 4_000, supportsVision: false, supportsTools: false),
        ]
    }

    private func convert(_ r: ChatResponse) -> UnifiedResponse {
        let text = r.text ?? ""
        return UnifiedResponse(
            id: r.generation_id ?? UUID().uuidString,
            model: r.model ?? "command",
            stopReason: r.finish_reason,
            usage: UnifiedUsage(
                promptTokens: r.meta?.tokens?.input_tokens ?? 0,
                completionTokens: r.meta?.tokens?.output_tokens ?? 0
            ),
            content: text.isEmpty ? [] : [.text(text)]
        )
    }
}

private struct BillingUsage: Codable {
    var total_dollar_value: Double?
    var total_token_count: Int?
}

private struct ChatResponse: Codable {
    var response_id: String?
    var generation_id: String?
    var text: String?
    var model: String?
    var finish_reason: String?
    var meta: Meta?

    struct Meta: Codable {
        var tokens: Tokens?
    }

    struct Tokens: Codable {
        var input_tokens: Int?
        var output_tokens: Int?
    }
}

private enum CohereStreamDecoder {
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
                                // Cohere SSE：{"event_type":"text-generation","text":"..."}，
                                // {"event_type":"stream-end","finish_reason":"COMPLETE"}
                                if let evt = json["event_type"] as? String {
                                    switch evt {
                                    case "text-generation":
                                        if let t = json["text"] as? String, !t.isEmpty {
                                            continuation.yield(UnifiedStreamChunk(
                                                index: nil, deltaText: t,
                                                toolCallDelta: nil, finishReason: nil, usage: nil
                                            ))
                                        }
                                    case "stream-end":
                                        let finish = json["finish_reason"] as? String
                                        continuation.yield(UnifiedStreamChunk(
                                            index: nil, deltaText: nil,
                                            toolCallDelta: nil, finishReason: finish, usage: nil
                                        ))
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