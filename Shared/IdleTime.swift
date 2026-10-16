//
//  IdleTime.swift
//  Shared
//
//  系统空闲时间（距离上次键盘 / 鼠标输入的秒数）。
//
//  ⚠️ 重要边界（macOS 26 实测，2026-10-15，v1.6.2）：
//    当任意进程持有 `PreventUserIdleSystemSleep` 类型的 noidle 断言时
//    （例如 DeepSleep 助手 + UURemote + DeepSleep 主进程自己持有
//    `IOPMAssertionCreateWithName(...)`），powerd 会停止累加 IOHIDSystem
//    的 `HIDIdleTime` 计数器。这个值会在 powerd 偶尔处理别的 I/O 时
//    被短暂刷新、然后又停滞，**不**会按真实挂钟累加。
//
//    也就是说，服务器模式（开启后 `pmset disablesleep=1` + Helper 持
//    noidle 断言）这个核心使用场景下，`systemIdleSeconds()` 不可信。
//    实测 30 秒不动机器，值在 0~1.5 秒之间反复跳，从未单调递增到 10 秒以上。
//
//    **不要**在持有 noidle 断言的进程里把 `systemIdleSeconds()` 当
//    "距离上次输入秒数"用 —— 会导致「空闲计时永远不动」。
//
//  替代方案（v1.6.2 起，ServerModeController 使用）：
//    应用层时间戳 + CGEvent tap：
//      - 开启时记录 `lastActivityAt = Date()`
//      - CGEvent tap（需要 Accessibility 授权）监听全局键盘 / 鼠标事件，
//        每次来事件把 `lastActivityAt` 重置为现在
//      - 倒计时 watchdog 直接比较 `now - lastActivityAt`
//
//  本文件保留 `systemIdleSeconds()` 仅用于「非 noidle 场景」或调试；
//  新代码请用 ServerModeController 内部的应用层时间戳。
//
//  路径选择（macOS 26）：
//
//  公开 API（无需权限）：
//    IOHID 服务的 registry 属性 `HIDIdleTime` —— 由内核维护（`powerd` /
//    IOHIDSystem 共同更新），单位是**纳秒**。普通进程从 IOKit registry 读出即可。
//
//  旧实现的问题（v1.6.0 → v1.6.1）：
//    Deep Sleep 早期版本用 `NSEvent.addGlobalMonitorForEvents` 监听回调来识别
//    用户操作 —— 但该 API 必须有 Accessibility 授权才会真正回调，没授权时回调
//    根本不来，导致「用户在操作却仍被判为空闲」的假阴性。
//
//  改用 IOKit registry 直接读属性后，根本不依赖回调。这是 `pmset` 内部、
//    `caffeinate` 等所有关心空闲时间的工具用的同一来源。
//
//

import Foundation
import IOKit

public enum IdleTime {

    /// 系统最后一次键盘 / 鼠标输入距今的秒数。
    ///
    /// **警告**：当任意进程持有 `PreventUserIdleSystemSleep` 类型的 noidle 断言
    /// （DeepSleep 助手 + UURemote + 主进程自己持 noidle）时，powerd 会停止
    /// 累加这个值，返回的是 powerd 上次更新时的陈旧值，不可作为「距离上次
    /// 输入秒数」使用。请改用 `ServerModeController` 内部的应用层时间戳 +
    /// CGEvent tap。
    ///
    /// 进程刚启动、没有任何输入时返回 0；返回 `nil` 表示读不到（理论极少）。
    public static func systemIdleSeconds() -> TimeInterval? {
        let entry = IORegistryEntryFromPath(
            kIOMainPortDefault,
            "IOService:/IOResources/IOHIDSystem"
        )
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(
            entry, &unmanaged, kCFAllocatorDefault, 0
        )
        guard kr == KERN_SUCCESS else { return nil }
        guard let dict = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        // HIDIdleTime 是纳秒（UInt64），不是毫秒。这与 pmset 一致。
        guard let raw = dict["HIDIdleTime"] as? UInt64 else { return nil }
        return TimeInterval(raw) / 1_000_000_000
    }
}
