//
//  IdleTime.swift
//  Shared
//
//  系统最后一次输入（键盘 / 鼠标）距今多久。
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
