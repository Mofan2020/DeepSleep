//
//  ExternalActivityView.swift
//  Deep Sleep
//
//  「外部活动」页：系统里还有谁在碰电源管理。
//
//  回答两个用户真正关心的问题：
//    - 现在是谁在阻止休眠？
//    - 是谁在改电源设置，跟我们抢控制权？
//
//  2026-11 界面换新：空态换成 EmptyStateView（不再是一行灰字），
//  行列表改用 L2 卡内分区（insetPanel），状态一律「颜色 + 文字」双编码。
//  数据来源与扫描节奏没动。
//

import SwiftUI

struct ExternalActivityView: View {

    @EnvironmentObject private var controller: SleepController
    @ObservedObject private var monitor = PowerActivityMonitor.shared

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            rivalsCard
            blockersCard
            changesCard
        }
    }

    // MARK: - 争夺电源控制的程序

    private var rivalsCard: some View {
        SectionCard(
            title: "可能争夺电源控制的程序",
            subtitle: "这些程序自己不拦睡眠，所以不会出现在下面的列表里，"
                + "但它们会直接改系统电源设置，和 Deep Sleep 互相覆盖。",
            symbol: "exclamationmark.triangle",
            accent: monitor.rivals.isEmpty ? DS.Tone.good : DS.Tone.critical
        ) {
            if monitor.rivals.isEmpty {
                EmptyStateView(
                    title: "没有发现其他会修改电源设置的程序",
                    message: "常见的电源管理工具都没有在运行。",
                    systemImage: "checkmark.circle"
                )
            } else {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    ForEach(monitor.rivals) { rival in
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            HStack(spacing: DS.Space.sm) {
                                Text(rival.name)
                                    .font(.callout.weight(.medium))
                                Text(rival.bundleID)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: DS.Space.sm)
                                Tag(text: "会改电源设置", color: DS.Tone.critical)
                            }
                            Text(rival.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(DS.Space.md)
                        .insetPanel()
                    }
                }
            }
        }
    }

    // MARK: - 谁在阻止休眠

    private var blockersCard: some View {
        SectionCard(
            title: "谁在阻止休眠",
            subtitle: "系统里此刻所有拦着睡眠的进程。数据由内核直接给出，"
                + "Deep Sleep 自己的也在里面，方便对照。",
            symbol: "hand.raised.fill",
            accent: DS.Tone.caution,
            accessory: AnyView(
                Button {
                    monitor.scan()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            )
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                if let scanned = monitor.lastScanAt {
                    LabeledContent("上次扫描") {
                        Text(Self.timeFormatter.string(from: scanned))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                if monitor.blockers.isEmpty {
                    EmptyStateView(
                        title: "当前没有外部进程阻止睡眠",
                        message: "系统里没有进程持有阻止睡眠的电源断言。",
                        systemImage: "checkmark.circle"
                    )
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        ForEach(monitor.blockers) { blocker in
                            blockerRow(blocker)
                        }
                    }
                }
            }
        }
    }

    private func blockerRow(_ blocker: SleepBlocker) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: blocker.isPreventingSystemSleep ? "moon.zzz.fill" : "display")
                    .font(.system(size: 12))
                    .foregroundStyle(blocker.isPreventingSystemSleep ? DS.Tone.caution : DS.Tone.idle)
                Text(blocker.name)
                    .font(.callout.weight(.medium))
                Text("pid \(blocker.pid)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                if blocker.isSelf {
                    Tag(text: "Deep Sleep", color: DS.Tone.good)
                }
                Spacer(minLength: DS.Space.sm)
                Tag(text: blocker.isPreventingSystemSleep ? "阻止系统睡眠" : "仅阻止屏幕睡眠",
                    color: blocker.isPreventingSystemSleep ? DS.Tone.caution : DS.Tone.idle)
            }

            ForEach(blocker.assertions) { assertion in
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(assertion.type)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if !assertion.reason.isEmpty {
                        Text(assertion.reason)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, DS.Space.xl)
        }
        .padding(DS.Space.md)
        .insetPanel()
    }

    // MARK: - 设置改动

    private var changesCard: some View {
        SectionCard(
            title: "电源设置的改动记录",
            subtitle: "Deep Sleep 每 6 秒比对一次系统设置。"
                + "能确定改了什么、从什么变成什么、什么时候，以及是不是本应用自己改的；"
                + "但 macOS 不提供「哪个进程写入了设置」的接口，"
                + "所以这里不会去猜一个进程名。",
            symbol: "waveform.path.ecg",
            accent: .purple,
            accessory: AnyView(
                Button {
                    monitor.clearChanges()
                } label: {
                    Label("清空记录", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(monitor.changes.isEmpty)
            )
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                if monitor.changes.isEmpty {
                    EmptyStateView(
                        title: "尚未检测到电源设置被改动",
                        message: "有程序改动了系统电源设置时，这里会记录改动前后的值。",
                        systemImage: "checkmark.circle"
                    )
                } else {
                    LabeledContent("改动记录") {
                        Text("\(monitor.changes.count) 条")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)

                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        ForEach(monitor.changes) { change in
                            changeRow(change)
                        }
                    }
                }
            }
        }
    }

    private func changeRow(_ change: PowerSettingChange) -> some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Text(Self.timeFormatter.string(from: change.date))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xs) {
                    Text(change.key)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                    Tag(text: change.bySelf ? "Deep Sleep" : "外部改动",
                        color: change.bySelf ? DS.Tone.good : DS.Tone.critical)
                }
                Text("\(change.oldValue ?? "（无）") → \(change.newValue)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(change.bySelf ? Color.secondary : DS.Tone.critical)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.sm)
        .insetPanel()
    }
}
