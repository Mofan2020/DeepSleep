//
//  ServerModeView.swift
//  Deep Sleep
//
//  「服务器模式」设置页：开关、空闲阈值、最近事件。
//
//  跟系统监控 / 自动化规则的「监控 → 提示」不同：服务器模式是「持续运行状态」，
//  状态机归 `ServerModeController`，这里只是把状态可视化。
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
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(
                title: "服务器模式",
                subtitle: controller.helperState.isReady
                    ? "开启后系统永不睡眠，\(initialSleepSeconds) 秒后关屏锁屏；空闲 \(idleMinutes) 分钟再重复。"
                    : "请先在「完全控制」页安装助手。",
                symbol: "server.rack",
                accent: isActive ? .orange : .accentColor
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        StatusPill(text: statusTitle, isActive: isActive)
                        Spacer()
                        if isActive {
                            Button(role: .destructive) {
                                Task { await controller.setServerMode(false) }
                            } label: {
                                Label("关闭", systemImage: "stop.circle.fill")
                            }
                        } else {
                            Button {
                                enablingError = nil
                                Task { await controller.setServerMode(true) }
                            } label: {
                                Label("开启", systemImage: "play.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!controller.helperState.isReady)
                        }
                    }

                    if isActive {
                        Text(mode.lastEventDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let err = enablingError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            SectionCard(
                title: "空闲检测方式",
                subtitle: "两种方式都判断「距离你上次操作过去多久」；开启后不能切换，需先关闭服务器模式。",
                symbol: "clock.arrow.circlepath"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $detectionMode) {
                        ForEach(IdleDetectionMode.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.radioGroup)
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

            SectionCard(
                title: "参数",
                subtitle: "关闭后参数仍保留；下次开启沿用同一组值。",
                symbol: "slider.horizontal.3"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper(value: $initialSleepSeconds, in: 0...60, step: 1) {
                        Text("开启 \(initialSleepSeconds) 秒后首次关屏")
                    }
                    .onChange(of: initialSleepSeconds) { _, v in
                        mode.initialSleepDelaySeconds = TimeInterval(v)
                    }

                    Stepper(value: $idleMinutes, in: 1...60, step: 1) {
                        Text("空闲 \(idleMinutes) 分钟再次关屏")
                    }
                    .onChange(of: idleMinutes) { _, v in
                        mode.idleThresholdSeconds = TimeInterval(v * 60)
                    }

                    Text("空闲计时从你最后一次键盘 / 鼠标操作开始算。屏幕关掉之后计时停在零；你回来操作后重新从 \(idleMinutes) 分钟开始计。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SectionCard(
                title: "机制说明",
                subtitle: nil,
                symbol: "info.circle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    BulletLine("「系统永不睡眠」通过 `pmset disablesleep=1` + 特权助手持有的 PreventSystemSleep 断言双重落实，与「完全禁止睡眠」共用对账层。")
                    BulletLine("「关屏」走 `pmset displaysleepnow`，每次都会落日志。")
                    BulletLine("「锁屏」依赖系统设置 → 锁屏 → 「立即要求密码」：勾上之后，关屏即等同 macOS 要求输入密码。**首次开启前请确认该选项已勾选**，否则只会关屏，不会要求输密码。")
                    BulletLine("服务器模式期间，系统监控若启用：仅告警，不弹冻结 / 终结对话框 —— 不打扰后台服务进程。")
                    BulletLine("手动关闭或 Deep Sleep 退出时，`disablesleep` 自动恢复为 0。")
                }
            }
        }
        .onAppear {
            // 把 controller 当前值同步到控件初值。
            idleMinutes = Int(mode.idleThresholdSeconds / 60)
            initialSleepSeconds = Int(mode.initialSleepDelaySeconds)
            detectionMode = mode.idleDetectionMode
        }
    }

    private var statusTitle: String {
        switch mode.phase {
        case .off:                 return "未开启"
        case .starting:            return "开启中…"
        case .locked:              return "已熄屏锁定"
        case .waitingForIdle:      return "空闲倒计时中"
        }
    }
}
