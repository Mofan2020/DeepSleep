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
    /// 只接受来源为 Deep Sleep.app 内部、且内容摘要与调用方给出一致的二进制。
    case updateSelf
    /// 强制结束一批进程及其全部子进程（快速退出功能）。
    ///
    /// 参数只有 `pids`（逗号分隔的根进程）。助手**不信任**调用方给出的
    /// 任何判断，会自己重新抓进程快照、重新套用 `ProcessGuard` 保护名单 ——
    /// 调用方给的 pid 只是「待考察对象」，不是「要杀的东西」。
    case terminateProcesses
    /// 返回当前所有进程的 RSS / CPU% / 启动时间快照（系统过载监控 + 内存泄漏检测）。
    /// v2 协议才支持；旧版助手会回 `unknown command` 失败。
    case getProcessStats
    /// 用 SIGSTOP 挂起（冻结）一组进程。用于「过载时冻结前三大占用者」。
    /// 参数 `pids` 为逗号分隔的 pid 列表。
    /// 助手仍然走 `ProcessGuard.plan`，命中白名单或子树返回 `refused`。
    /// 同样不连带子树 —— 监控场景下调用方已明确是叶子节点。
    case suspendProcesses
    /// 用 SIGKILL 杀掉一组进程。用于「通知/对话框点了处理（建议）」路径。
    /// 不连带子树、不走保护名单豁免 —— 必须经过 `ProcessGuard.plan` 全套裁决。
    case killProcesses
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
    ///
    /// 版本历史：
    ///   - v1：所有现有命令（assertion、pmset、计划唤醒、终止）
    ///   - v2：新增 `getProcessStats` / `suspendProcesses` / `killProcesses`，
    ///         用于系统过载监控与内存泄漏检测
    ///
    /// 升级路径：用户启动新版 app 后，app 探测到旧助手（v=1），
    /// 主动触发 `updateSelf` —— docs/release.md 已说明助手能自我更新。
    /// 旧助手对 v2 命令会回 `unknown command`；应用侧必须探测协议版本并提示。
    public static let protocolVersion = 2
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
