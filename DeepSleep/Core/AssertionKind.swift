//
//  AssertionKind.swift
//  Deep Sleep
//
//  电源 assertion 的类型定义。这是整个应用的能力清单。
//

import Foundation

/// app 可以申请持有的电源 assertion。
enum AssertionKind: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 阻止空闲系统睡眠。等价于 `caffeinate -i`，无需特权。
    case preventIdleSystemSleep
    /// 阻止显示器进入空闲睡眠。等价于 `caffeinate -d`，无需特权。
    case preventIdleDisplaySleep
    /// 阻止系统睡眠，**包含合盖场景**。需要 root 权限，必须经助手执行。
    case preventSystemSleep
    /// 阻止已连接磁盘进入低功耗空闲态（外置 USB / Thunderbolt 盘尤其明显）。
    ///
    /// 实测：普通用户进程即可创建，不需要 root（`pmset -g assertions` 里
    /// 可见 `PreventDiskIdle 1`）。所以 `requiresPrivilege` 是 false。
    ///
    /// **边界**：它阻止的是「磁盘进入低功耗态」，不是「系统关机」。
    /// 电池耗尽时系统照样会关。也不等于 `pmset disksleep 0` ——
    /// 那是全局禁用内置盘休眠，语义不同，不要混为一谈。
    case preventDiskIdle

    var id: String { rawValue }

    /// 传给 IOKit 的 assertion 类型字符串。
    var iokitType: String {
        switch self {
        case .preventIdleSystemSleep:  return "PreventUserIdleSystemSleep"
        case .preventIdleDisplaySleep: return "PreventUserIdleDisplaySleep"
        case .preventSystemSleep:      return "PreventSystemSleep"
        case .preventDiskIdle:         return "PreventDiskIdle"
        }
    }

    /// 是否必须由特权助手代为持有。
    var requiresPrivilege: Bool { self == .preventSystemSleep }

    var title: String {
        switch self {
        case .preventIdleSystemSleep:  return "阻止空闲睡眠"
        case .preventIdleDisplaySleep: return "保持屏幕常亮"
        case .preventSystemSleep:      return "阻止系统睡眠"
        case .preventDiskIdle:         return "阻止磁盘空闲休眠"
        }
    }

    var subtitle: String {
        switch self {
        case .preventIdleSystemSleep:
            return "系统不会因为长时间无操作而睡眠，合盖仍会睡眠。"
        case .preventIdleDisplaySleep:
            return "显示器不会因为空闲而关闭，系统仍可能睡眠。"
        case .preventSystemSleep:
            return "连合上盖子也不会睡眠，需要完全控制权限。"
        case .preventDiskIdle:
            return "外置硬盘不会因空闲而转入低功耗态，避免传输中断与唤醒延迟。"
             + "不阻止系统睡眠，也不能阻止电池耗尽时关机。"
        }
    }

    var symbolName: String {
        switch self {
        case .preventIdleSystemSleep:  return "moon.zzz"
        case .preventIdleDisplaySleep: return "sun.max"
        case .preventSystemSleep:      return "lock.shield"
        case .preventDiskIdle:         return "internaldrive"
        }
    }

    /// 命令行接口使用的简短名称，供 `--hold` 等参数使用。
    var cliName: String {
        switch self {
        case .preventIdleSystemSleep:  return "idle-system"
        case .preventIdleDisplaySleep: return "display"
        case .preventSystemSleep:      return "system"
        case .preventDiskIdle:         return "disk-idle"
        }
    }

    /// 写入 IOKit 的 assertion 名称。
    /// 必须是 ASCII：非 ASCII 名称在 `pmset -g assertions` 里会显示为空，
    /// 导致排查时无法辨认是谁在阻止睡眠。
    var assertionName: String {
        switch self {
        case .preventIdleSystemSleep:  return "Deep Sleep - prevent idle system sleep"
        case .preventIdleDisplaySleep: return "Deep Sleep - prevent display sleep"
        case .preventSystemSleep:      return "Deep Sleep - prevent system sleep"
        case .preventDiskIdle:         return "Deep Sleep - prevent disk idle"
        }
    }

    /// 从命令行名称反查类型，同时接受 rawValue 与常见别名。
    static func fromCLIName(_ name: String) -> AssertionKind? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = AssertionKind.allCases.first(where: { $0.cliName == normalized || $0.rawValue.lowercased() == normalized }) {
            return exact
        }
        switch normalized {
        case "idle", "sleep", "idle-sleep":        return .preventIdleSystemSleep
        case "screen", "display-sleep", "awake":   return .preventIdleDisplaySleep
        case "lid", "clamshell", "all":            return .preventSystemSleep
        case "disk", "disksleep", "external-disk": return .preventDiskIdle
        default:                                    return nil
        }
    }
}
