//
//  HelperProtocol.swift
//  Deep Sleep
//
//  特权助手进程与主应用之间共享的通信协议定义。
//  此文件同时被 DeepSleep.app 与 deepsleep-helper 编译。
//

import Foundation

// MARK: - 命令

/// 特权助手支持的命令集合。
public enum HelperCommand: String, Codable, CaseIterable, Sendable {
    /// 存活探测，用于判断助手是否已就绪。
    case ping
    /// 读取助手侧状态（持有的 assertion、disablesleep 状态、版本）。
    case status
    /// 获取一个需要 root 权限的电源 assertion。
    case acquireAssertion
    /// 释放一个由本助手持有的 assertion。
    case releaseAssertion
    /// 设置 `pmset disablesleep`（合盖不睡眠 / 完全禁用睡眠）。
    case setSleepDisabled
    /// 读取 `pmset` 电量管理设置。
    case readPowerSettings
    /// 写入 `pmset` 电量管理设置。
    case writePowerSetting
    /// 计划一个定时唤醒。
    case scheduleWake
    /// 取消已排定的唤醒。
    case cancelScheduledWake
    /// 立即进入睡眠。
    case sleepNow
    /// 卸载助手（停止并删除文件）。
    case uninstall
    /// 用应用内置的新二进制替换助手自身并重启（助手的自我更新）。
    /// 只接受构建序号严格递增、且来源为 Deep Sleep.app 内部的二进制。
    case updateSelf
}

// MARK: - 请求

public struct HelperRequest: Codable, Sendable {
    public var command: HelperCommand
    public var arguments: [String: String]

    public init(command: HelperCommand, arguments: [String: String] = [:]) {
        self.command = command
        self.arguments = arguments
    }
}

// MARK: - 响应

public struct HelperResponse: Codable, Sendable {
    public var success: Bool
    public var message: String
    public var payload: [String: String]

    public init(success: Bool, message: String = "", payload: [String: String] = [:]) {
        self.success = success
        self.message = message
        self.payload = payload
    }

    public static func ok(_ message: String = "ok", payload: [String: String] = [:]) -> HelperResponse {
        HelperResponse(success: true, message: message, payload: payload)
    }

    public static func failure(_ message: String) -> HelperResponse {
        HelperResponse(success: false, message: message)
    }
}

// MARK: - 常量

public enum HelperConstants {
    /// launchd 标签，同时也是 LaunchDaemon plist 的文件名主体。
    public static let label = "com.skyc8266.deepsleep.helper"
    /// 助手监听的 UNIX domain socket 路径。
    public static let socketPath = "/var/run/com.skyc8266.deepsleep.sock"
    /// 助手二进制在系统内的安装路径。
    public static let installedHelperPath = "/Library/PrivilegedHelperTools/com.skyc8266.deepsleep.helper"
    /// LaunchDaemon 描述文件路径。
    public static let launchDaemonPath = "/Library/LaunchDaemons/com.skyc8266.deepsleep.helper.plist"
    /// 助手日志路径。
    public static let logPath = "/var/log/com.skyc8266.deepsleep.helper.log"
    /// 协议版本，双方不一致时拒绝通信，避免升级后行为错乱。
    public static let protocolVersion = 1

    /// 助手二进制的构建序号。
    ///
    /// **每次改动 DeepSleepHelper/ 下的代码都要把它 +1。** 这是「已安装的助手
    /// 是否需要更新」的唯一判据，约定如下：
    ///
    ///   - 只增不减、不要跳号、不要复用它表示别的含义；
    ///   - 判据是 `已安装 build < 本常量`，而不是「两者不相等」——
    ///     用「不相等」的话，一旦应用比已安装的助手旧，就会反复把助手降级再
    ///     升级，永远停不下来；
    ///   - 应用侧读不到这个值（旧版助手不回报 build）时视为需要更新，
    ///     但每次运行只尝试一次，避免更新失败时陷入循环。
    public static let helperBuild = 1
}

// MARK: - 助手进程侧需 root 的断言类型

/// 助手可以代为持有的 assertion 类型（这些类型需要 root 权限）。
public enum PrivilegedAssertionKind: String, Codable, CaseIterable, Sendable {
    /// 阻止系统睡眠，包含合盖场景。需要 root。
    case preventSystemSleep
    /// 阻止空闲系统睡眠。普通进程亦可创建，助手侧提供作为兜底与统一管理。
    case preventIdleSystemSleep
    /// 阻止空闲显示器睡眠。
    case preventIdleDisplaySleep

    /// 对应的 IOKit assertion 类型字符串。
    public var iokitType: String {
        switch self {
        case .preventSystemSleep:     return "PreventSystemSleep"
        case .preventIdleSystemSleep: return "PreventUserIdleSystemSleep"
        case .preventIdleDisplaySleep: return "PreventUserIdleDisplaySleep"
        }
    }

    public var displayName: String {
        switch self {
        case .preventSystemSleep:     return "阻止系统睡眠（含合盖）"
        case .preventIdleSystemSleep: return "阻止空闲系统睡眠"
        case .preventIdleDisplaySleep: return "阻止显示器睡眠"
        }
    }
}
