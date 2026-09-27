//
//  LogView.swift
//  Deep Sleep
//
//  运行日志页。
//
//  日志保存在内存里，按条数与天数双重裁剪，不会无限增长。
//  真正会落盘的是特权助手的日志（/var/log），那份由助手自己按天归档、
//  按大小截尾并清理过期归档。
//

import SwiftUI

struct LogView: View {

    @EnvironmentObject private var controller: SleepController

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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            retentionCard
            logCard
        }
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
            VStack(alignment: .leading, spacing: 12) {
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

                HStack(spacing: 9) {
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)")
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 56, alignment: .trailing)
            }
        }
    }

    // MARK: - 日志列表

    private var logCard: some View {
        SectionCard(
            title: "运行日志",
            subtitle: "记录本应用的全部电源操作。助手侧的日志位于 "
                + "\(HelperConstants.logPath)（按天归档，超期自动清理）。",
            symbol: "text.alignleft"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("\(controller.log.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        controller.clearLog()
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(controller.log.isEmpty)
                }

                if controller.log.isEmpty {
                    Text("暂无日志")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(controller.log.reversed()) { entry in
                            HStack(alignment: .top, spacing: 9) {
                                Text(Self.timeFormatter.string(from: entry.date))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 62, alignment: .leading)
                                Text(entry.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(entry.isError ? Color.red : Color.primary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }
}
