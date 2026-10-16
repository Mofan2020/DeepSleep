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
//      涉及到事件监听、定时器、跨进程通讯给助手发命令，
//      放进 SleepController 会把它从「对账核心」变成「多功能管家」，
//      反而破坏现有 macOS 行为（参见 2026-10-06 的边界约定）。
//    - 抽出来独立 controller，SleepController 仅通过
//      `setServerMode(_:)` 钩入；任何时候关闭这个 controller，
//      SleepController 仍然跑自己的对账。
//
//  ## 状态机（v1.6.3）
//
//      off
//       │ setEnabled(true)
//       ▼
//      starting ──(initialSleepDelaySeconds 后)──▶ 关屏 ──▶ locked
//                                                            ▲
//                         ┌──────────────────────────────────┘
//                         │ 用户操作（idle 掉回阈值以下）
//                         ▼
//                   waitingForIdle ──(idle ≥ 阈值)──▶ 关屏 ──┘
//
//    `locked` 语义：屏幕已关、系统未睡，倒计时**保持归零**且不重复关屏；
//    只有检测到用户操作（idle 归零）才回到 `waitingForIdle` 重新计时。
//
//  ## 空闲检测（双模式）
//
//  见 `IdleDetectionMode`。默认 `kernelIdle`（v1.6.1 方案，不需要授权）；
//  `eventTap`（v1.6.2 方案）需要 Accessibility 授权，作为可选项保留。
//
//  两种模式共用同一个判据 `currentIdleSeconds()`，语义都是「距离用户上次
//  操作过去多久」，所以 tick 不需要知道自己在哪个模式里跑：
//
//    - kernelIdle：`IdleTime.systemIdleSeconds()`（IOHIDSystem.HIDIdleTime）
//    - eventTap：`Date().timeIntervalSince(lastActivityAt)`，由 CGEvent tap 重置
//
//  ## 安全边界
//
//    - 关屏走助手（`sleepDisplay` → `pmset displaysleepnow`）。
//      **不**调用 ScreenSaverEngine —— 那是屏保动画，不是锁屏。
//      关屏后 macOS 按「系统设置 → 锁屏 → 立即要求密码」决定是否要求密码。
//    - 关闭服务器模式时把缓存的 displaysleep 写回系统。
//    - `kernelIdle` 在服务器模式下是否可靠存在不确定性：本进程持 noidle
//      断言时 powerd 可能停止累加 HIDIdleTime。因此保留双模式。
//
//  详见 `Shared/IdleTime.swift` 与 `docs/gotchas.md` 第 17 节。
//

import AppKit
import ApplicationServices
import Combine
import Foundation

/// 空闲检测方式。
enum IdleDetectionMode: String, CaseIterable, Identifiable {
    /// 内核空闲计时（v1.6.1 方案）：轮询 `IOHIDSystem.HIDIdleTime`。
    /// 不需要任何授权，因此作为默认。
    case kernelIdle
    /// 事件监听（v1.6.2 方案）：CGEvent tap 监听全局键盘 / 鼠标事件。
    /// 需要「辅助功能」授权；未授权时 tap 不会 fire。
    case eventTap

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kernelIdle: return "内核空闲计时"
        case .eventTap:   return "事件监听（实验）"
        }
    }

    var summary: String {
        switch self {
        case .kernelIdle:
            return "读系统内核维护的空闲时间，不需要任何授权。"
        case .eventTap:
            return "监听全局键盘 / 鼠标事件，需要「辅助功能」授权；未授权时不会生效。"
        }
    }
}

/// 服务器模式运行状态（公开给 UI + 日志）。
@MainActor
final class ServerModeController: ObservableObject {

    static let shared = ServerModeController()

    /// 运行阶段。判定逻辑与语义见 `Shared/ServerModeIdlePolicy.swift`。
    typealias Phase = ServerModeIdlePolicy.Phase
    /// 一次 tick 的判定结果。
    typealias TickDecision = ServerModeIdlePolicy.Decision

    @Published private(set) var phase: Phase = .off
    @Published private(set) var lastEventDescription: String = ""

    /// 「空闲多久后再次关屏锁屏」。默认 10 分钟。
    @Published var idleThresholdSeconds: TimeInterval = 10 * 60

    /// 「从开始到首次关屏」的延迟。默认 5 秒。
    @Published var initialSleepDelaySeconds: TimeInterval = 5

    /// 空闲检测方式。默认 `kernelIdle`（不需要授权）。
    @Published var idleDetectionMode: IdleDetectionMode = .kernelIdle {
        didSet {
            guard oldValue != idleDetectionMode else { return }
            UserDefaults.standard.set(idleDetectionMode.rawValue, forKey: Self.modeKey)
        }
    }

    private static let modeKey = "ServerModeController.idleDetectionMode"

    /// 全程 5 秒 tick。从 enable 起一直活到 disable。
    ///
    /// **不**在关屏时停掉：否则「用户回来了」就没人监听，界面会永远停在
    /// 归零不动（v1.6.2 的 bug 之一）。
    private var tickTimer: Timer?
    /// 「首次关屏」的一次性定时器。
    private var initialSleepTimer: Timer?
    /// 关屏动作进行中 —— 防止 tick 与一次性定时器重入。
    private var isPerformingSleep = false

    /// 应用层时间戳：上次侦听到的键盘 / 鼠标事件的时间。仅 `eventTap` 模式用。
    private var lastActivityAt: Date = Date()

    /// CGEvent tap 全局监听键盘 / 鼠标事件。仅 `eventTap` 模式用。
    private var activityTap: CFMachPort?
    /// 用于清理 CGEvent tap 关联的 run loop source。
    private var activityTapSource: CFRunLoopSource?

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.modeKey),
           let mode = IdleDetectionMode(rawValue: raw) {
            idleDetectionMode = mode
        }
    }

    // MARK: - 空闲判据

    /// 当前空闲秒数 —— 两种模式在这里统一。
    ///
    /// 语义是「距离用户上次操作过去多久」：
    ///   - `kernelIdle`：直接问系统
    ///   - `eventTap`：用事件 tap 重置过的时间戳自己算
    func currentIdleSeconds() -> TimeInterval {
        switch idleDetectionMode {
        case .kernelIdle:
            return IdleTime.systemIdleSeconds() ?? 0
        case .eventTap:
            return Date().timeIntervalSince(lastActivityAt)
        }
    }

    // MARK: - 状态机（纯逻辑见 Shared/ServerModeIdlePolicy.swift）

    /// 给定状态与空闲秒数，决定这一 tick 该做什么。
    static func decide(phase: Phase,
                       idle: TimeInterval,
                       threshold: TimeInterval) -> TickDecision {
        ServerModeIdlePolicy.decide(phase: phase, idle: idle, threshold: threshold)
    }

    // MARK: - 开关

    /// 开启 / 关闭服务器模式。
    ///
    /// 开启依赖：
    ///   1. 助手已 ready（发命令需要它）
    ///   2. `eventTap` 模式下需要辅助功能授权
    ///   3. 用户授权（沿用 SleepController 的 confirmPrivilegedAction）
    ///   4. 已开启 disablesleep（最稳的「系统不睡」手段）
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
        // 只有事件监听模式需要辅助功能授权。未授权时明确拒绝，不静默降级 ——
        // 用户选了哪个模式就该跑哪个模式。
        if idleDetectionMode == .eventTap {
            let authorized = await ensureAccessibilityAuthorized(controller: controller)
            guard authorized else { return }
        }
        guard await controller.confirmPrivilegedAction(reason: "允许 Deep Sleep 开启服务器模式") else {
            return
        }

        phase = .starting
        controller.appendLog("服务器模式已开启（空闲检测：\(idleDetectionMode.displayName)）："
                             + "\(initialSleepDelaySeconds) 秒后关屏锁屏")
        lastEventDescription = "开启中……"

        // 1. 先把 disablesleep 打开 —— 这是「系统不睡」的兜底层。
        await controller.setSleepDisabled(true)

        // 2. 事件监听模式才装 tap；失败即回滚（不留下跑不动的模式）。
        if idleDetectionMode == .eventTap, !installUserActivityMonitor() {
            controller.appendLog("服务器模式：CGEvent tap 启动失败，已回滚", isError: true)
            controller.banner = Banner(
                level: .error,
                text: "事件监听模式启动失败：无法创建 CGEvent tap。可改用「内核空闲计时」模式。")
            await controller.setSleepDisabled(false)
            phase = .off
            lastEventDescription = "启动失败"
            return
        }

        // 3. 首次关屏：一次性定时器。
        scheduleInitialSleepAndLock()
        // 4. 全程 5 秒 tick：负责「用户回来 → 重新计时 → 再次关屏」。
        startTickTimer()
    }

    /// 检查辅助功能授权。已授权返回 true；未授权时调
    /// `AXIsProcessTrustedWithOptions(prompt: true)` 弹系统对话框引导用户
    /// 去设置，然后最多等 30 秒重检。
    private func ensureAccessibilityAuthorized(controller: SleepController) async -> Bool {
        if isAccessibilityTrusted() { return true }

        // prompt: true 让系统弹一次授权对话框（用户可点「打开系统设置」）。
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )

        controller.banner = Banner(
            level: .info,
            text: "「事件监听」模式需要在「系统设置 → 隐私与安全性 → 辅助功能」里勾选 Deep Sleep，"
                + "勾完后重新点「开启」。不想授权可改用「内核空闲计时」模式。"
        )
        controller.appendLog("服务器模式：等待用户在系统设置里授予辅助功能权限……")

        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if isAccessibilityTrusted() {
                controller.appendLog("服务器模式：辅助功能授权已获得")
                controller.banner = nil
                return true
            }
        }
        controller.appendLog("服务器模式：未获得辅助功能授权，已取消开启", isError: true)
        return false
    }

    private func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func disable(on controller: SleepController) async {
        guard phase.isActive else { return }
        controller.appendLog("正在退出服务器模式……")
        uninstallUserActivityMonitor()
        initialSleepTimer?.invalidate()
        initialSleepTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        isPerformingSleep = false
        phase = .off
        lastEventDescription = "已关闭"
        controller.appendLog("服务器模式已关闭")
    }

    // MARK: - 关屏 + 锁屏

    private enum SleepTrigger {
        /// 开启后的首次关屏
        case initial
        /// 空闲倒计时到点后的关屏
        case idleTimeout
    }

    /// 首次关屏：`initialSleepDelaySeconds` 后执行一次。
    private func scheduleInitialSleepAndLock() {
        initialSleepTimer?.invalidate()
        let delay = max(0, initialSleepDelaySeconds)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.performSleepAndLock(reason: .initial)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        initialSleepTimer = timer
    }

    /// 关屏（等同锁屏，前提是系统设置勾了「立即要求密码」）。
    ///
    /// v1.6.3 修掉了 v1.6.2 的阻塞 bug：旧实现开头是
    /// `guard phase == .starting else { return }`，而倒计时到点时
    /// phase 已是 `.waitingForIdle` —— 于是直接被挡回，屏幕不关。
    /// 表现为「首次 5 秒关屏正常，但倒计时归零后没反应」。
    /// 现在两条路径都能进来。
    private func performSleepAndLock(reason: SleepTrigger) async {
        guard !isPerformingSleep else { return }
        switch reason {
        case .initial:
            guard phase == .starting else { return }
        case .idleTimeout:
            guard phase == .waitingForIdle else { return }
        }

        isPerformingSleep = true
        defer { isPerformingSleep = false }

        let controller = SleepController.shared
        do {
            let sleep = try await HelperClient.shared.send(.init(command: .sleepDisplay))
            if !sleep.success {
                controller.appendLog("服务器模式：关屏失败 \(sleep.message)", isError: true)
                lastEventDescription = "关屏失败：\(sleep.message)"
                return
            }
            if reason == .initial {
                initialSleepTimer?.invalidate()
                initialSleepTimer = nil
            }
            phase = .locked
            lastEventDescription = "已熄屏锁定；倒计时保持归零，你回来操作后重新计时"
            controller.appendLog(reason == .initial
                                 ? "服务器模式：已关屏，等待用户唤醒"
                                 : "服务器模式：空闲到点，已再次关屏")
        } catch {
            controller.appendLog("服务器模式：与助手通信失败 \(error.localizedDescription)",
                                 isError: true)
            lastEventDescription = "与助手通信失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 全程 tick

    /// 每 5 秒读一次空闲秒数，交给 `decide` 决定下一步。
    private func startTickTimer() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        let idle = currentIdleSeconds()
        switch Self.decide(phase: phase, idle: idle, threshold: idleThresholdSeconds) {
        case .idle:
            return
        case .countdown(let remaining):
            if phase == .locked {
                // 用户回来了（idle 已掉回阈值以下）—— 从此刻重新计时。
                phase = .waitingForIdle
            }
            lastEventDescription = "空闲倒计时：\(remaining) 秒后再次关屏"
        case .sleepNow:
            lastEventDescription = "空闲到点，正在关屏……"
            Task { @MainActor in
                await performSleepAndLock(reason: .idleTimeout)
            }
        case .holdAtZero:
            lastEventDescription = "已熄屏锁定；倒计时保持归零，你回来操作后重新计时"
        }
    }

    // MARK: - CGEvent tap（仅 eventTap 模式）

    /// 用 `CGEvent.tapCreate(.listenOnly, .headInsertEventTap, ...)` 监听
    /// 全局键盘 / 鼠标事件；每次事件来时把 `lastActivityAt` 重置为 `Date()`。
    /// 需要辅助功能授权（`enable` 已检查）。
    @discardableResult
    private func installUserActivityMonitor() -> Bool {
        if activityTap != nil { return true }

        // kCGSessionEventTap + kCGHeadInsertEventTap + kCGEventTapOptionListenOnly
        // = 监听所有键盘 / 鼠标事件，不拦截、不修改，不影响其他 app。
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

        // callback 必须是 @convention(c)，不能捕获 Swift 上下文 —— 通过
        // userInfo 指针回传单例。
        let proxy = Unmanaged.passUnretained(ServerModeController.shared).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { (_, _, _, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo else { return nil }
                let controller = Unmanaged<ServerModeController>
                    .fromOpaque(userInfo).takeUnretainedValue()
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
            // tap 已创建但 source 没创建 —— 释放 tap 避免泄漏。
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

    /// CGEvent tap 回调。跳回主线程改 `lastActivityAt`（MainActor 隔离）。
    private func handleUserActivity() {
        lastActivityAt = Date()
        // 已熄屏时用户回来了 —— 立刻切回倒计时，不等下一个 tick。
        if phase == .locked {
            phase = .waitingForIdle
            lastEventDescription = "空闲倒计时：\(Int(idleThresholdSeconds)) 秒后再次关屏"
        }
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
