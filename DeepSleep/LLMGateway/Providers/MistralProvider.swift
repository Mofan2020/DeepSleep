//
//  MistralProvider.swift
//  Deep Sleep
//
//  Mistral AI 适配层（OpenAI 兼容协议）。
//
//  关键点：
//  - Chat endpoint: POST {base}/v1/chat/completions
//  - Quota（按量）: GET {base}/v1/billing/usage?start_date=&end_date=
//  - Quota（订阅）: GET {base}/v1/billing/subscription
//  - Auth: Bearer
//

import Foundation

final class MistralProvider: NSObject, LLMProvider, LLMProviderInit {

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
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let start = fmt.string(from: Date().addingTimeInterval(-30 * 86400))
        let end = fmt.string(from: Date())
        var comps = URLComponents(string: "\(baseURL)/v1/billing/usage")!
        comps.queryItems = [
            URLQueryItem(name: "start_date", value: start),
            URLQueryItem(name: "end_date", value: end),
        ]
        var req = HTTPRequest(url: comps.url!)
        req.headers["Authorization"] = "Bearer \(apiKey)"
        let resp = try await HTTPClient.shared.fetch(req)
        let data = try HTTPClient.ensureSuccess(resp)
        let parsed = try JSONDecoder().decode(UsageResponse.self, from: data)
        return [QuotaWindow(
            providerId: config.id,
            capturedAt: Date(),
            fiveHourUsed: parsed.aggregate_monthly_usage ?? nil,
            fiveHourTotal: nil,
            fiveHourResetAt: nil,
            weeklyUsed: nil, weeklyTotal: nil, weeklyResetAt: nil,
            balanceAmount: parsed.total_amount,
            balanceCurrency: "USD",
            windowStatus: .normal
        )]
    }

    func send(_ request: UnifiedRequest, stream: Bool) async throws -> SendResult {
        var dict: [String: Any] = [
            "model": request.model,
            "stream": stream,
            "messages": request.messages.map { m -> [String: Any] in
                let texts = m.content.compactMap { c -> String? in
                    if case .text(let s) = c { return s } else { return nil }
                }
                return ["role": m.role, "content": texts.joined(separator: "\n")]
            },
        ]
        if let sys = request.system {
            dict["messages"] = [["role": "system", "content": sys]] + (dict["messages"] as? [[String: Any]] ?? [])
        }
        if let t = request.temperature { dict["temperature"] = t }
        let body = try JSONSerialization.data(withJSONObject: dict)

        var urlReq = HTTPRequest(url: URL(string: "\(baseURL)/v1/chat/completions")!, method: "POST")
        urlReq.headers["Authorization"] = "Bearer \(apiKey)"
        urlReq.headers["Content-Type"] = "application/json"
        urlReq.body = body

        if stream {
            let (code, s) = try await HTTPClient.shared.stream(urlReq)
            guard (200..<300).contains(code) else {
                throw LLMGatewayError.httpStatus(code, "<stream>")
            }
            return .stream(MistralStreamDecoder.stream(from: s))
        } else {
            let resp = try await HTTPClient.shared.fetch(urlReq)
            let data = try HTTPClient.ensureSuccess(resp)
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            return .single(convert(decoded))
        }
    }

    func listModels() async throws -> [ModelInfo] {
        return [
            ModelInfo(name: "mistral-large-latest", displayName: "Mistral Large",
                      contextWindow: 128_000, supportsVision: false, supportsTools: true),
            ModelInfo(name: "mistral-medium-latest", displayName: "Mistral Medium",
                      contextWindow: 128_000, supportsVision: false, supportsTools: true),
            ModelInfo(name: "mistral-small-latest", displayName: "Mistral Small",
                      contextWindow: 32_000, supportsVision: false, supportsTools: true),
            ModelInfo(name: "pixtral-12b-2409", displayName: "Pixtral 12B",
                      contextWindow: 128_000, supportsVision: true, supportsTools: false),
        ]
    }

    private func convert(_ r: ChatResponse) -> UnifiedResponse {
        let text = r.choices.first?.message?.content ?? ""
        return UnifiedResponse(
            id: r.id, model: r.model,
            stopReason: r.choices.first?.finish_reason,
            usage: UnifiedUsage(promptTokens: r.usage?.prompt_tokens ?? 0,
                                completionTokens: r.usage?.completion_tokens ?? 0),
            content: [.text(text)]
        )
    }
}

private struct UsageResponse: Codable {
    var aggregate_monthly_usage: Double?
    var total_amount: Double?
    var currency: String?
}

private struct ChatResponse: Codable {
    var id: String
    var model: String
    var choices: [Choice]
    var usage: Usage?

    struct Usage: Codable {
        var prompt_tokens: Int
        var completion_tokens: Int
    }

    struct Choice: Codable {
        var message: Message?
        var finish_reason: String?
    }

    struct Message: Codable {
        var role: String
        var content: String?
    }
}

private enum MistralStreamDecoder {
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
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let choices = json["choices"] as? [[String: Any]],
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