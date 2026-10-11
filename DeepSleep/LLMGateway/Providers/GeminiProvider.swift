//
//  GeminiProvider.swift
//  Deep Sleep
//
//  Google Gemini 适配层。
//
//  关键点：
//  - Chat endpoint: POST {base}/v1beta/models/{model}:generateContent
//    鉴权：?key=KEY 或 Authorization: Bearer KEY
//  - Streaming: POST {base}/v1beta/models/{model}:streamGenerateContent?alt=sse
//  - Quota：Google 公开 API 没有稳定的 quota endpoint；本实现调
//    GET {base}/v1beta/models?key=KEY → 列模型，间接验证 key 有效性。
//  - Auth: query string key 或 Bearer
//

import Foundation

final class GeminiProvider: NSObject, LLMProvider, LLMProviderInit {

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
        // Gemini 公开 API 不暴露余额/RPM；用 model list 验证 key 有效性即可。
        // 返回 .unknown 窗口让上层 UI 兜底。
        guard !apiKey.isEmpty else { throw LLMGatewayError.noAPIKey }
        var comps = URLComponents(string: "\(baseURL)/v1beta/models")!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey), URLQueryItem(name: "pageSize", value: "1")]
        var req = HTTPRequest(url: comps.url!)
        req.headers["Authorization"] = "Bearer \(apiKey)"
        let resp = try await HTTPClient.shared.fetch(req)
        _ = try HTTPClient.ensureSuccess(resp)
        return [QuotaWindow(
            providerId: config.id,
            capturedAt: Date(),
            fiveHourUsed: nil, fiveHourTotal: nil, fiveHourResetAt: nil,
            weeklyUsed: nil, weeklyTotal: nil, weeklyResetAt: nil,
            balanceAmount: nil, balanceCurrency: nil,
            windowStatus: .unknown
        )]
    }

    func send(_ request: UnifiedRequest, stream: Bool) async throws -> SendResult {
        var urlStr = "\(baseURL)/v1beta/models/\(request.model):generateContent"
        if stream { urlStr += "?alt=sse" }
        var comps = URLComponents(string: urlStr)!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        // 构造 Gemini contents（user/model parts 数组）
        var contents: [[String: Any]] = []
        for m in request.messages {
            let texts = m.content.compactMap { c -> String? in
                if case .text(let s) = c { return s } else { return nil }
            }
            let role = m.role == "assistant" ? "model" : "user"
            contents.append([
                "role": role,
                "parts": [["text": texts.joined(separator: "\n")]]
            ])
        }
        var dict: [String: Any] = ["contents": contents]
        if let sys = request.system {
            dict["systemInstruction"] = ["parts": [["text": sys]]]
        }
        let body = try JSONSerialization.data(withJSONObject: dict)

        var urlReq = HTTPRequest(url: comps.url!, method: "POST")
        urlReq.headers["Content-Type"] = "application/json"
        urlReq.body = body

        if stream {
            let (code, s) = try await HTTPClient.shared.stream(urlReq)
            guard (200..<300).contains(code) else {
                throw LLMGatewayError.httpStatus(code, "<stream>")
            }
            return .stream(GeminiStreamDecoder.stream(from: s))
        } else {
            let resp = try await HTTPClient.shared.fetch(urlReq)
            let data = try HTTPClient.ensureSuccess(resp)
            let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
            return .single(convert(decoded))
        }
    }

    func listModels() async throws -> [ModelInfo] {
        var comps = URLComponents(string: "\(baseURL)/v1beta/models")!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var req = HTTPRequest(url: comps.url!)
        req.headers["Authorization"] = "Bearer \(apiKey)"
        let resp = try await HTTPClient.shared.fetch(req)
        let data = try HTTPClient.ensureSuccess(resp)
        let parsed = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return (parsed.models ?? []).compactMap { m -> ModelInfo? in
            // name 形如 "models/gemini-1.5-pro"
            let raw = m.name ?? ""
            let short = raw.hasPrefix("models/") ? String(raw.dropFirst("models/".count)) : raw
            return ModelInfo(
                name: short,
                displayName: m.displayName ?? short,
                contextWindow: m.inputTokenLimit,
                supportsVision: short.contains("vision") || short.contains("vl") || m.supportedGenerationMethods?.contains("generateContent") == true,
                supportsTools: m.supportedGenerationMethods?.contains("generateContent") == true
            )
        }
    }

    private func convert(_ r: GenerateResponse) -> UnifiedResponse {
        var text = ""
        for c in r.candidates ?? [] {
            if let parts = c.content?.parts {
                text += parts.compactMap { $0.text }.joined()
            }
        }
        return UnifiedResponse(
            id: r.responseId ?? UUID().uuidString,
            model: r.modelVersion ?? "gemini",
            stopReason: r.candidates?.first?.finishReason,
            usage: UnifiedUsage(
                promptTokens: r.usageMetadata?.promptTokenCount ?? 0,
                completionTokens: r.usageMetadata?.candidatesTokenCount ?? 0
            ),
            content: text.isEmpty ? [] : [.text(text)]
        )
    }
}

private struct GenerateResponse: Codable {
    var candidates: [Candidate]?
    var modelVersion: String?
    var responseId: String?
    var usageMetadata: UsageMetadata?

    struct Candidate: Codable {
        var content: Content?
        var finishReason: String?
    }

    struct Content: Codable {
        var parts: [Part]?
        var role: String?
    }

    struct Part: Codable {
        var text: String?
    }

    struct UsageMetadata: Codable {
        var promptTokenCount: Int?
        var candidatesTokenCount: Int?
        var totalTokenCount: Int?
    }
}

private struct ModelsResponse: Codable {
    var models: [Model]?

    struct Model: Codable {
        var name: String?                        // "models/gemini-1.5-pro"
        var displayName: String?
        var inputTokenLimit: Int?
        var supportedGenerationMethods: [String]?
    }
}

private enum GeminiStreamDecoder {
    static func stream(from bytes: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<UnifiedStreamChunk, Error> {
        AsyncThrowingStream<UnifiedStreamChunk, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty { continue }
                        if trimmed.hasPrefix("data:") {
                            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if let data = payload.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let candidates = json["candidates"] as? [[String: Any]],
                               let first = candidates.first,
                               let content = first["content"] as? [String: Any],
                               let parts = content["parts"] as? [[String: Any]] {
                                let text = parts.compactMap { $0["text"] as? String }.joined()
                                let finish = first["finishReason"] as? String
                                if !text.isEmpty || finish != nil {
                                    continuation.yield(UnifiedStreamChunk(
                                        index: nil, deltaText: text.isEmpty ? nil : text,
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