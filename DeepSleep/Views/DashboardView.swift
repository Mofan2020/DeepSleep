//
//  DashboardView.swift
//  Deep Sleep
//
//  总览页：一眼看清当前状态，并提供最常用的几个操作。
//

import SwiftUI

struct DashboardView: View {

    @EnvironmentObject private var controller: SleepController
    @State private var countdownMinutes: Int = 30

    private var isHolding: Bool { !controller.activeAssertions.isEmpty }

    var body: some View {
        StatusHeaderCard()
            .environmentObject(controller)

        SectionCard(
            title: "保持清醒",
            subtitle: "打开后会持续向系统申请对应的电源 assertion，关闭即释放。",
            symbol: "moon.zzz.fill"
        ) {
            VStack(spacing: 10) {
                ForEach(AssertionKind.allCases) { kind in
                    AssertionRow(kind: kind)
                        .environmentObject(controller)
                    if kind != AssertionKind.allCases.last {
                        Divider()
                    }
                }
            }
        }

        SectionCard(
            title: "快捷操作",
            symbol: "bolt.fill",
            accent: .orange
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
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
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("倒计时睡眠")
                        .font(.subheadline.weight(.medium))
                    Text("设定时长后开始计时，到点自动进入睡眠。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Picker("", selection: $countdownMinutes) {
                            ForEach([5, 10, 15, 30, 45, 60, 90, 120], id: \.self) { value in
                                Text("\(value) 分钟").tag(value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
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

                    if let deadline = controller.countdownDeadline {
                        CountdownLabel(deadline: deadline)
                    }
                }
            }
        }

        SectionCard(
            title: "电源与电池",
            symbol: controller.batteryIsOnAC ? "powerplug.fill" : "battery.75",
            accent: controller.batteryIsOnAC ? .green : .secondary
        ) {
            HStack(spacing: 10) {
                StatusPill(
                    text: controller.batteryIsOnAC ? "已接入电源" : "使用电池供电",
                    isActive: controller.batteryIsOnAC
                )
                StatusPill(
                    text: controller.automation.isRunning
                        ? "自动化已运行（\(controller.automation.satisfiedRuleIDs.count)/\(controller.automation.rules.count) 条生效）"
                        : "自动化未运行",
                    isActive: controller.automation.isRunning
                )
                Spacer()
            }
        }
    }
}

/// 顶部状态卡：当前是否在阻止睡眠。
struct StatusHeaderCard: View {

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
            return "已生效：\(names)"
        }
        return "没有任何 assertion 在阻止睡眠，系统会按电源设置正常休眠。"
    }

    private var tint: Color {
        if controller.sleepDisabled { return .orange }
        return isHolding ? .green : .secondary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 60, height: 60)
                Image(systemName: controller.sleepDisabled ? "exclamationmark.octagon.fill"
                      : (isHolding ? "cup.and.saucer.fill" : "moon.fill"))
                    .font(.system(size: 25))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(statusTitle)
                    .font(.title2.weight(.semibold))
                Text(statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                StatusPill(text: "\(controller.activeAssertions.count) 项生效", isActive: isHolding)
                StatusPill(
                    text: "完全控制 \(controller.helperState.isReady ? "已启用" : "未启用")",
                    isActive: controller.helperState.isReady
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.28))
        )
    }
}

/// 每秒刷新的倒计时文案。
struct CountdownLabel: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(deadline.timeIntervalSince(context.date)))
            let minutes = remaining / 60
            let seconds = remaining % 60
            HStack(spacing: 7) {
                Image(systemName: "timer").foregroundStyle(.orange)
                Text(String(format: "剩余 %02d:%02d", minutes, seconds))
                    .font(.system(.body, design: .monospaced).weight(.medium))
            }
        }
    }
}
