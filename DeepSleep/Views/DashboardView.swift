//
//  DashboardView.swift
//  Deep Sleep
//
//  总览页：一屏之内说清三件事 —— 现在是什么状态、下一步做什么、刚发生了什么。
//
//  设计约束（改动前先读）：
//  - 状态**只在这里说一次**。侧边栏底部只留一行摘要，不重复这里的内容。
//  - 主操作（立即睡眠 / 释放 / 倒计时）不放进卡片，直接摊在页面上，
//    放在卡片里会让人以为它需要先展开点什么。
//  - 状态永远「颜色 + 文字」双编码，不能只靠颜色。
//

import SwiftUI

struct DashboardView: View {

    @EnvironmentObject private var controller: SleepController
    @State private var countdownMinutes: Int = 30

    var body: some View {
        StatusHeroCard()
            .environmentObject(controller)

        quickActions

        SectionCard(
            title: "状态速览",
            symbol: "speedometer",
            accent: .secondary
        ) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                MetricTile(
                    title: "电源",
                    value: controller.batteryIsOnAC ? "已接入" : "电池",
                    status: controller.batteryIsOnAC ? "外接供电" : "使用电池供电",
                    tint: controller.batteryIsOnAC ? DS.Tone.good : DS.Tone.caution,
                    symbol: controller.batteryIsOnAC ? "powerplug.fill" : "battery.50"
                )
                MetricTile(
                    title: "自动化",
                    value: "\(controller.automation.satisfiedRuleIDs.count)",
                    unit: "条生效",
                    status: controller.automation.isRunning ? "引擎运行中" : "引擎未运行",
                    tint: controller.automation.isRunning ? DS.Tone.info : DS.Tone.idle,
                    symbol: "gearshape.2"
                )
                MetricTile(
                    title: "完全控制",
                    value: controller.helperState.isReady ? "已启用" : "未启用",
                    status: controller.helperState.title,
                    tint: controller.helperState.isReady ? DS.Tone.good : DS.Tone.caution,
                    symbol: controller.helperState.isReady ? "lock.shield.fill" : "lock.shield"
                )
            }
        }

        SectionCard(
            title: "保持清醒",
            subtitle: "打开后会持续向系统申请对应的电源 assertion，关闭即释放。",
            symbol: "moon.zzz.fill"
        ) {
            VStack(spacing: DS.Space.sm) {
                ForEach(AssertionKind.allCases) { kind in
                    AssertionRow(kind: kind)
                        .environmentObject(controller)
                    if kind != AssertionKind.allCases.last {
                        Divider()
                    }
                }
            }
        }

        recentEvents
    }

    // MARK: - 主操作

    /// 主操作条。不套卡片 —— 这是这一页最该被点到的东西。
    private var quickActions: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.md) {
                Button {
                    Task { await controller.sleepNow() }
                } label: {
                    Label("立即睡眠", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.countdownDeadline != nil)

                Button {
                    Task { await controller.releaseAllAssertions() }
                } label: {
                    Label("释放全部保持", systemImage: "arrow.uturn.backward")
                }
                .disabled(controller.activeAssertions.isEmpty)

                Spacer(minLength: DS.Space.md)

                if let deadline = controller.countdownDeadline {
                    CountdownLabel(deadline: deadline)
                }
            }

            Divider()

            HStack(spacing: DS.Space.md) {
                Text("倒计时睡眠")
                    .font(.subheadline.weight(.medium))
                Text("设定时长后开始计时，到点自动进入睡眠。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: DS.Space.md)

                Picker("", selection: $countdownMinutes) {
                    ForEach([5, 10, 15, 30, 45, 60, 90, 120], id: \.self) { value in
                        Text("\(value) 分钟").tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                .disabled(controller.countdownDeadline != nil)

                Button("开始倒计时") {
                    controller.startCountdown(minutes: countdownMinutes)
                }
                .disabled(controller.countdownDeadline != nil)

                Button("取消") {
                    controller.cancelCountdown()
                }
                .disabled(controller.countdownDeadline == nil)
            }
        }
        .padding(DS.Space.lg)
        .insetPanel()
    }

    // MARK: - 最近事件

    private var recentEvents: some View {
        SectionCard(
            title: "最近事件",
            subtitle: "最近几条运行记录，完整日志在「运行日志」页。",
            symbol: "clock.arrow.circlepath"
        ) {
            if controller.log.isEmpty {
                EmptyStateView(
                    title: "还没有记录",
                    message: "开关一次保持清醒或改一次设置，这里就会有记录。",
                    systemImage: "text.alignleft"
                )
                .frame(minHeight: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(controller.log.suffix(5).reversed())) { entry in
                        HStack(alignment: .top, spacing: DS.Space.sm) {
                            Circle()
                                .fill(entry.isError ? DS.Tone.critical : Color.secondary.opacity(0.5))
                                .frame(width: 6, height: 6)
                                .padding(.top, 5)
                            Text(entry.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: DS.Space.sm)
                            Text(entry.date, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, DS.Space.xs)
                    }
                }
            }
        }
    }
}

// MARK: - 顶部状态卡

/// 顶部状态卡：当前是否在阻止睡眠。
struct StatusHeroCard: View {

    @EnvironmentObject private var controller: SleepController

    private var isHolding: Bool { !controller.activeAssertions.isEmpty }

    private var statusTitle: String {
        if controller.sleepDisabled { return "系统睡眠已完全禁用" }
        return isHolding ? "正在保持清醒" : "允许正常睡眠"
    }

    private var statusDetail: String {
        if controller.sleepDisabled {
            return "合上盖子也不会睡眠。关闭「完全禁止系统睡眠」即可恢复。"
        }
        if isHolding {
            let names = controller.activeAssertions
                .sorted { $0.rawValue < $1.rawValue }
                .map(\.title)
                .joined(separator: "、")
            return "已生效 \(controller.activeAssertions.count) 项：\(names)"
        }
        return "没有任何 assertion 在阻止睡眠，系统会按电源设置正常休眠。"
    }

    private var tint: Color {
        if controller.sleepDisabled { return DS.Tone.caution }
        return isHolding ? DS.Tone.good : DS.Tone.idle
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.xl) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 56, height: 56)
                Image(systemName: controller.sleepDisabled ? "exclamationmark.octagon.fill"
                      : (isHolding ? "cup.and.saucer.fill" : "moon.fill"))
                    .font(.system(size: 23))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(statusTitle)
                    .font(.title2.weight(.semibold))
                Text(statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DS.Space.md)

            nextAction
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.hero)
    }

    /// 右栏：下一次系统动作。这是用户最常问的问题之一。
    @ViewBuilder
    private var nextAction: some View {
        VStack(alignment: .trailing, spacing: DS.Space.sm) {
            Text("下一次动作")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let deadline = controller.countdownDeadline {
                VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                    Text("倒计时睡眠")
                        .font(.callout.weight(.medium))
                    CountdownLabel(deadline: deadline)
                }
            } else if let wake = controller.scheduledWake {
                VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                    Text("定时唤醒")
                        .font(.callout.weight(.medium))
                    Text(wake, format: .dateTime.month().day().hour().minute())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("没有安排")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 120, alignment: .trailing)
    }
}

// MARK: - 倒计时

/// 每秒刷新的倒计时文案。
struct CountdownLabel: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(deadline.timeIntervalSince(context.date)))
            let minutes = remaining / 60
            let seconds = remaining % 60
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "timer").foregroundStyle(DS.Tone.caution)
                Text(String(format: "剩余 %02d:%02d", minutes, seconds))
                    .font(.system(.body, design: .monospaced).weight(.medium))
            }
        }
    }
}
