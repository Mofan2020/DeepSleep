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
        VStack(alignment: .leading, spacing: 16) {
            blockersCard
            changesCard
        }
    }

    // MARK: - 谁在阻止休眠

    private var blockersCard: some View {
        SectionCard(
            title: "谁在阻止休眠",
            subtitle: "系统当前所有持有电源断言的进程。数据由内核直接给出，"
                + "Deep Sleep 自己的断言也列在里面，方便对照。",
            symbol: "hand.raised.fill",
            accent: .orange
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if let scanned = monitor.lastScanAt {
                        Text("上次扫描 \(Self.timeFormatter.string(from: scanned))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        monitor.scan()
                    } label: {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }

                if monitor.blockers.isEmpty {
                    Text("当前没有任何进程在阻止休眠。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(monitor.blockers) { blocker in
                            blockerRow(blocker)
                        }
                    }
                }
            }
        }
    }

    private func blockerRow(_ blocker: SleepBlocker) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: blocker.isPreventingSystemSleep ? "moon.zzz.fill" : "display")
                    .font(.system(size: 12))
                    .foregroundStyle(blocker.isPreventingSystemSleep ? Color.orange : Color.secondary)
                Text(blocker.name)
                    .font(.callout.weight(.medium))
                Text("pid \(blocker.pid)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                if blocker.isSelf {
                    Tag(text: "Deep Sleep", color: .green)
                }
                Spacer(minLength: 6)
                Tag(text: blocker.isPreventingSystemSleep ? "阻止系统睡眠" : "仅阻止屏幕睡眠",
                    color: blocker.isPreventingSystemSleep ? .orange : .secondary)
            }

            ForEach(blocker.assertions) { assertion in
                VStack(alignment: .leading, spacing: 1) {
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
                .padding(.leading, 19)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
            accent: .purple
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("\(monitor.changes.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        monitor.clearChanges()
                    } label: {
                        Label("清空记录", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(monitor.changes.isEmpty)
                }

                if monitor.changes.isEmpty {
                    Text("尚未检测到电源设置被改动。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(monitor.changes) { change in
                            changeRow(change)
                        }
                    }
                }
            }
        }
    }

    private func changeRow(_ change: PowerSettingChange) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(Self.timeFormatter.string(from: change.date))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(change.key)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                    Tag(text: change.bySelf ? "Deep Sleep" : "外部改动",
                        color: change.bySelf ? .green : .red)
                }
                Text("\(change.oldValue ?? "（无）") → \(change.newValue)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(change.bySelf ? Color.secondary : Color.red)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
