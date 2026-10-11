//
//  MiniMaxProvider.swift
//  Deep Sleep
//
//  MiniMax 适配层。海外 base = https://api.minimax.io，国内 = https://api.minimaxi.com
//
//  关键点：
//  - Chat endpoint: POST {base}/anthropic/v1/messages（走 Anthropic Messages API 协议）
//  - Streaming: SSE
//  - Quota（按量，API Key 以 sk-api- 开头）：POST {base}/account/query_balance
//    → AccountBalanceResponse { available_amount, cash_balance, voucher_balance,
//      credit_balance, owed_amount, base_resp: { status_code, status_msg } }
//  - Quota（订阅 / Coding Plan）：GET {base}/v1/token_plan/remains
//    → QuotaResponse { model_remains: [{ model_name, current_interval_total_count,
//      current_interval_usage_count, current_interval_remaining_percent,
//      weekly_start_time, weekly_end_time, weekly_remains_time,
//      current_weekly_total_count, current_weekly_usage_count,
//      current_weekly_remaining_percent, current_interval_status,
//      current_weekly_status }] }
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

    /// API Key 以 sk-api- 开头视为按量（走 account_balance），否则视为订阅/Coding Plan（走 token_plan）。
    private var isSecretApiKey: Bool { apiKey.hasPrefix("sk-api-") }

    func fetchQuota() async throws -> [QuotaWindow] {
        guard !apiKey.isEmpty else { throw LLMGatewayError.noAPIKey }
        if isSecretApiKey {
            return try await fetchBalance()
        } else {
            return try await fetchTokenPlan()
        }
    }

    private func fetchBalance() async throws -> [QuotaWindow] {
        var req = HTTPRequest(url: URL(string: "\(baseURL)/account/query_balance")!, method: "POST")
        req.headers["Authorization"] = "Bearer \(apiKey)"
        req.headers["Content-Type"] = "application/json"
        req.body = try JSONSerialization.data(withJSONObject: ["account": NSNull()])
        let resp = try await HTTPClient.shared.fetch(req)
        let data = try HTTPClient.ensureSuccess(resp)
        let parsed = try JSONDecoder().decode(AccountBalanceResponse.self, from: data)
        return [QuotaWindow(
            providerId: config.id,
            capturedAt: Date(),
            fiveHourUsed: nil, fiveHourTotal: nil, fiveHourResetAt: nil,
            weeklyUsed: nil, weeklyTotal: nil, weeklyResetAt: nil,
            balanceAmount: parsed.available_amount,
            balanceCurrency: nil,
            windowStatus: .normal
        )]
    }

    private func fetchTokenPlan() async throws -> [QuotaWindow] {
        var req = HTTPRequest(url: URL(string: "\(baseURL)/v1/token_plan/remains")!)
        req.headers["Authorization"] = "Bearer \(apiKey)"
        let resp = try await HTTPClient.shared.fetch(req)
        let data = try HTTPClient.ensureSuccess(resp)
        let parsed = try JSONDecoder().decode(QuotaResponse.self, from: data)
        var windows: [QuotaWindow] = []
        for m in parsed.model_remains ?? [] {
            windows.append(QuotaWindow(
                providerId: config.id,
                capturedAt: Date(),
                fiveHourUsed: m.current_interval_usage_count,
                fiveHourTotal: m.current_interval_total_count,
                fiveHourResetAt: nil,
                weeklyUsed: m.current_weekly_usage_count,
                weeklyTotal: m.current_weekly_total_count,
                weeklyResetAt: nil,
                balanceAmount: nil, balanceCurrency: nil,
                windowStatus: mapStatus(m.current_interval_status)
            ))
        }
        return windows.isEmpty ? [emptyWindow()] : windows
    }

    func send(_ request: UnifiedRequest, stream: Bool) async throws -> SendResult {
        // MiniMax Anthropic Messages API 协议
        var dict: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "messages": request.messages.map { m -> [String: Any] in
                let texts = m.content.compactMap { c -> String? in
                    if case .text(let s) = c { return s } else { return nil }
                }
                return ["role": m.role, "content": texts.joined(separator: "\n")]
            },
            "stream": stream,
        ]
        if let sys = request.system { dict["system"] = sys }
        if let t = request.temperature { dict["temperature"] = t }
        if let p = request.topP { dict["top_p"] = p }
        let body = try JSONSerialization.data(withJSONObject: dict)

        var urlReq = HTTPRequest(
            url: URL(string: "\(baseURL)/anthropic/v1/messages")!,
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
            return .stream(SmallStreamDecoder.stream(from: s))
        } else {
            let resp = try await HTTPClient.shared.fetch(urlReq)
            let data = try HTTPClient.ensureSuccess(resp)
            let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
            return .single(convert(decoded))
        }
    }

    func listModels() async throws -> [ModelInfo] {
        return [
            ModelInfo(name: "MiniMax-Text-01", displayName: "MiniMax Text 01",
                      contextWindow: 1_000_000, supportsVision: false, supportsTools: true),
            ModelInfo(name: "MiniMax-VL-01", displayName: "MiniMax VL 01",
                      contextWindow: 1_000_000, supportsVision: true, supportsTools: true),
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

    private func mapStatus(_ s: String?) -> QuotaWindow.WindowStatus {
        switch s {
        case "1": return .normal
        case "2": return .exhausted
        case "3": return .unlimited
        default:  return .unknown
        }
    }

    private func convert(_ m: MessagesResponse) -> UnifiedResponse {
        var content: [UnifiedContent] = []
        for c in m.content ?? [] {
            if let t = c.text { content.append(.text(t)) }
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

// MARK: - Schema

private struct AccountBalanceResponse: Codable {
    var available_amount: Double?
    var cash_balance: Double?
    var voucher_balance: Double?
    var credit_balance: Double?
    var owed_amount: Double?
    var balance_alert_switch: String?
    var balance_alert_threshold: Double?
    var base_resp: BaseResp?

    struct BaseResp: Codable {
        var status_code: Int?
        var status_msg: String?
    }
}

private struct QuotaResponse: Codable {
    var model_remains: [ModelRemain]?
    var base_resp: AccountBalanceResponse.BaseResp?

    struct ModelRemain: Codable {
        var model_name: String?
        var current_interval_total_count: Double?
        var current_interval_usage_count: Double?
        var current_interval_remaining_percent: Double?
        var weekly_start_time: Date?
        var weekly_end_time: Date?
        var weekly_remains_time: Date?
        var current_weekly_total_count: Double?
        var current_weekly_usage_count: Double?
        var current_weekly_remaining_percent: Double?
        var current_interval_status: String?
        var current_weekly_status: String?
    }
}

private struct MessagesResponse: Codable {
    var id: String
    var model: String
    var stop_reason: String?
    var usage: Usage?
    var content: [Content]?

    struct Usage: Codable {
        var input_tokens: Int
        var output_tokens: Int
    }

    struct Content: Codable {
        var type: String?
        var text: String?
    }
}

// MARK: - 流式解码
//
// 直接复用 AnthropicProvider 的 SSE → UnifiedStreamChunk 解码：
// MiniMax 的 `anthropic/v1/messages` 路径返回的 SSE 与 Anthropic 字段完全一致
// （event: content_block_delta / message_delta / [DONE]）。
// 提取一个共享 decoder 集中维护；这里只做命名转发以保持本文件自包含。

private enum SmallStreamDecoder {
    static func stream(from bytes: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<UnifiedStreamChunk, Error> {
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
                    if !pending.isEmpty, let s = String(data: pending, encoding: .utf8),
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
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let type = json["type"] as? String ?? ""
        if type == "content_block_delta",
           let delta = json["delta"] as? [String: Any],
           let text = delta["text"] as? String {
            return UnifiedStreamChunk(index: nil, deltaText: text,
                                       toolCallDelta: nil, finishReason: nil, usage: nil)
        }
        if type == "message_delta",
           let delta = json["delta"] as? [String: Any],
           let stop = delta["stop_reason"] as? String {
            return UnifiedStreamChunk(index: nil, deltaText: nil,
                                       toolCallDelta: nil, finishReason: stop, usage: nil)
        }
        return nil
    }
}