//
//  OllamaProvider.swift
//  Deep Sleep
//
//  Ollama 本地 LLM 适配层（与 OpenAI 兼容但有原生 /api/chat、/api/tags）。
//
//  关键点：
//  - 默认 base = http://127.0.0.1:11434
//  - Chat: POST {base}/api/chat（Ollama 原生 /api/chat，stream=true 时 NDJSON）
//  - Streaming: NDJSON 行，{ "message": { "role": "assistant", "content": "..." }, "done": false }
//  - Quota: 无（本地不消耗）；返回空窗口 .unlimited
//  - listModels: GET {base}/api/tags → { models: [{ name, size, ... }] }
//  - Auth: 无（apiKey 通常为空）
//

import Foundation

final class OllamaProvider: NSObject, LLMProvider, LLMProviderInit {

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
        // 本地：无配额概念
        return [QuotaWindow(
            providerId: config.id,
            capturedAt: Date(),
            fiveHourUsed: nil, fiveHourTotal: nil, fiveHourResetAt: nil,
            weeklyUsed: nil, weeklyTotal: nil, weeklyResetAt: nil,
            balanceAmount: nil, balanceCurrency: nil,
            windowStatus: .unlimited
        )]
    }

    func send(_ request: UnifiedRequest, stream: Bool) async throws -> SendResult {
        let lastUserText: String = {
            for m in request.messages.reversed() where m.role == "user" {
                if let t = m.content.compactMap({ c -> String? in
                    if case .text(let s) = c { return s } else { return nil }
                }).first { return t }
            }
            return ""
        }()

        var dict: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map { m -> [String: Any] in
                let texts = m.content.compactMap { c -> String? in
                    if case .text(let s) = c { return s } else { return nil }
                }
                return ["role": m.role, "content": texts.joined(separator: "\n")]
            },
            "stream": stream,
        ]
        if let sys = request.system {
            dict["system"] = sys
        }
        if let t = request.temperature { dict["options"] = ["temperature": t] }
        _ = lastUserText  // 已在 messages 内传完整对话，不再单独送 message
        let body = try JSONSerialization.data(withJSONObject: dict)

        var urlReq = HTTPRequest(url: URL(string: "\(baseURL)/api/chat")!, method: "POST")
        urlReq.headers["Content-Type"] = "application/json"
        urlReq.body = body

        if stream {
            let (code, s) = try await HTTPClient.shared.stream(urlReq)
            guard (200..<300).contains(code) else {
                throw LLMGatewayError.httpStatus(code, "<stream>")
            }
            return .stream(OllamaStreamDecoder.stream(from: s))
        } else {
            var urlReq2 = urlReq
            urlReq2.headers["Accept"] = "application/json"
            let resp = try await HTTPClient.shared.fetch(urlReq2)
            let data = try HTTPClient.ensureSuccess(resp)
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            return .single(convert(decoded))
        }
    }

    func listModels() async throws -> [ModelInfo] {
        var req = HTTPRequest(url: URL(string: "\(baseURL)/api/tags")!)
        req.headers["Accept"] = "application/json"
        let resp = try await HTTPClient.shared.fetch(req)
        let data = try HTTPClient.ensureSuccess(resp)
        let parsed = try JSONDecoder().decode(TagsResponse.self, from: data)
        return (parsed.models ?? []).map { m in
            ModelInfo(
                name: m.name ?? "unknown",
                displayName: m.name,
                contextWindow: nil,
                supportsVision: m.name?.lowercased().contains("vision") == true
                              || m.name?.lowercased().contains("llava") == true
                              || m.name?.lowercased().contains("vl") == true,
                supportsTools: m.name?.lowercased().contains("tool") == true
            )
        }
    }

    private func convert(_ r: ChatResponse) -> UnifiedResponse {
        let text = r.message?.content ?? ""
        return UnifiedResponse(
            id: UUID().uuidString,
            model: r.model ?? "ollama",
            stopReason: r.done_reason,
            usage: UnifiedUsage(
                promptTokens: r.prompt_eval_count ?? 0,
                completionTokens: r.eval_count ?? 0
            ),
            content: text.isEmpty ? [] : [.text(text)]
        )
    }
}

private struct TagsResponse: Codable {
    var models: [ModelTag]?

    struct ModelTag: Codable {
        var name: String?
        var modified_at: Date?
        var size: Int64?
    }
}

private struct ChatResponse: Codable {
    var model: String?
    var message: Message?
    var done: Bool?
    var done_reason: String?
    var prompt_eval_count: Int?
    var eval_count: Int?

    struct Message: Codable {
        var role: String
        var content: String?
    }
}

private enum OllamaStreamDecoder {
    static func stream(from bytes: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<UnifiedStreamChunk, Error> {
        AsyncThrowingStream<UnifiedStreamChunk, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty { continue }
                        // Ollama NDJSON：每行都是 ChatResponse
                        if let d = trimmed.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            let text = (json["message"] as? [String: Any])?["content"] as? String
                            let done = json["done"] as? Bool
                            let reason = json["done_reason"] as? String
                            if let t = text, !t.isEmpty {
                                continuation.yield(UnifiedStreamChunk(
                                    index: nil, deltaText: t,
                                    toolCallDelta: nil, finishReason: nil, usage: nil
                                ))
                            }
                            if done == true {
                                continuation.yield(UnifiedStreamChunk(
                                    index: nil, deltaText: nil,
                                    toolCallDelta: nil, finishReason: reason, usage: nil
                                ))
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