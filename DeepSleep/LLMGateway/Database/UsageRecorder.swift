//
//  UsageRecorder.swift
//  Deep Sleep
//
//  每个请求完成时记账用的轻量 actor。
//
//  设计：
//  - 走 GatewayDatabase.recordUsage。GatewayDatabase 单例的 queue 是串行的，
//    所以即使 GatewayServer 在多个 connection 上并发调用 record 也不会写花。
//  - 提供按 provider 聚合（包一层 GatewayDatabase.aggregateUsage），UI 显示
//    「今日用 X tokens」之类时直接调即可。
//

import Foundation

actor UsageRecorder {

    static let shared = UsageRecorder()

    private init() {}

    /// 记一条请求账目。
    /// - Parameters:
    ///   - provider: Provider id（用于归类 provider 维度）。
    ///   - model: 模型名（"claude-3-5-sonnet-20241022" 等）。
    ///   - usage: 这次请求的 token 计数。
    ///   - latency: 端到端时延（毫秒）。
    ///   - status: HTTP 状态码（200 / 4xx / 5xx 都如实记）。
    ///   - source: 客户端协议（"anthropic" / "openai"）。
    ///   - target: Provider 实际接收的协议。
    func record(
        provider: UUID,
        model: String,
        usage: UnifiedUsage,
        latency: Int,
        status: Int,
        source: String,
        target: String
    ) {
        let rec = UsageRecord(
            providerId: provider,
            model: model,
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens,
            latencyMs: latency,
            statusCode: status,
            sourceFormat: source,
            targetFormat: target
        )
        do {
            try GatewayDatabase.shared.recordUsage(rec)
        } catch {
            NSLog("[UsageRecorder] recordUsage failed: \(error)")
        }
    }

    /// 按 provider 聚合 [since, now] 的用量。
    func aggregate(
        provider: UUID, since: Date, until: Date = Date()
    ) -> GatewayDatabase.UsageAggregate {
        do {
            return try GatewayDatabase.shared.aggregateUsage(
                providerId: provider, since: since, until: until
            )
        } catch {
            return GatewayDatabase.UsageAggregate(
                providerId: provider,
                promptTokens: 0, completionTokens: 0, requestCount: 0
            )
        }
    }
}
