//
//  TokenDashboardView.swift
//  Deep Sleep
//
//  LLM Gateway 配额总览：每个 Provider 一张卡，
//  订阅类展示 5h / 周窗口，按量类展示余额。
//  倒计时 1 秒刷新（TimelineView）。
//

import SwiftUI

struct TokenDashboardView: View {

    @ObservedObject private var controller = GatewayController.shared

    private var providerSnapshots: [(ProviderConfig, QuotaWindow?)] {
        controller.providers.map { ($0, controller.latestSnapshots[$0.id]) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard

                if controller.providers.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(controller.providers) { provider in
                            ProviderQuotaCard(
                                provider: provider,
                                snapshot: controller.latestSnapshots[provider.id]
                            )
                        }
                    }
                }
            }
            .pageLayout()
        }
        .navigationTitle("Token 用量")
    }

    // MARK: - Header

    private var headerCard: some View {
        SectionCard(
            title: "配额总览",
            subtitle: controller.providers.isEmpty
                ? "暂无 Provider"
                : "当前共 \(controller.providers.count) 个 Provider",
            symbol: "gauge.with.dots.needle.50percent"
        ) {
            HStack(spacing: 10) {
                Button {
                    Task { await controller.refreshAllQuotas() }
                } label: {
                    Label("全部刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.providers.isEmpty)

                if LLMGatewayFeature.gateway.isEnabled {
                    Spacer()
                    gatewayToggle
                }
            }
        }
    }

    @ViewBuilder
    private var gatewayToggle: some View {
        Toggle(isOn: Binding(
            get: { controller.isRunning },
            set: { newValue in
                Task {
                    if newValue { try? await controller.startGateway() }
                    else { controller.stopGateway() }
                }
            }
        )) {
            Label(controller.isRunning ? "停止网关" : "启动网关",
                  systemImage: controller.isRunning ? "stop.fill" : "play.fill")
        }
        .toggleStyle(.switch)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("暂无 Provider。前往「模型」标签页添加。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Card

private struct ProviderQuotaCard: View {
    let provider: ProviderConfig
    let snapshot: QuotaWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: provider.platform.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.headline)
                    Text(provider.platform.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let status = snapshot?.windowStatus {
                    StatusPill(
                        text: status.label,
                        isActive: status == .normal || status == .unlimited
                    )
                }
            }

            Divider()

            content

            if let capturedAt = snapshot?.capturedAt {
                Text("更新于 \(Self.timeFormatter.string(from: capturedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("尚无数据")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    @ViewBuilder
    private var content: some View {
        switch provider.billingMode {
        case .payAsYouGo:
            balanceContent
        case .subscription, .codingPlan:
            windowContent
        case .unlimited:
            unlimitedContent
        }
    }

    private var balanceContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("余额")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let s = snapshot, let amount = s.balanceAmount {
                Text(formatCurrency(amount: amount, currency: s.balanceCurrency))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                ProgressView(value: balanceFraction(s))
                    .progressViewStyle(.linear)
            } else {
                Text("--")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var windowContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = snapshot {
                windowRow(label: "5h 窗口", used: s.fiveHourUsed, total: s.fiveHourTotal,
                          resetAt: s.fiveHourResetAt)
                windowRow(label: "周窗口", used: s.weeklyUsed, total: s.weeklyTotal,
                          resetAt: s.weeklyResetAt)
            } else {
                Text("暂无数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func windowRow(label: String, used: Double?, total: Double?, resetAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let used, let total, total > 0 {
                    Text("\(Int(used)) / \(Int(total))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: percent(used: used, total: total))
                .progressViewStyle(.linear)
            if let resetAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("重置于 \(Self.formatRemaining(until: resetAt, now: context.date))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var unlimitedContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "infinity")
            Text("无限额度")
        }
        .font(.subheadline)
        .foregroundStyle(.green)
    }

    // MARK: - Helpers

    private func balanceFraction(_ s: QuotaWindow) -> Double {
        guard let amount = s.balanceAmount, amount > 0 else { return 0 }
        // 余额条：单纯显示剩余值；上限设 100 当 fallback。
        let cap = max(amount * 2, 100)
        return min(max(amount / cap, 0), 1)
    }

    private func percent(used: Double?, total: Double?) -> Double {
        guard let u = used, let t = total, t > 0 else { return 0 }
        return min(max(u / t, 0), 1)
    }

    private func formatCurrency(amount: Double, currency: String?) -> String {
        let symbol = currencySymbol(currency)
        return "\(symbol)\(String(format: "%.2f", amount))"
    }

    private func currencySymbol(_ code: String?) -> String {
        switch code?.uppercased() {
        case "USD": return "$"
        case "CNY", "RMB": return "¥"
        case "EUR": return "€"
        case "JPY": return "¥"
        default: return ""
        }
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func formatRemaining(until date: Date, now: Date) -> String {
        let interval = max(date.timeIntervalSince(now), 0)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        if hours > 0 {
            return String(format: "%d 小时 %02d 分", hours, minutes)
        }
        if minutes > 0 {
            return String(format: "%d 分 %02d 秒", minutes, seconds)
        }
        return "\(seconds) 秒"
    }
}

// MARK: - WindowStatus 扩展

private extension QuotaWindow.WindowStatus {
    var label: String {
        switch self {
        case .unknown:   return "未知"
        case .normal:    return "正常"
        case .exhausted: return "已耗尽"
        case .unlimited: return "无限"
        }
    }
}

private extension LLMPlatform {
    var symbolName: String {
        switch self {
        case .anthropicGlobal, .anthropicCN: return "brain"
        case .openai:          return "sparkles"
        case .minimaxGlobal, .minimaxCN:     return "star.circle"
        case .deepseek:        return "magnifyingglass.circle"
        case .zhipu:           return "wand.and.stars"
        case .dashScope:       return "cloud"
        case .moonshot:        return "moon.stars"
        case .doubao:          return "leaf"
        case .qianfan:         return "globe.asia.australia.fill"
        case .gemini:          return "sparkle"
        case .grok:            return "bolt"
        case .mistral:         return "wind"
        case .cohere:          return "circle.hexagongrid"
        case .ollama:          return "server.rack"
        }
    }
}
