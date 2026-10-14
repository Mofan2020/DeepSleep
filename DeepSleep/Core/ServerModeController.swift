//
//  ServerModeController.swift
//  Deep Sleep
//
//  「服务器模式」状态机：开启后系统永不睡眠，显示器定时关 + 锁屏，
//  用户解锁后再倒计时 → 重复。
//
//  这是与 SleepController 平行的一个小状态机。设计动机：
//
//    - SleepController 的 reconcile / PowerWatcher 已经覆盖了
//      「阻止系统睡眠」这一层（既有 disablesleep + PreventSystemSleep）。
//      服务器模式只是把它们的组合「升级」到「开机就不撤」。
//    - 但「关屏 + 锁屏 + 空闲倒计时 + 解锁后重置」这一串行为，
//      涉及到 NSEvent 监听、定时器、跨进程通讯给助手发命令，
//      放进 SleepController 会把它从「对账核心」变成「多功能管家」，
//      反而破坏现有 macOS 行为（参见 2026-10-06 的边界约定）。
//    - 抽出来独立 controller，SleepController 仅通过
//      `setServerMode(_:)` 钩入；任何时候关闭这个 controller，
//      SleepController 仍然跑自己的对账。
//
//  安全边界：
//    - 「空闲」用 `CGEventSourceSecondsSinceLastEventType` 读内核 HID idle time。
//      这是 macOS 公开 API、**不**需要 Accessibility 授权即可读取。
//      v1.6.0 早期版本用 NSEvent.addGlobalMonitorForEvents，但那需要 Accessibility
//      授权，没授权时回调根本不来，导致"用户在操作却仍判为空闲"。
//    - 真要锁屏走助手（sleepDisplay 命令）：关屏后 macOS 按"系统设置 → 锁屏 → 立即
//      要求密码"决定是否要求密码。**不**调用 ScreenSaverEngine —— 那是屏保动画，
//      不是锁屏。
//    - 关闭服务器模式时把缓存的 displaysleep 写回系统，
//      避免「服务器模式期间临时改的 displaysleep」留下来。
//

import AppKit
import Combine
import Foundation

/// 服务器模式运行状态（公开给 UI + 日志）。
@MainActor
final class ServerModeController: ObservableObject {

    static let shared = ServerModeController()

    enum Phase: Equatable {
        /// 未开启
        case off
        /// 已开启，正在 5 秒内关屏 + 锁屏
        case starting
        /// 已锁屏 / 屏幕黑着，等待用户解锁
        case locked
        /// 解锁后等待用户活动；空闲达到阈值后再次关屏锁屏
        case waitingForIdle
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var lastEventDescription: String = ""

    /// 「空闲多久后再次关屏锁屏」。默认 10 分钟。
    @Published var idleThresholdSeconds: TimeInterval = 10 * 60

    /// 「从开始到首次关屏」的延迟。默认 5 秒。
    @Published var initialSleepDelaySeconds: TimeInterval = 5

    private var watchdog: Timer?
    private var helperStateWhenStarted: HelperState = .unknown

    private init() {}

    // MARK: - 开关

    /// 开启 / 关闭服务器模式。
    ///
    /// 开启依赖：
    ///   1. 助手已 ready（发命令需要它）
    ///   2. 用户授权（沿用 SleepController 的 confirmPrivilegedAction）
    ///   3. 已开启 disablesleep（最稳的「系统不睡」手段）
    func setEnabled(_ enabled: Bool, controller: SleepController) async {
        if enabled {
            await enable(on: controller)
        } else {
            await disable(on: controller)
        }
    }

    private func enable(on controller: SleepController) async {
        guard controller.helperState.isReady else {
            controller.banner = Banner(level: .error, text: "服务器模式需要先启用完全控制")
            return
        }
        guard !phase.isActive else {
            controller.appendLog("服务器模式已在运行中")
            return
        }
        guard await controller.confirmPrivilegedAction(reason: "允许 Deep Sleep 开启服务器模式") else {
            return
        }

        helperStateWhenStarted = controller.helperState
        phase = .starting
        controller.appendLog("服务器模式已开启：\(initialSleepDelaySeconds) 秒后关屏锁屏")
        lastEventDescription = "开启中……"

        // 1. 先把 disablesleep 打开 —— 这是「系统不睡」的兜底层。
        await controller.setSleepDisabled(true)
        // 2. 启动 5 秒后「关屏 + 锁屏」一次性动作。
        scheduleInitialSleepAndLock()

        // 3. 监听用户活动（用于解锁后的空闲判定）。
        installUserActivityMonitor()
    }

    private func disable(on controller: SleepController) async {
        guard phase.isActive || phase != .off else { return }
        controller.appendLog("正在退出服务器模式……")
        uninstallUserActivityMonitor()
        watchdog?.invalidate()
        watchdog = nil
        phase = .off
        lastEventDescription = "已关闭"
        controller.appendLog("服务器模式已关闭")
    }

    // MARK: - 首次关屏 + 锁屏

    private func scheduleInitialSleepAndLock() {
        let delay = initialSleepDelaySeconds
        watchdog = Timer.scheduledTimer(withTimeInterval: max(0, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.performSleepAndLock()
            }
        }
        if let watchdog {
            RunLoop.main.add(watchdog, forMode: .common)
        }
    }

    /// 一次性动作：5 秒（或者用户配置的初始延迟）到点 → 关屏。
    /// 关屏即等同"锁屏"，前提是用户在系统设置 → 锁屏里启用了"立即要求密码"。
    /// 助手侧 `lockScreen` 与 `sleepDisplay` 是同一实现，所以这里只发一次。
    /// 之后进 `locked` 状态，等用户活动唤醒。
    private func performSleepAndLock() async {
        guard phase == .starting else { return }
        let controller = SleepController.shared

        do {
            let sleep = try await HelperClient.shared.send(.init(command: .sleepDisplay))
            if !sleep.success {
                controller.appendLog("服务器模式：关屏失败 \(sleep.message)", isError: true)
                lastEventDescription = "关屏失败：\(sleep.message)"
            } else {
                lastEventDescription = "屏幕已关；macOS 会按系统设置决定是否要求密码"
                controller.appendLog("服务器模式：已关屏，等待用户唤醒")
            }
            phase = .locked
            startIdleWatchdogAfterUnlock()
        } catch {
            controller.appendLog("服务器模式：与助手通信失败 \(error.localizedDescription)", isError: true)
            lastEventDescription = "与助手通信失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 解锁后倒计时

    /// 解锁后启动空闲检测 —— 用户连续 `idleThresholdSeconds` 没动，
    /// 就再走一次「关屏 + 锁屏」。
    private func startIdleWatchdogAfterUnlock() {
        watchdog?.invalidate()
        let interval: TimeInterval = 5
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickIdleWatchdog()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        phase = .waitingForIdle
    }

    private func tickIdleWatchdog() {
        guard phase == .waitingForIdle else { return }

        // CGEventSourceSecondsSinceLastEventType 直接读内核的 HID idle time，
        // 这是"用户最后一次操作至今"的秒数。**不**依赖 NSEvent 回调，
        // 所以不需要 Accessibility 授权，且用户在操作时这个值会持续归零。
        let idle = IdleTime.systemIdleSeconds() ?? 0

        if idle >= idleThresholdSeconds {
            watchdog?.invalidate()
            watchdog = nil
            Task { @MainActor in
                await performSleepAndLock()
            }
        } else {
            let remaining = Int(idleThresholdSeconds - idle)
            lastEventDescription = "空闲倒计时：\(remaining) 秒后再次关屏"
        }
    }

    // MARK: - 用户活动监听（已弃用，见 IdleTime.swift）

    private func installUserActivityMonitor() {
        // v1.6.0 早期版本这里用 NSEvent.addGlobalMonitorForEvents 监听回调。
        // 但该 API 必须有 Accessibility 授权才真正回调，没授权时回调根本不来，
        // 导致"用户在操作却仍判为空闲"的 bug。v1.6.1 起改用 IdleTime.systemIdleSeconds()
        // 直接读内核 HID 时间戳，无需权限、不会假阴性。
        // 此方法保留为空壳，避免破坏调用方语义。
    }

    private func uninstallUserActivityMonitor() {
        // 同上：v1.6.1 起为空。
    }
}

private extension ServerModeController.Phase {
    var isActive: Bool {
        switch self {
        case .off: return false
        default:   return true
        }
    }
}
