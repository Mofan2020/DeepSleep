//
//  UsageDetailView.swift
//  Deep Sleep
//
//  单 Provider 用量明细：时间范围 + 聚合数字 + 模型分布 + 最近记录 + 导出 CSV。
//

import SwiftUI
import AppKit

struct UsageDetailView: View {

    let providerId: UUID

    @ObservedObject private var controller = GatewayController.shared

    enum Range: String, CaseIterable, Identifiable {
        case today = "今天"
        case week  = "7 天"
        case month = "30 天"
        var id: String { rawValue }

        var since: Date {
            let cal = Calendar.current
            switch self {
            case .today: return cal.startOfDay(for: Date())
            case .week:
                return cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            case .month:
                return cal.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            }
        }
    }

    @State private var range: Range = .today
    @State private var aggregate: GatewayDatabase.UsageAggregate?
    @State private var records: [UsageRecord] = []
    @State private var modelBreakdown: [(model: String, count: Int, tokens: Int)] = []
    @State private var loading: Bool = false
    @State private var exportURL: URL?
    @State private var exportError: String?

    private var provider: ProviderConfig? {
        controller.providers.first { $0.id == providerId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                rangeCard
                aggregateCard
                modelCard
                recordsCard
            }
            .pageLayout()
        }
        .navigationTitle(provider?.displayName ?? "用量明细")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exportCSV()
                } label: {
                    Label("导出 CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(records.isEmpty)
            }
        }
        .task { await reload() }
        .onChange(of: range) { _ in
            Task { await reload() }
        }
        .alert("导出失败",
               isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
               )
        ) {
            Button("好") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Sections

    private var rangeCard: some View {
        SectionCard(
            title: "时间范围",
            symbol: "calendar"
        ) {
            Picker("", selection: $range) {
                ForEach(Range.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var aggregateCard: some View {
        SectionCard(
            title: "汇总",
            symbol: "sum"
        ) {
            HStack(spacing: 14) {
                statBlock(title: "请求数",
                          value: aggregate.map { "\($0.requestCount)" } ?? "--")
                Divider().frame(height: 36)
                statBlock(title: "输入 Token",
                          value: aggregate.map { Self.formatNumber($0.promptTokens) } ?? "--")
                Divider().frame(height: 36)
                statBlock(title: "输出 Token",
                          value: aggregate.map { Self.formatNumber($0.completionTokens) } ?? "--")
            }
        }
    }

    private var modelCard: some View {
        SectionCard(
            title: "按模型",
            symbol: "chart.bar"
        ) {
            if modelBreakdown.isEmpty {
                Text("无数据")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                VStack(spacing: 8) {
                    ForEach(modelBreakdown, id: \.model) { item in
                        HStack {
                            Text(item.model)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(item.count) 次")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(Self.formatNumber(item.tokens) + " tok")
                                .foregroundStyle(.secondary)
                                .font(.caption.monospacedDigit())
                        }
                        if item.model != modelBreakdown.last?.model {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var recordsCard: some View {
        SectionCard(
            title: "最近记录",
            subtitle: "最多显示 200 条",
            symbol: "list.bullet.rectangle"
        ) {
            if records.isEmpty {
                Text("无数据")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                VStack(spacing: 6) {
                    ForEach(records.prefix(50)) { r in
                        recordRow(r)
                        if r.id != records.prefix(50).last?.id {
                            Divider()
                        }
                    }
                    if records.count > 50 {
                        Text("… 还有 \(records.count - 50) 条")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func recordRow(_ r: UsageRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(r.model)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                Text(Self.fullDateFormatter.string(from: r.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(Self.formatNumber(r.promptTokens))/\(Self.formatNumber(r.completionTokens))")
                        .font(.caption.monospacedDigit())
                    Text("\(r.latencyMs) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("\(r.statusCode)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(r.statusCode < 400 ? .secondary : .red)
            }
        }
        .padding(.vertical, 2)
    }

    private func statBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let since = range.since
            aggregate = try GatewayDatabase.shared.aggregateUsage(
                providerId: providerId, since: since
            )
            records = try GatewayDatabase.shared.usageRecords(
                providerId: providerId, since: since, limit: 200
            )
            modelBreakdown = computeBreakdown(records: records)
        } catch {
            aggregate = nil
            records = []
            modelBreakdown = []
        }
    }

    private func computeBreakdown(records: [UsageRecord]) -> [(model: String, count: Int, tokens: Int)] {
        var dict: [String: (count: Int, tokens: Int)] = [:]
        for r in records {
            let prev = dict[r.model] ?? (0, 0)
            dict[r.model] = (prev.count + 1, prev.tokens + r.promptTokens + r.completionTokens)
        }
        return dict
            .map { (model: $0.key, count: $0.value.count, tokens: $0.value.tokens) }
            .sorted { $0.tokens > $1.tokens }
    }

    // MARK: - Export

    private func exportCSV() {
        guard !records.isEmpty else { return }
        let csv = buildCSV(records: records)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let stamp = Self.fileStampFormatter.string(from: Date())
        let file = dir.appendingPathComponent("usage-\(providerId.uuidString.prefix(8))-\(stamp).csv")
        do {
            try csv.write(to: file, atomically: true, encoding: .utf8)
            exportURL = file
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func buildCSV(records: [UsageRecord]) -> String {
        let header = "timestamp,model,prompt_tokens,completion_tokens,latency_ms,status_code,source_format,target_format"
        let formatter = ISO8601DateFormatter()
        let rows = records.map { r in
            [
                formatter.string(from: r.timestamp),
                r.model,
                "\(r.promptTokens)",
                "\(r.completionTokens)",
                "\(r.latencyMs)",
                "\(r.statusCode)",
                r.sourceFormat,
                r.targetFormat
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    // MARK: - Formatting

    static func formatNumber(_ value: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        return nf.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
