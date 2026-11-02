//
//  ServerModeView.swift
//  Deep Sleep
//
//  「服务器模式」设置页：开关、空闲阈值、最近事件。
//
//  跟系统监控 / 自动化规则的「监控 → 提示」不同：服务器模式是「持续运行状态」，
//  状态机归 `ServerModeController`，这里只是把状态可视化。
//
//  2026-11 界面换新：这一页要一眼看清三件事 ——
//  1) 现在是否在运行（StatusPill + 文字，颜色不单独承载信息）；
//  2) 自动锁屏的节奏（首次关屏延迟 + 空闲多少分钟再锁一次）；
//  3) 当前到底有哪些断言在阻止系统睡眠。
//  间距 / 圆角一律走 `DS.Space` / `DS.Radius`，不写字面量。
//

import SwiftUI

struct ServerModeView: View {

    @EnvironmentObject private var controller: SleepController
    @ObservedObject private var mode = ServerModeController.shared
    @State private var idleMinutes: Int = 10
    @State private var initialSleepSeconds: Int = 5
    @State private var detectionMode: IdleDetectionMode = .kernelIdle
    @State private var enablingError: String?

    private var isActive: Bool { mode.phase != .off }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            statusCard
            scheduleCard
            assertionsCard
            detectionCard
        }
        .onAppear {
            // 把 controller 当前值同步到控件初值。
            idleMinutes = Int(mode.idleThresholdSeconds / 60)
            initialSleepSeconds = Int(mode.initialSleepDelaySeconds)
            detectionMode = mode.idleDetectionMode
        }
    }

    // MARK: - 运行状态

    private var statusCard: some View {
        SectionCard(
            title: "服务器模式",
            subtitle: controller.helperState.isReady
                ? "开启后系统永不睡眠，\(initialSleepSeconds) 秒后关屏锁屏；空闲 \(idleMinutes) 分钟再重复。"
                : "请先在「完全控制」页安装助手。",
            symbol: "server.rack",
            accessory: AnyView(
                StatusPill(
                    text: statusTitle,
                    isActive: isActive,
                    color: isActive ? DS.Tone.good : DS.Tone.idle
                )
            )
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Toggle(isOn: Binding(
                    get: { isActive },
                    set: { newValue in
                        enablingError = nil
                        Task { await controller.setServerMode(newValue) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("永不睡眠 + 定时锁屏")
                            .font(.body.weight(.medium))
                        Text(isActive
                             ? "正在运行：系统不会睡眠，到点自动关屏并锁定。"
                             : "已关闭：系统按正常的电源设置睡眠。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!controller.helperState.isReady && !isActive)

                if isActive {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(DS.Tone.info)
                        Text(mode.lastEventDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let err = enablingError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DS.Tone.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 锁屏节奏

    private var scheduleCard: some View {
        SectionCard(
            title: "锁屏节奏",
            symbol: "timer"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Stepper(value: $initialSleepSeconds, in: 0...60, step: 1) {
                    LabeledContent("首次关屏延迟") {
                        Text("\(initialSleepSeconds) 秒")
                            .metricNumber(15)
                    }
                }
                .onChange(of: initialSleepSeconds) { _, v in
                    mode.initialSleepDelaySeconds = TimeInterval(v)
                }

                Stepper(value: $idleMinutes, in: 1...60, step: 1) {
                    LabeledContent("自动锁屏间隔") {
                        Text("\(idleMinutes) 分钟")
                            .metricNumber(15)
                    }
                }
                .onChange(of: idleMinutes) { _, v in
                    mode.idleThresholdSeconds = TimeInterval(v * 60)
                }

                Text("空闲按最后一次键盘或鼠标操作计时，屏幕关掉后暂停。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("锁屏需要系统设置 → 锁屏 →「立即要求密码」已勾选。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 关掉服务器模式或退出 Deep Sleep 会恢复系统原来的睡眠设置
                // —— 除非在「完全控制」页打开了「退出时保留当前的阻止睡眠设置」。
                // 这条必须写出来：用户开服务器模式跑长任务，关掉应用后 Mac
                // 又睡过去，会以为「永不睡眠」是系统级设置会留着。
                Text("关掉服务器模式或退出 Deep Sleep 会恢复系统原来的睡眠设置"
                     + "（除非在「完全控制」页打开了「退出时保留当前的阻止睡眠设置」）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 当前断言

    private var assertionsCard: some View {
        SectionCard(
            title: "当前阻止睡眠的请求",
            symbol: "lock.shield"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "powerplug")
                        .foregroundStyle(controller.sleepDisabled ? DS.Tone.good : DS.Tone.idle)
                        .frame(width: DS.Space.xl)
                    Text("系统永不睡眠")
                        .font(.body)
                    Spacer(minLength: DS.Space.sm)
                    Tag(
                        text: controller.sleepDisabled ? "已开启" : "未开启",
                        color: controller.sleepDisabled ? DS.Tone.good : DS.Tone.idle
                    )
                }

                if controller.activeAssertions.isEmpty {
                    EmptyStateView(
                        title: "当前没有阻止睡眠的请求",
                        message: "系统会按正常的电源设置睡眠。",
                        systemImage: "lock.open"
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(controller.activeAssertions.sorted { $0.rawValue < $1.rawValue }) { kind in
                            HStack(spacing: DS.Space.sm) {
                                Image(systemName: kind.symbolName)
                                    .foregroundStyle(DS.Tone.good)
                                    .frame(width: DS.Space.xl)
                                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                    Text(kind.title)
                                        .font(.body)
                                    Text(kind.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: DS.Space.sm)
                            }
                            .padding(.horizontal, DS.Space.md)
                            .padding(.vertical, DS.Space.sm)
                            if kind != controller.activeAssertions.sorted(by: { $0.rawValue < $1.rawValue }).last {
                                Divider()
                            }
                        }
                    }
                    .insetPanel()
                }
            }
        }
    }

    // MARK: - 空闲检测方式

    private var detectionCard: some View {
        SectionCard(
            title: "空闲检测方式",
            subtitle: "服务器模式开启后不能切换。",
            symbol: "clock.arrow.circlepath"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Picker("", selection: $detectionMode) {
                    ForEach(IdleDetectionMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isActive)
                .onChange(of: detectionMode) { _, v in
                    mode.idleDetectionMode = v
                }

                Text(detectionMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 状态

    private var statusTitle: String {
        switch mode.phase {
        case .off:                 return "未开启"
        case .starting:            return "开启中…"
        case .locked:              return "已熄屏锁定"
        case .waitingForIdle:      return "空闲倒计时中"
        }
    }
}
