//
//  RunStateRestorer.swift
//  Deep Sleep
//
//  启动时把上次的运行状态接回来：风扇控制、手动保持、定时保持、
//  完全禁止系统睡眠、服务器模式、逐应用音量。
//
//  ## 为什么不在 `SleepController.init` 里直接恢复
//
//  恢复要动助手（写 disablesleep、拿断言、关屏）和 CoreAudio（建引擎）。
//  应用刚起来那几百毫秒里这两样都还没就位：
//
//    - 助手是 launchd 托管的独立进程，冷启动时 socket 可能还没起来；
//    - 音频输出设备要等 coreaudiod 把设备枚举完；
//    - 风扇引擎自己还有一段「清上次残留」的启动流程。
//
//  在那时硬恢复，结果是一串必然失败的调用：断言拿不到、disablesleep 写不进
//  —— 用户看到的是「设置没恢复」，机器进入一种半失效状态。
//  所以这里先等环境，再逐项落实；等不到就跳过并说明原因，而不是抛错。
//
//  ## 恢复不等于「重新执行一次用户操作」
//
//  所有落实动作都带 `source: .restore`：不写存档（存档本来就是它）、
//  不弹提权确认（用户此前已经授权过同一件事，而且此刻他们往往不在屏幕前）。
//
//  ## 跳过要说出来
//
//  「重启后设置没了」如果只是静默发生，用户只会觉得应用不可靠。
//  每一项跳过都必须带得出口的原因（`RestoreSkipReason`）。
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
final class RunStateRestorer {

    static let shared = RunStateRestorer()

    /// 只跑一次。重复调用是安全的（bootstrap 与 CLI 参数都可能触发）。
    private var didRestore = false

    /// 等助手就绪的上限。助手是常驻进程，正常几百毫秒内就该应答；
    /// 超过这个时长还没起来，就按「没就绪」处理，不再让用户干等。
    private let helperWaitSeconds: TimeInterval = 5
    private let helperPollInterval: TimeInterval = 0.25

    private init() {}

    /// 启动恢复的入口。没有存档就什么都不做。
    func restoreIfNeeded() async {
        guard !didRestore else { return }
        didRestore = true

        guard let saved = RunStateStore.load(), !saved.isEmpty else { return }

        let controller = SleepController.shared
        let known = Set(AssertionKind.allCases.map(\.rawValue))
        let privileged = Set(AssertionKind.allCases.filter(\.requiresPrivilege).map(\.rawValue))

        // 只有存档里确实有「要助手才能恢复」的项，才值得等它。
        // 否则 `--status` 这类一次性命令行调用会白等几秒。
        if needsHelper(saved) {
            await waitForHelper(controller: controller)
        }

        let state = saved.retainingKnownAssertions(known)

        let environment = RestoreEnvironment(
            helperReady: controller.helperState.isReady,
            disclaimerAccepted: FanDisclaimer.isAccepted,
            serverModeNeedsAccessibility: ServerModeController.shared.idleDetectionMode == .eventTap,
            accessibilityAuthorized: AXIsProcessTrusted(),
            knownAssertions: known,
            privilegedAssertions: privileged
        )

        let entries = state.restoreEntries(environment: environment)
        guard !entries.isEmpty else { return }

        // 定时保持已经过期：那一批保持本该在到点时全部释放。应用当时不在，
        // 释放没发生。这里把存档一起清掉，否则每次启动都会再提示一遍「已到期」。
        if let deadline = state.holdUntil, deadline <= Date() {
            RunStateStore.update { saved in
                saved.manualAssertions = []
                saved.holdUntil = nil
            }
        }

        var restored: [String] = []
        var skipped: [String] = []

        // 断言先落：后面几项（服务器模式、风扇）与它们互不影响，
        // 但断言是「保持清醒」最直接的一层，先把这层接回来最符合预期。
        for entry in entries {
            switch entry.item {
            case .assertion(let raw):
                guard let kind = AssertionKind(rawValue: raw) else { continue }
                if case .restore = entry.action {
                    await controller.setAssertion(kind, enabled: true, source: .restore)
                    if controller.activeAssertions.contains(kind) {
                        restored.append(kind.title)
                    } else {
                        skipped.append("\(kind.title)（未能生效）")
                    }
                } else {
                    skipped.append("\(describe(entry))")
                }

            case .holdDeadline:
                if case .restore = entry.action, let deadline = state.holdUntil {
                    controller.restoreHoldDeadline(until: deadline)
                    restored.append("定时保持（到 \(Self.timeText(deadline)) 自动释放）")
                } else {
                    skipped.append(describe(entry))
                }

            case .sleepDisabled:
                if case .restore = entry.action {
                    await controller.setSleepDisabled(true, source: .restore)
                    // 用实际写入结果判断，而不是意图：applySleepDisabled 失败时
                    // desiredSleepDisabled 仍是 true（对账会继续纠），但这次确实没恢复。
                    if controller.sleepDisabled {
                        restored.append("完全禁止系统睡眠")
                    } else {
                        skipped.append("完全禁止系统睡眠（未能生效）")
                    }
                } else {
                    skipped.append(describe(entry))
                }

            case .serverMode:
                if case .restore = entry.action {
                    await ServerModeController.shared.setEnabled(true, controller: controller,
                                                                 source: .restore)
                    if ServerModeController.shared.phase.isActive {
                        restored.append("服务器模式")
                    } else {
                        skipped.append("服务器模式（未能生效）")
                    }
                } else {
                    skipped.append(describe(entry))
                }

            case .fanControl:
                if case .restore = entry.action {
                    // 风扇引擎启动时会先「清上次残留」把控制权交回系统，
                    // 必须等它跑完再开启，否则刚恢复就被自己清掉。
                    await FanController.shared.waitUntilStarted()
                    await FanController.shared.setEnabled(true, source: .restore)
                    if FanController.shared.isEnabled {
                        restored.append("风扇控制")
                    } else {
                        skipped.append("风扇控制（未能生效）")
                    }
                } else {
                    skipped.append(describe(entry))
                }
            }
        }

        // 逐应用音量：存储本来就在 `AudioControlManager` 自己的 suite 里，
        // 这里只负责把它叫起来、并把「哪些应用还没回来」讲清楚。
        AudioControlManager.shared.reportRestoredVolumes()

        report(restored: restored, skipped: skipped, controller: controller)
    }

    // MARK: - 环境就绪

    /// 存档里有没有「非助手不可」的项。
    private func needsHelper(_ state: RunState) -> Bool {
        if state.fanControlEnabled || state.sleepDisabled || state.serverModeEnabled {
            return true
        }
        let privileged = Set(AssertionKind.allCases.filter(\.requiresPrivilege).map(\.rawValue))
        return state.manualAssertions.contains { privileged.contains($0) }
    }

    /// 等助手应答。没装助手就不等 —— 那是「没启用完全控制」，不是「还没起来」。
    private func waitForHelper(controller: SleepController) async {
        guard HelperInstaller.isInstalled else { return }
        if controller.helperState.isReady { return }

        let deadline = Date().addingTimeInterval(helperWaitSeconds)
        while Date() < deadline {
            await controller.refreshHelperState()
            if controller.helperState.isReady { return }
            try? await Task.sleep(nanoseconds: UInt64(helperPollInterval * 1_000_000_000))
        }
        controller.appendLog("启动恢复：等了 \(Int(helperWaitSeconds)) 秒助手仍未就绪，"
                             + "需要助手的状态项将被跳过", isError: true)
    }

    // MARK: - 汇报

    private func report(restored: [String],
                        skipped: [String],
                        controller: SleepController) {
        guard !restored.isEmpty || !skipped.isEmpty else { return }

        if !restored.isEmpty {
            controller.appendLog("已恢复上次的运行状态：\(restored.joined(separator: "、"))")
        }
        if !skipped.isEmpty {
            controller.appendLog("以下状态本次未能恢复：\(skipped.joined(separator: "；"))",
                                 isError: true)
        }

        // 只恢复了一部分时才打扰用户：全成功就只写日志，别每次开机都弹一条。
        guard !skipped.isEmpty else { return }
        controller.banner = Banner(
            level: .error,
            text: "上次的部分设置未能恢复：\(skipped.joined(separator: "；"))"
        )
    }

    private func describe(_ entry: RestoreEntry) -> String {
        switch entry.action {
        case .restore:
            return entry.item.description
        case .skip(let reason):
            return "\(entry.item.description)（\(reason.explanation)）"
        }
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
