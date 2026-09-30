//
//  ProcessGuard.swift
//  Deep Sleep
//
//  强杀保护名单与「该杀谁」的裁决。**应用与特权助手编译同一份。**
//
//  这是全项目第二危险的代码（仅次于助手的自我更新）：它决定「哪些进程
//  绝对不能被本应用杀掉」。因此：
//
//    1. 名单是硬编码的，不接受应用传来的任何参数覆盖；
//    2. 应用侧与助手侧各自独立调用同一份实现 —— 助手**不信任**应用传过来的
//       裁决结果，只把应用给的 pid 当作「待考察对象」，全部规则自己再算一遍；
//    3. 被保护的进程连同它的**整棵子树**一起跳过。理由：保护名单里的
//       进程都是会话/系统关键进程，它们的子进程同样是系统结构的一部分，
//       「杀掉系统关键进程的子进程」不是任何人想要的语义。
//

import Foundation
import Darwin

public enum ProcessGuard {

    // MARK: - 硬名单：进程短名（小写，取自 p_comm）

    /// 绝对不允许杀死的进程名。
    ///
    /// 分组的依据是「杀掉之后会失去什么」：
    ///   - 会话关键：直接掉登录会话、界面失去响应
    ///   - 系统关键：内核/启动/电源/安全的基础设施
    ///   - 数据与偏好：偏好丢失或写坏、Spotlight 索引重建
    /// 名单按名字匹配，命中即拒绝，不允许任何开关绕过。
    public static let protectedNames: Set<String> = [
        // —— 内核与启动 ——
        "launchd",              // pid 1，杀掉等于立刻崩溃重启
        "kernel_task",          // 内核任务
        "watchdogd",
        // —— 会话与界面 ——
        "windowserver",         // 杀掉 = 立刻注销当前用户
        "loginwindow",          // 登录会话管理
        "dock",
        "finder",
        "systemuiserver",       // 菜单栏本体
        "controlcenter",        // 控制中心（声音/网络/Wi-Fi 菜单）
        "notificationcenter",   // 通知中心
        "notificationcenterui",
        "spotlight",            // 聚焦
        "universalcontrol",     // 通用控制
        // —— 电源与散热 ——
        "powerd",               // 本应用的对账机制正是围绕它建立的
        "thermald",
        "thermalmonitord",
        // —— 安全与权限 ——
        "securityd",
        "tccd",                 // 权限数据库，杀掉会让所有权限提示紊乱
        "authd",
        "syspolicyd",
        "amfid",
        // —— 注册、通知与偏好 ——
        "launchservicesd",
        "runningboardd",
        "distnoted",            // 跨进程通知总线
        "coreservicesd",
        "sharedfilelistd",
        "cfprefsd",             // 偏好写入代理，杀掉会让设置丢失
        "usernoted",
        "notifyd",
        "pboard",               // 剪贴板
        // —— 目录服务与配置 ——
        "opendirectoryd",
        "configd",
        // —— 磁盘与元数据 ——
        "diskarbitrationd",
        "fseventsd",
        "mds",
        "mds_stores",
        "mdworker",
        "mdworker_shared",
        // —— 网络 ——
        "mdnsresponder",
        "nehelper",
        "nesessionmanager",
        // —— 音频与蓝牙 ——
        "coreaudiod",
        "bluetoothd",
        // —— 日志与诊断 ——
        "logd",
        "syslogd",
        // —— 本应用自己 ——
        "deep sleep",
        "deepsleep-helper",
    ]

    // MARK: - 硬名单：bundle id

    /// 绝对不允许杀死的 bundle id。
    /// 与名单里的进程名互补：有些系统进程改过名，靠 bundle id 更稳。
    public static let protectedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.WindowServer",
        "com.apple.loginwindow",
        "com.apple.SystemUIServer",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.systempreferences",
        "com.apple.SecurityAgent",
        "com.apple.CoreServicesUIAgent",
        "com.skyc8266.deepsleep",           // 本应用
        "com.skyc8266.deepsleep.helper",    // 特权助手
    ]

    // MARK: - 裁决

    /// 拒绝一个进程的理由。`nil` 表示可以杀。
    public struct Refusal: Sendable, Equatable {
        public let pid: pid_t
        public let name: String
        public let reason: String
    }

    /// 一次强杀的完整计划。
    public struct Plan: Sendable {
        /// 实际要杀掉的进程，**子进程在前**。
        public let targets: [pid_t]
        /// 被保护而跳过的进程（连同其子树）。
        public let refusals: [Refusal]
        /// 因为落在被保护进程的子树里而一并跳过的进程总数。
        public let skippedDescendantCount: Int

        public var isNoop: Bool { targets.isEmpty }
    }

    /// 判定单个进程是否受保护。
    ///
    /// 返回值是「拒绝理由」，而不是 Bool —— 调用方需要把理由讲给用户听，
    /// 而「被保护」本身不足以解释为什么 Finder 杀不得。
    public static func refusalReason(for process: RunningProcess) -> String? {
        // 内核与 pid 1 无条件拒绝。名单里也有它们，但这一条不依赖名单正确。
        if process.pid <= 1 {
            return "内核或 launchd（pid \(process.pid)）"
        }
        if process.pid == getpid() {
            return "发起请求的进程自己"
        }

        let name = process.name.lowercased()
        if protectedNames.contains(name) {
            return "受保护的系统进程「\(process.name)」"
        }
        if let bundleID = process.bundleIdentifier, protectedBundleIDs.contains(bundleID) {
            return "受保护的系统应用「\(process.name)」（\(bundleID)）"
        }
        return nil
    }

    /// 一个 app 束是否受保护。界面用它把系统应用挡在可选列表之外 ——
    /// 让人先选进去、按键时再被拒绝是更差的体验。
    public static func isProtected(bundleIdentifier: String, name: String) -> Bool {
        protectedBundleIDs.contains(bundleIdentifier)
            || protectedNames.contains(name.lowercased())
    }

    /// 算出「从这些根进程出发，到底该杀谁」。
    ///
    /// 逐层遍历：任何一层命中保护名单，就把该进程**连同子树**整段跳过，
    /// 并留下拒绝记录。这样「杀掉某个进程会不会误伤系统」这个问题，
    /// 答案永远只取决于名单，不取决于树形。
    ///
    /// 读不到的根进程会被记成拒绝项而不是被忽略：应用侧（普通权限）读不到
    /// 其他用户拥有的进程，若静默跳过，用户按下快捷键后会看到「什么都没发生、
    /// 也没有原因」—— 这不是诚实的行为。
    public static func plan(roots: [pid_t],
                            in snapshot: [RunningProcess]) -> Plan {
        let byPid = Dictionary(snapshot.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        var children: [pid_t: [pid_t]] = [:]
        for process in snapshot {
            children[process.parentPID, default: []].append(process.pid)
        }

        var kept = Set<pid_t>()
        var refusals: [Refusal] = []
        var skipped = 0
        var visited = Set<pid_t>()

        /// 子树大小（含自己）。用于统计「因为落在受保护进程之下而一并跳过」的数量。
        func subtreeSize(_ pid: pid_t) -> Int {
            var count = 1
            for child in children[pid] ?? [] {
                count += subtreeSize(child)
            }
            return count
        }

        /// 把整棵子树记为跳过 —— 只标记，不加入 kept。
        func blockSubtree(_ pid: pid_t) {
            guard !visited.contains(pid) else { return }
            visited.insert(pid)
            for child in children[pid] ?? [] {
                blockSubtree(child)
            }
        }

        func walk(_ pid: pid_t) {
            guard !visited.contains(pid) else { return }
            visited.insert(pid)

            guard let process = byPid[pid] else {
                refusals.append(Refusal(
                    pid: pid,
                    name: "pid \(pid)",
                    reason: "无法读取该进程（可能刚刚退出，或由其他用户运行而需要完全控制）"
                ))
                return
            }

            if let reason = refusalReason(for: process) {
                refusals.append(Refusal(pid: pid, name: process.name, reason: reason))
                skipped += subtreeSize(pid) - 1
                for child in children[pid] ?? [] {
                    blockSubtree(child)
                }
                return
            }

            for child in children[pid] ?? [] {
                walk(child)
            }
            kept.insert(pid)
        }

        for root in Set(roots).sorted() {
            walk(root)
        }

        // 顺序：子进程在前。用同一份快照重排，避免再抓一次而拿到不一致的树。
        let ordered = ProcessInventory.orderedForTermination(
            roots: Array(kept), in: snapshot
        ).filter { kept.contains($0) }

        return Plan(targets: ordered, refusals: refusals, skippedDescendantCount: skipped)
    }

    // MARK: - 上限

    /// 单次请求允许的根进程数上限。
    /// 设定这个上限是为了让「一次请求能杀掉的东西」有明确上界 ——
    /// 即使调用方被替换成一个乱发 pid 的程序，影响也是可估的。
    public static let maximumRootCount = 64

    /// 一次动作的进程数上限（含子进程）。超过就整体拒绝，不做部分执行：
    /// 「杀了一半」比「一个没杀」更难收拾。
    public static let maximumTargetCount = 512
}

// MARK: - 执行

/// 真正把进程杀掉。
///
/// 与 `ProcessGuard` 分开：裁决可以单测，执行不能。分开之后
/// 「名单写错了」与「kill 调用写错了」是两个可分别验证的问题。
public enum ProcessTerminator {

    public struct Outcome: Sendable {
        public struct Record: Sendable {
            public let pid: pid_t
            public let name: String
        }
        public struct Failure: Sendable {
            public let pid: pid_t
            public let name: String
            public let reason: String
        }

        public let killed: [Record]
        public let failed: [Failure]
    }

    /// 逐个 SIGKILL，然后等它们真的消失。
    ///
    /// 为什么直接 SIGKILL：macOS 上的 Cocoa 应用不处理 SIGTERM，
    /// 收到它同样是立刻终止、不走保存流程，「优雅一点」是错觉；
    /// 而真正优雅的做法（发 AppleEvent 请求退出）需要给每个目标 app
    /// 单独授予「自动化」权限，与「一键 panic」的目的直接冲突。
    ///
    /// - Parameter waitSeconds: 等进程消失的最长时间。SIGKILL 之下正常
    ///   应立即消失，等一等只是为了把「真的死了」写进结果而不是猜。
    public static func terminate(_ pids: [pid_t],
                                 in snapshot: [RunningProcess],
                                 waitSeconds: Double = 1.5) -> Outcome {
        let byPid = Dictionary(snapshot.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var killed: [Outcome.Record] = []
        var failed: [Outcome.Failure] = []

        func name(of pid: pid_t) -> String {
            byPid[pid]?.name ?? "pid \(pid)"
        }

        for pid in pids {
            // 权限不足（目标是别人的进程、或目标是 root 而自己不是）
            // 时这里会拿到 EPERM，如实记下来，交给调用方讲清楚。
            let result = Darwin.kill(pid, SIGKILL)
            if result == 0 {
                killed.append(.init(pid: pid, name: name(of: pid)))
            } else if errno == ESRCH {
                // 快照之后自己退出了：结果是「已经不在」，不是失败。
                killed.append(.init(pid: pid, name: name(of: pid)))
            } else {
                failed.append(.init(pid: pid, name: name(of: pid),
                                    reason: String(cString: strerror(errno))))
            }
        }

        guard waitSeconds > 0 else { return Outcome(killed: killed, failed: failed) }

        let deadline = Date().addingTimeInterval(waitSeconds)
        var survivors = killed.map(\.pid)
        while !survivors.isEmpty, Date() < deadline {
            survivors = survivors.filter { Darwin.kill($0, 0) == 0 }
            if survivors.isEmpty { break }
            usleep(50_000)
        }
        // 等了之后仍然活着 —— 这种情况极少（不可中断的 D 状态），
        // 但它确实存在，所以照实报告，不假装成功。
        for pid in survivors {
            killed.removeAll { $0.pid == pid }
            failed.append(.init(pid: pid, name: name(of: pid),
                                reason: "已发送 SIGKILL 但进程仍未退出"))
        }

        return Outcome(killed: killed, failed: failed)
    }
}
