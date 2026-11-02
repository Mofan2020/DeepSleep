//
//  LogView.swift
//  Deep Sleep
//
//  运行日志页。
//
//  日志保存在内存里，按条数与天数双重裁剪，不会无限增长。
// 真正会落盘的是特权助手的日志（/var/log），那份由助手自己按天归档、
//  按大小截尾并清理过期归档。
//
//  2026-11 界面换新：加等级筛选（全部 / 仅错误）与关键词搜索，
//  条目列表换成原生 List（惰性渲染，日志再多也不一次性铺满），
//  空态换成 EmptyStateView。
//

import SwiftUI

struct LogView: View {

    @EnvironmentObject private var controller: SleepController

    /// 等级筛选。默认看全部。
    @State private var levelFilter: LogLevelFilter = .all
    /// 关键词搜索。空字符串表示不过滤。
    @State private var searchText: String = ""

    /// 待确认的清空操作。`nil` 表示没有清空在等确认。
    @State private var pendingClear: TlDeleteRequest?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    /// 日志列表的固定高度。
    ///
    /// 页面本身在 ScrollView 里，List 必须自己占一个确定的高度，
    /// 否则它会按内容撑开、把外层滚动条顶没；列表内部自己滚。
    private static let logListHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            retentionCard
            logCard
        }
        .deleteConfirmation($pendingClear)
    }

    // MARK: - 保留策略

    private var retentionCard: some View {
        SectionCard(
            title: "日志保留策略",
            subtitle: "本页日志只保存在内存中，不写磁盘。按条数与天数双重裁剪，"
                + "即使某个循环把日志刷爆，占用也有上限。",
            symbol: "internaldrive",
            accent: .blue
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                stepperRow(
                    title: "最多保留条数",
                    detail: "超出后从最旧的开始丢弃（50 – 5000）",
                    value: Binding(
                        get: { controller.logRetentionCount },
                        set: { controller.logRetentionCount = $0 }
                    ),
                    range: 50...5000,
                    step: 50
                )

                Divider()

                stepperRow(
                    title: "最多保留天数",
                    detail: "早于这个天数的记录会被清除，0 表示不限",
                    value: Binding(
                        get: { controller.logRetentionDays },
                        set: { controller.logRetentionDays = $0 }
                    ),
                    range: 0...365,
                    step: 1
                )

                Divider()

                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    Text(trimSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var trimSummary: String {
        var parts = ["当前 \(controller.log.count) 条"]
        if let oldest = controller.log.first?.date {
            parts.append("最早 \(Self.dayFormatter.string(from: oldest))")
        }
        if controller.trimmedLogCount > 0 {
            parts.append("已自动清除 \(controller.trimmedLogCount) 条")
        }
        return parts.joined(separator: " · ")
    }

    private func stepperRow(title: String,
                            detail: String,
                            value: Binding<Int>,
                            range: ClosedRange<Int>,
                            step: Int) -> some View {
        LabeledContent {
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)")
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
            }
            .fixedSize()
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 日志列表

    private var logCard: some View {
        SectionCard(
            title: "运行日志",
            subtitle: "记录本应用的全部电源操作。助手侧的日志位于 "
                + "\(HelperConstants.logPath)（按天归档，超期自动清理）。",
            symbol: "text.alignleft",
            accessory: AnyView(
                Button {
                    pendingClear = TlDeleteRequest(
                        title: "清空日志？",
                        message: "\(controller.log.count) 条运行日志会被删掉，删掉之后没法恢复。",
                        confirmTitle: "清空",
                        perform: { controller.clearLog() }
                    )
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(controller.log.isEmpty)
            )
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(spacing: DS.Space.md) {
                    Picker("等级", selection: $levelFilter) {
                        ForEach(LogLevelFilter.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 200)

                    TextField("搜索日志内容", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    Spacer(minLength: DS.Space.sm)
                }

                LabeledContent("显示") {
                    Text("\(filteredEntries.count) / \(controller.log.count) 条")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                if controller.log.isEmpty {
                    EmptyStateView(
                        title: "暂无日志",
                        message: "应用产生的电源操作会记录在这里。",
                        systemImage: "text.alignleft"
                    )
                } else if filteredEntries.isEmpty {
                    EmptyStateView(
                        title: "没有匹配的日志",
                        message: "换个关键词，或把等级切回「全部」。",
                        systemImage: "magnifyingglass"
                    )
                } else {
                    logList
                }
            }
        }
    }

    /// 日志条目列表。
    ///
    /// 用原生 List —— 它是惰性容器，几千条日志也只渲染可见的那几行。
    private var logList: some View {
        List(filteredEntries) { entry in
            HStack(alignment: .top, spacing: DS.Space.sm) {
                Text(Self.timeFormatter.string(from: entry.date))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                Text(entry.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(entry.isError ? DS.Tone.critical : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if entry.isError {
                    Tag(text: "错误", color: DS.Tone.critical)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(height: Self.logListHeight)
    }

    /// 过滤后的日志条目，最新的排在最前面。
    private var filteredEntries: [LogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return controller.log.reversed().filter { entry in
            if levelFilter == .errorsOnly && !entry.isError { return false }
            if query.isEmpty { return true }
            return entry.text.localizedCaseInsensitiveContains(query)
        }
    }
}

// MARK: - 等级筛选

/// 日志等级筛选。
private enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case errorsOnly = "仅错误"

    var id: String { rawValue }
}
