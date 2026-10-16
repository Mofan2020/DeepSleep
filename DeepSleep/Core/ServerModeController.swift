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
//    - 「空闲」v1.6.1 路径用 IOHIDSystem 的 `HIDIdleTime` 读内核 HID idle time。
//      **这条路径在服务器模式下不可信**（v1.6.2 已弃用）：服务器模式开启后
//      DeepSleep 助手 + UURemote + 主进程自己持有 `PreventUserIdleSystemSleep`
//      断言，powerd 会停止累加 `HIDIdleTime`，实测 30 秒不动机器它只在
//      0~1.5 秒之间反复跳，永远不会增长到阈值 → 「倒计时永远不动 / 到点
//      也不息屏」。详见 `Shared/IdleTime.swift` 注释。
//
//    - v1.6.2 起改用「应用层时间戳 + CGEvent tap」：
//        * 开启服务器模式时记 `lastActivityAt = Date()`
//        * 用 `CGEvent.tapCreate(.listenOnly, .headInsertEventTap)` 监听
//          全局键盘 / 鼠标事件；每次事件来时把 `lastActivityAt` 重置为 `Date()`
//        * 5 秒一 tick 的 watchdog 直接比较 `now - lastActivityAt`
//          是否 ≥ `idleThresholdSeconds`
//
//    - CGEvent tap 需要 **Accessibility 授权**（`AXIsProcessTrusted`）。
//      没授权时 tap 不会被 fire，事件永远不来 —— 启用服务器模式前必须
//      先确认授权（调用 `AXIsProcessTrustedWithOptions(prompt: true)`
//      引导用户去系统设置）。未授权开启会直接拒绝并给出 banner 提示，
//      不允许「开了但倒计时永远不动」的退化状态存在。
//
//    - 关闭服务器模式 / app 退出时，调用 `CGEvent.tapEnable(tap, false)` +
//      `CFRelease(tap)` 彻底释放事件 tap。
//
//    - 真要锁屏走助手（sleepDisplay 命令）：关屏后 macOS 按"系统设置 → 锁屏 → 立即
//      要求密码"决定是否要求密码。**不**调用 ScreenSaverEngine —— 那是屏保动画，
//      不是锁屏。
//    - 关闭服务器模式时把缓存的 displaysleep 写回系统，
//      避免「服务器模式期间临时改的 displaysleep」留下来。
//

import AppKit
import ApplicationServices
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

    /// 应用层时间戳：上次侦听到的键盘 / 鼠标事件的时间。
    /// 解锁后立即置为 Date()，CGEvent tap 每次 fire 也置为 Date()。
    /// watchdog tick 比较 `Date().timeIntervalSince(lastActivityAt)`。
    /// 这条路径不依赖 powerd 的 `HIDIdleTime`，即使本进程持有 noidle 断言
    /// 也能正常工作（见 Shared/IdleTime.swift 注释）。
    private var lastActivityAt: Date = Date()

    /// CGEvent tap 全局监听键盘 / 鼠标事件。需要 Accessibility 授权。
    /// 未授权时 `tap` 为 nil，倒计时按"解锁后 5 秒 tick"粗粒度跑 —— 但
    /// `enable` 已经拒绝未授权开启，所以 `tap` 永远非 nil（运行时）。
    private var activityTap: CFMachPort?

    /// 用于清理 CGEvent tap 关联的 run loop source。
    private var activityTapSource: CFRunLoopSource?

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
        // CGEvent tap 需要 Accessibility 授权；未授权直接拒绝，
        // 不允许「开了但倒计时永远不动」的退化状态。`prompt: true` 会
        // 顺带弹一个 macOS 系统对话框让用户去设置授权。
        guard await ensureAccessibilityAuthorized(controller: controller) else {
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

        // 3. 启动 CGEvent tap 监听用户活动（用于解锁后的空闲判定）。
        //    没装成功（理论上 enable 已经过授权检查，所以不太可能）就
        //    直接拒绝开启 —— 倒计时不能多也不能少。
        guard installUserActivityMonitor() else {
            controller.appendLog("服务器模式：CGEvent tap 启动失败，已回滚", isError: true)
            controller.banner = Banner(level: .error, text: "服务器模式启动失败：CGEvent tap 创建失败")
            await controller.setSleepDisabled(false)
            phase = .off
            lastEventDescription = "启动失败"
            return
        }
    }

    /// 检查 Accessibility 授权。已授权返回 true；未授权时调用
    /// `AXIsProcessTrustedWithOptions(prompt: true)` 弹出系统对话框引导
    /// 用户去设置授权，然后等 1.5 秒看用户是否已经操作过。
    ///
    /// 返回 false 表示「未授权且用户也没在系统设置里勾上」。
    /// 内部用 banner 告知用户去「系统设置 → 隐私与安全性 → 辅助功能」勾选 DeepSleep。
    private func ensureAccessibilityAuthorized(controller: SleepController) async -> Bool {
        if isAccessibilityTrusted() { return true }

        // prompt: true 让系统弹一次授权对话框（用户可点「打开系统设置」）。
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)

        controller.banner = Banner(
            level: .info,
            text: "服务器模式需要在「系统设置 → 隐私与安全性 → 辅助功能」里勾选 Deep Sleep；勾完后重新点「开启」。"
        )
        controller.appendLog("服务器模式：等待用户在系统设置里授予 Accessibility 权限……", isError: false)

        // 给用户一点时间完成授权操作。最多等 30 秒，期间每 1 秒重检。
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if isAccessibilityTrusted() {
                controller.appendLog("服务器模式：Accessibility 授权已获得")
                controller.banner = nil
                return true
            }
        }
        controller.appendLog("服务器模式：Accessibility 授权未授予，已取消开启", isError: true)
        return false
    }

    private func isAccessibilityTrusted() -> Bool {
        // 不带 prompt 的纯查询；返回 Bool。
        return AXIsProcessTrusted()
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
        // 解锁这一瞬视为"刚刚用户操作过" —— 倒计时从这里开始算。
        lastActivityAt = Date()
        let interval: TimeInterval = 5
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickIdleWatchdog()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        phase = .waitingForIdle
        let remaining = Int(idleThresholdSeconds)
        lastEventDescription = "空闲倒计时：\(remaining) 秒后再次关屏"
    }

    private func tickIdleWatchdog() {
        guard phase == .waitingForIdle else { return }

        // 应用层时间戳：直接读 `lastActivityAt`，由 CGEvent tap 在每次
        // 键盘 / 鼠标事件来时重置为 `Date()`。这条路径不依赖 powerd 的
        // `HIDIdleTime`，因此即使本进程持有 noidle 断言（disablesleep +
        // Helper 的 PreventSystemSleep）也能正常累加空闲时间。
        let idle = Date().timeIntervalSince(lastActivityAt)

        if idle >= idleThresholdSeconds {
            watchdog?.invalidate()
            watchdog = nil
            Task { @MainActor in
                await performSleepAndLock()
            }
        } else {
            let remaining = max(0, Int(idleThresholdSeconds - idle))
            lastEventDescription = "空闲倒计时：\(remaining) 秒后再次关屏"
        }
    }

    // MARK: - CGEvent tap（监听用户键盘 / 鼠标活动）

    /// 用 `CGEvent.tapCreate(.listenOnly, .headInsertEventTap, ...)` 监听
    /// 全局键盘 / 鼠标事件；每次事件来时把 `lastActivityAt` 重置为 `Date()`。
    /// 需要 Accessibility 授权（`enable` 已检查）。
    ///
    /// 返回 true 表示 tap 装上、run loop source 装上、tap 已 enable；
    /// 返回 false 表示 tap 创建失败（极少见，可能是系统资源耗尽 / 沙盒限制）。
    @discardableResult
    private func installUserActivityMonitor() -> Bool {
        // 已经装上就认为成功。
        if activityTap != nil { return true }

        // kCGHIDEventTap + kCGHeadInsertEventTap + kCGEventTapOptionListenOnly
        // = 监听 HID 层所有键盘 / 鼠标事件，不拦截、不修改，不影响其他 app。
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.tabletPointer.rawValue) |
            (1 << CGEventType.tabletProximity.rawValue)

        // callback 必须用 @convention(c)，不能捕获 Swift 上下文，所以通过
        // userInfo 指针回传 `ServerModeController.shared`（它在 init 内
        // 设置一次，全进程唯一）。
        let proxy = Unmanaged.passUnretained(ServerModeController.shared).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { (_, _, _, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo else { return nil }
                let controller = Unmanaged<ServerModeController>.fromOpaque(userInfo).takeUnretainedValue()
                DispatchQueue.main.async {
                    controller.handleUserActivity()
                }
                // 返回 nil = 不拦截事件，让事件继续传给原目标。
                return nil
            },
            userInfo: proxy
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            // tap 已经创建但 source 没创建 —— 释放 tap 避免泄漏。
            CFMachPortInvalidate(tap)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.activityTap = tap
        self.activityTapSource = source
        self.lastActivityAt = Date()
        return true
    }

    /// CGEvent tap 回调（运行在 CoreFoundation 线程）。通过 DispatchQueue
    /// 跳回主线程改 `lastActivityAt`。`lastActivityAt` 是 MainActor 隔离的
    /// mutable 状态，必须在主线程改。
    private func handleUserActivity() {
        lastActivityAt = Date()
    }

    private func uninstallUserActivityMonitor() {
        if let tap = activityTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = activityTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        activityTap = nil
        activityTapSource = nil
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
