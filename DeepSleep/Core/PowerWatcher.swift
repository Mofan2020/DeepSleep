//
//  PowerWatcher.swift
//  Deep Sleep
//
//  系统电源事件监听：在「即将睡眠」的瞬间抢一次对账机会，并在唤醒后立即对账。
//
//  为什么必须有「睡前」这一层：
//    周期对账（3 秒一次）能覆盖空闲睡眠 —— idle timer 通常以分钟计，来得及。
//    但盖不上主动睡眠请求：合盖、苹果菜单「睡眠」、`pmset sleepnow` 都是
//    立即触发的，只有在收到 willSleep 的这一刻介入才有机会阻止。
//
//  机制：
//    IORegisterForSystemPower 注册电源通知端口。收到 kIOMessageSystemWillSleep 时，
//    系统会等待我们调用 IOAllowPowerChange 才继续睡眠（最长约 30 秒）。
//    只要在这段窗口里把防护重新建立起来（重新写入 pmset + 重建 assertion），
//    powerd 就会取消这次睡眠。
//
//  安全边界（很重要）：
//    如果用户并没有要求阻止睡眠，必须**立即**放行，否则会无端延迟用户的正常睡眠。
//    只有在「期望阻止睡眠」时才进入延迟路径，并且始终设置兜底超时，
//    绝不允许出现「永远不放行」的状态。
//

import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - IOKit 电源消息常量
//
// IOMessage.h 里这些常量由 C 宏 iokit_common_msg() 定义，Swift 无法导入宏，
// 因此按同样的位运算规则复现。message 参数取自 SDK 头文件 IOMessage.h：
//     kIOMessageCanSystemSleep     = iokit_common_msg(0x270)
//     kIOMessageSystemWillSleep    = iokit_common_msg(0x280)
//     kIOMessageSystemHasPoweredOn = iokit_common_msg(0x300)
// 复现结果已用 C 程序编译比对，分别为 0xE0000270 / 0xE0000280 / 0xE0000300。
private func iokitCommonMessage(_ message: UInt32) -> natural_t {
    let sysIOKit: UInt32 = 0x38 << 26        // err_system(0x38)
    let subIOKitCommon: UInt32 = 0           // err_sub(0)
    return natural_t(sysIOKit | subIOKitCommon | message)
}

private let powerMessageCanSystemSleep = iokitCommonMessage(0x270)
private let powerMessageSystemWillSleep = iokitCommonMessage(0x280)
private let powerMessageSystemHasPoweredOn = iokitCommonMessage(0x300)

final class PowerWatcher {

    static let shared = PowerWatcher()

    /// 系统即将睡眠时调用。返回 true 表示「我们希望阻止这次睡眠」，
    /// 调用方需要在这段窗口里重建防护。
    ///
    /// 返回值必须是同步得到的快速判断（只读内存状态），不能做 IO ——
    /// 它处在系统的睡眠等待路径上。
    var shouldPreventSleep: (() -> Bool)?

    /// 需要重建防护时调用（异步，可以放心做 IO）。
    var rebuildProtection: (() async -> Bool)?

    /// 系统已唤醒，或防护重建完成后的对账。
    var didWake: (() -> Void)?

    /// 兜底放行延迟：即使用户要求阻止睡眠，也不会把系统吊住超过这个时间。
    private let allowTimeout: TimeInterval = 5

    private var connect: io_connect_t = 0
    private var notifierObject: io_object_t = 0
    private var notificationPort: IONotificationPortRef?
    private(set) var isRegistered = false

    private init() {}

    // MARK: - 注册

    func start() {
        guard !isRegistered else { return }

        // refcon 不持有引用，因此 PowerWatcher 必须是长生命周期单例。
        let context = Unmanaged.passUnretained(self).toOpaque()
        var port: IONotificationPortRef?

        var notifier: io_object_t = 0
        let rootPort = IORegisterForSystemPower(
            context,
            &port,
            deepSleepPowerCallback,
            &notifier
        )

        guard rootPort != 0, let port else {
            NSLog("[DeepSleep] 电源事件注册失败：IORegisterForSystemPower 未返回有效端口")
            return
        }

        self.connect = rootPort
        self.notificationPort = port
        self.notifierObject = notifier

        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        isRegistered = true
        NSLog("[DeepSleep] 已注册系统电源事件监听（睡前拦截 + 唤醒对账）")
    }

    func stop() {
        guard isRegistered else { return }
        if notifierObject != 0 {
            IODeregisterForSystemPower(&notifierObject)
            notifierObject = 0
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
        if connect != 0 {
            IOServiceClose(connect)
            connect = 0
        }
        isRegistered = false
    }

    // MARK: - 事件处理

    fileprivate func handle(messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case powerMessageSystemWillSleep:
            let wantsPrevent = shouldPreventSleep?() ?? false
            if wantsPrevent {
                NSLog("[DeepSleep] 系统即将睡眠，但用户要求保持清醒 —— 尝试重建防护")
                preventSleepOrGiveUp(argument: argument)
            } else {
                // 用户没有要求阻止，立刻放行。绝不无端拖延正常睡眠。
                allowSleep(argument: argument)
            }

        case powerMessageSystemHasPoweredOn:
            NSLog("[DeepSleep] 系统已唤醒，触发对账")
            didWake?()

        case powerMessageCanSystemSleep:
            // 已废弃的「能否睡眠」查询阶段，直接放行，决策留到 willSleep。
            allowSleep(argument: argument)

        default:
            break
        }
    }

    /// 重建防护；无论成功与否都会在超时后放行，避免把系统吊死。
    private func preventSleepOrGiveUp(argument: UnsafeMutableRawPointer?) {
        guard let rebuildProtection else {
            allowSleep(argument: argument)
            return
        }

        // 兜底：到了时间无论如何都放行。
        let deadline = DispatchWorkItem { [weak self] in
            self?.allowSleep(argument: argument)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + allowTimeout, execute: deadline)

        Task { @MainActor in
            let rebuilt = await rebuildProtection()
            deadline.cancel()
            if rebuilt {
                NSLog("[DeepSleep] 防护已重建，放行本次睡眠等待；powerd 应据此取消睡眠")
            } else {
                NSLog("[DeepSleep] 防护重建失败，放行本次睡眠")
            }
            // 重建成功后也放行：此时 assertion / pmset 已重新生效，
            // powerd 会在决策阶段看到它们并取消睡眠。
            // 若迟迟不调用 IOAllowPowerChange，系统只会在超时后强制睡眠，
            // 反而让状态更不可控。
            allowSleep(argument: argument)
        }
    }

    /// 只放行一次，重复调用是无效的（系统已销毁对应的 notification id）。
    private var allowedIdentifiers: Set<Int> = []

    private func allowSleep(argument: UnsafeMutableRawPointer?) {
        let identifier = Int(bitPattern: argument)
        guard !allowedIdentifiers.contains(identifier) else { return }
        allowedIdentifiers.insert(identifier)

        // 避免集合无限增长：保留最近 64 个即可。
        if allowedIdentifiers.count > 64 {
            allowedIdentifiers.removeAll()
        }

        IOAllowPowerChange(connect, intptr_t(bitPattern: argument))
    }
}

// MARK: - C 回调

/// 必须是自由函数（不能是捕获上下文的闭包）才能作为 C 函数指针传入。
private func deepSleepPowerCallback(
    refcon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: natural_t,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let watcher = Unmanaged<PowerWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handle(messageType: messageType, argument: messageArgument)
}
