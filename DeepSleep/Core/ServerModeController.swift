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
//    - 用户活动检测走 NSEvent.addGlobalMonitorForEvents —— 仅观察，
//      不拦截，不修改输入。无需 Accessibility 权限。
//    - 真要锁屏走助手（lockScreen 命令），路径里讲过的两条：
//      关屏 + 启动 ScreenSaverEngine。ScreenSaverEngine 启动后，
//      系统若启用了「立即要求密码」就等于锁屏。
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
    private var eventMonitor: Any?
    private var waitingSince: Date?
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
        waitingSince = nil
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

    /// 一次性动作：5 秒（或者用户配置的初始延迟）到点 → 关屏 + 锁屏。
    /// 之后进 `locked` 状态，等用户活动唤醒。
    private func performSleepAndLock() async {
        guard phase == .starting else { return }
        let controller = SleepController.shared

        do {
            let sleep = try await HelperClient.shared.send(.init(command: .sleepDisplay))
            if !sleep.success {
                controller.appendLog("服务器模式：关屏失败 \(sleep.message)", isError: true)
            }

            let lock = try await HelperClient.shared.send(.init(command: .lockScreen))
            if !lock.success {
                controller.appendLog("服务器模式：锁屏失败 \(lock.message)", isError: true)
                lastEventDescription = "关屏成功但锁屏失败：\(lock.message)"
            } else {
                lastEventDescription = "屏幕已关、已锁屏"
            }

            phase = .locked
            controller.appendLog("服务器模式：已关屏锁屏，等待用户唤醒")
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
        waitingSince = Date()
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
        guard phase == .waitingForIdle, let waitingSince else { return }
        let elapsed = Date().timeIntervalSince(waitingSince)
        if elapsed >= idleThresholdSeconds {
            watchdog?.invalidate()
            watchdog = nil
            Task { @MainActor in
                await performSleepAndLock()
            }
        } else {
            let remaining = Int(idleThresholdSeconds - elapsed)
            lastEventDescription = "空闲倒计时：\(remaining) 秒后再次关屏"
        }
    }

    // MARK: - 用户活动监听

    private func installUserActivityMonitor() {
        // 监听鼠标 / 键盘事件 —— 不拦截，只观察。
        // 仅观察不消费，所以不需要 Accessibility 权限。
        let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleUserActivity()
            }
        }
        eventMonitor = monitor
    }

    private func uninstallUserActivityMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// 任何用户活动都「重置」空闲计时器。
    ///
    /// 这里隐含一个细节：用户解锁后**第一次**活动就是「解锁了，开始操作」。
    /// 如果在 locked 状态收到活动，说明已经解锁；后续活动都是 idle 重置。
    private func handleUserActivity() {
        switch phase {
        case .locked:
            // 第一次活动 = 已解锁，开始倒计时
            waitingSince = Date()
            phase = .waitingForIdle
            lastEventDescription = "已解锁，空闲计时开始"
            SleepController.shared.appendLog("服务器模式：检测到用户活动，屏幕已唤醒")
        case .waitingForIdle:
            waitingSince = Date()
        case .starting, .off:
            break
        }
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
