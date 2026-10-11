//
//  QianfanProvider.swift
//  Deep Sleep
//
//  百度千帆适配层（OpenAI 兼容协议）。
//
//  关键点：
//  - Chat endpoint: POST {base}/v2/chat/completions
//  - Quota: GET {base}/v2/charge → { status, message, data: { balance, cash, gift } }
//  - Auth: Bearer
//

import Foundation

final class QianfanProvider: NSObject, LLMProvider, LLMProviderInit {

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
        var req = HTTPRequest(url: URL(string: "\(baseURL)/v2/charge")!)
        req.headers["Authorization"] = "Bearer \(apiKey)"
        let resp = try await HTTPClient.shared.fetch(req)
        let data = try HTTPClient.ensureSuccess(resp)
        let parsed = try JSONDecoder().decode(ChargeResponse.self, from: data)
        let balance = parsed.data?.balance ?? parsed.data?.cash ?? 0
        return [QuotaWindow(
            providerId: config.id,
            capturedAt: Date(),
            fiveHourUsed: nil, fiveHourTotal: nil, fiveHourResetAt: nil,
            weeklyUsed: nil, weeklyTotal: nil, weeklyResetAt: nil,
            balanceAmount: balance,
            balanceCurrency: "CNY",
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

        var urlReq = HTTPRequest(url: URL(string: "\(baseURL)/v2/chat/completions")!, method: "POST")
        urlReq.headers["Authorization"] = "Bearer \(apiKey)"
        urlReq.headers["Content-Type"] = "application/json"
        urlReq.body = body

        if stream {
            let (code, s) = try await HTTPClient.shared.stream(urlReq)
            guard (200..<300).contains(code) else {
                throw LLMGatewayError.httpStatus(code, "<stream>")
            }
            return .stream(QianfanStreamDecoder.stream(from: s))
        } else {
            let resp = try await HTTPClient.shared.fetch(urlReq)
            let data = try HTTPClient.ensureSuccess(resp)
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            return .single(convert(decoded))
        }
    }

    func listModels() async throws -> [ModelInfo] {
        return [
            ModelInfo(name: "ernie-4.5-8k", displayName: "ERNIE 4.5 8K",
                      contextWindow: 8_000, supportsVision: false, supportsTools: true),
            ModelInfo(name: "ernie-4.5-128k", displayName: "ERNIE 4.5 128K",
                      contextWindow: 128_000, supportsVision: false, supportsTools: true),
            ModelInfo(name: "ernie-3.5-128k", displayName: "ERNIE 3.5 128K",
                      contextWindow: 128_000, supportsVision: false, supportsTools: true),
            ModelInfo(name: "ernie-vilg", displayName: "ERNIE-ViLG",
                      contextWindow: 8_000, supportsVision: true, supportsTools: false),
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

private struct ChargeResponse: Codable {
    var status: String?
    var message: String?
    var data: ChargeData?

    struct ChargeData: Codable {
        var balance: Double?
        var cash: Double?
        var gift: Double?
    }
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

private enum QianfanStreamDecoder {
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