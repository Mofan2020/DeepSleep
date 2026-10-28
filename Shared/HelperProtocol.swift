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
    /// 读 CPU 温度（Apple SMC）。仅在特权助手侧能直接连 SMC，普通进程不行。
    /// 返回 `CPUTemperatureSample`(max/average/aggregate °C,字段缺失 = 该值读不到)。
    /// v3 协议才支持；旧版助手（v<=2）会回 `unknown command` 失败。
    case getCPUTemperature

    // MARK: - 风扇控制（v1.9 起）

    /// 读风扇实时状态：数量、每个风扇的当前转速 / 最低 / 最高 / 是否手动模式。
    /// 返回 payload 见 `Shared/FanModels.swift` 的 `FanState.encode()`。
    /// 无参数。
    case getFanState

    /// 写风扇目标转速 + 模式。
    ///
    /// 参数：
    ///   `fan`   = 风扇序号（0 起）
    ///   `rpm`   = 目标转速（整数；0 表示交回系统自动控制）
    ///   `lease` = 租约秒数。助手在此秒数内没收到同风扇的新指令，
    ///             自动把该风扇交回系统自动模式。传 0 = 不设租约
    ///             （危险，应用侧禁止使用，只给诊断用）。
    ///   `reason`= 可选，写入日志。
    ///
    /// 写入顺序必须是「先写模式键，后写目标键」（见 docs/SMC.md §2.6.1）。
    case setFanSpeed

    /// 读全部温度传感器（IOHID 私有事件通道，PrimaryUsagePage 0xFF00 / PrimaryUsage 5）。
    /// 返回 payload 见 `Shared/FanModels.swift` 的 `TemperatureSnapshot.encode()`。
    /// 无参数。
    case getTemperatureSnapshot

    /// 强制把所有风扇交回系统自动控制。
    ///
    /// 安全兜底：应用退出 / 崩溃 / 租约到期时都要调用。
    /// 手动模式下风扇转速不再由 SMC 决定，不收回控制权就等于让一个
    /// 可能已经不存在的进程决定散热。
    /// 无参数。
    case releaseFanControl

    /// 同步「用户已同意风扇免责声明」的状态给助手。
    ///
    /// 参数 `accepted` = "true" / "false"。
    ///
    /// 为什么应用同意还不够、助手要自己存一份：应用层的同意状态拦不住
    /// 「绕过 UI 直接构造协议包打助手」。助手侧独立持久化一份，
    /// 未同意时直接拒绝一切写 SMC 的命令 —— 门禁必须在执行点，
    /// 不能只在调用点。
    case setFanDisclaimerAccepted

    // MARK: - 排定唤醒增强（v1.9 起）

    /// 读系统当前所有排定项。返回 payload：
    ///   `entries` = 记录串 `kind|when|owner`，记录间 `,`
    ///   `count`   = 条数
    /// 无参数。
    case listScheduledEvents

    /// 排定一次唤醒，带 owner 标记（便于按条取消）。
    /// 参数 `date`（MM/dd/yy HH:mm:ss）、`owner`（可选，默认 "Deep Sleep"）。
    case scheduleWakeWithOwner

    /// 按条取消排定。参数 `date`（MM/dd/yy HH:mm:ss）+ `kind`（默认 wake）。
    /// 刻意不做 cancelall —— 那会连别的程序排的唤醒一起取消。
    case cancelScheduledEvent

    /// 循环排定唤醒。参数 `weekdays`（MTWRFSU 的子集）、`time`（HH:mm:ss）。
    case scheduleRepeatWake

    /// 取消全部循环排定。
    case cancelRepeatWake

    // MARK: - 服务器模式（v1.6 起）

    /// 立刻关显示器（等价于 `pmset displaysleepnow`）。
    /// 服务模式需要「系统不睡 + 显示器关」，普通应用可以走 `pmset`，
    /// 但这里仍走助手路径是为了和锁屏共用一套提权审计/日志。
    /// 参数：无。
    case sleepDisplay

    /// 立刻锁屏。
    /// 走「关屏 + 让系统已有的"立即要求密码"接管」。不写 `com.apple.screensaver`
    /// 偏好，调用方必须先确认系统设置已开启「立即」。
    /// 参数：无。
    case lockScreen

    // MARK: - 进程优先级（v1.6 起）

    /// 读一组进程的 nice 值。参数 `pids` 为逗号分隔 pid 列表。
    /// 返回 payload 里 `nice:<pid>=<value>` 一行一项；读不到的进程记成 `missing`。
    case getProcessNice

    /// 改一个进程的 nice 值。参数 `pid` 单进程 + `value` ∈ [-20, 19]。
    /// 助手会先复用 `ProcessGuard.niceRefusalReason` 判定「能否改」，
    /// 不允许系统进程、bundle id 在保护名单里的应用。
    case setProcessNice

    // MARK: - Hosts 文件（v1.7 起）

    /// 读取 `/etc/hosts` 的当前内容。返回 payload `content=<原文>`。
    /// 无参数。
    case readHosts

    /// 写入 `/etc/hosts`。
    ///
    /// 写入前会做三件事：
    ///   1. 校验调用方 uid 在 hosts 编辑白名单内（白名单为空时放行任何 uid）；
    ///   2. 调用方给的内容是**完整文件原文**（不是 diff/patch），先备份再写；
    ///   3. 写完后把 owner 设回 `root:wheel`、mode `0644`，
    ///      防止任何调用方让 hosts 变成可执行。
    ///
    /// 参数 `content=<新内容>`。`content` 必须 UTF-8 合法、且非空。
    case writeHosts

    /// 读取当前的「谁能改 hosts」白名单。
    /// payload `uids=<逗号分隔>`、`usernames=<逗号分隔>`。
    /// 无参数。
    case listHostsEditors

    /// 替换「谁能改 hosts」白名单。
    ///
    /// 白名单本身是宿主 hosts 的钥匙：调用方必须在 hosts 编辑白名单内
    /// 才能修改白名单（防止普通 uid 加自己）。
    /// 参数 `uids=<逗号分隔>` 与 `usernames=<逗号分隔>`。两者皆可空表示
    /// 「清空白名单 = 任何人都能改」（恢复默认）。
    case setHostsEditors

    // MARK: - 周重启（v1.7.2 起）

    /// 写一个 launchd plist 到 `~/Library/LaunchAgents/com.skyc8266.deepsleep.weeklyrestart.plist`，
    /// 同时配套写入 `/etc/sudoers.d/deepsleep-weeklyrestart` 给用户 NOPASSWD 权限跑
    /// `shutdown -r now`。下次到点时系统会按用户身份跑这条命令，触发重启。
    ///
    /// 参数 `weekday=<0–6, 0=周日>`、`hour=<0–23>`、`minute=<0–59>`。
    case installWeeklyRestart

    /// 删除上述 plist + sudoers 配置。
    case uninstallWeeklyRestart
}

// MARK: - 请求

public struct HelperRequest: Codable, Sendable {
    public var command: HelperCommand
    public var arguments: [String: String]

    public init(command: HelperCommand, arguments: [String: String] = [:]) {
        self.command = command
        self.arguments = arguments
    }

    /// 调用方 uid。仅 helper 进程在收到 socket 请求后填上，序列化时**忽略**。
    /// 这是「不能信任调用方」原则下的本地记账 —— 协议 JSON 里没有这个字段，
    /// 但 handler 在调度时已经能看见它，所以 hosts 白名单、niceRefusal
    /// 这类「按调用方身份决定」的命令能直接拿到。
    public var callerUID: uid_t?

    private enum CodingKeys: String, CodingKey {
        case command, arguments
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
    ///   - v3：**未发**。原计划跟随 `getCPUTemperature`（Apple SMC）一起升，
    ///         但 maintenance 3.2 节明确写「新增命令不需要升级 protocolVersion」，
    ///         旧助手遇新命令会回解码错误而非崩溃（已实测），保持兼容更好。
    ///         所以 `getCPUTemperature` 仍跑在 v2 协议上：旧助手直接拒绝
    ///         （应用侧用 ProtocolVersion=2 仍能跑现有功能），新助手支持；
    ///         `ProcessStatsProvider.fetchCPUTemperature()` 会用协议版本门禁
    ///         探测能力。
    ///   - v1.7 起追加 `readHosts` / `writeHosts` / `listHostsEditors` /
    ///     `setHostsEditors`，仍跑在 v2 协议上 —— 旧助手遇这些命令会回
    ///     `unknown command`，新应用会探测能力并提示。
    ///
    /// 升级路径：用户启动新版 app 后，app 探测到旧助手（v=2 不含 CPU 温度），
    /// 主动触发 `updateSelf` —— docs/release.md 已说明助手能自我更新。
    /// 旧助手对 `getCPUTemperature` 会回 `unknown command`；应用侧必须探测协议版本
    /// 并提示「助手需要更新才能支持 CPU 温度」。
    public static let protocolVersion = 2

    /// hosts 编辑白名单文件路径。
    /// 由助手以 root 写入；应用只能读。
    /// 放在 `/Library/Application Support` 而不是 `/etc`，是因为
    /// `/etc/hosts` 受 SIP 保护但 `/Library/Application Support/com.skyc8266.deepsleep/`
    /// 不受 —— 我们要写的是「白名单文件」，而不是 hosts 本体。
    public static let hostsEditorsPath = "/Library/Application Support/com.skyc8266.deepsleep/hosts-editors.plist"
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