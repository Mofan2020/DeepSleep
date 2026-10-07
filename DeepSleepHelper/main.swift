//
//  main.swift
//  deepsleep-helper
//
//  Deep Sleep 的特权助手守护进程（root / launchd LaunchDaemon）。
//
//  存在的意义：macOS 上有一部分电源控制能力（PreventSystemSleep assertion、
//  pmset disablesleep、计划唤醒等）必须有 root 权限。若每次操作都让用户输入
//  管理员密码，体验很差。因此这里做成一次性安装的常驻守护进程：
//
//    1. 用户在 app 内点一次「启用完全控制」→ 系统授权对话框（可用 Touch ID）→ 安装本助手
//    2. 之后 app 每次需要提权操作，只要求 Touch ID 确认，再经 UNIX socket 发命令过来
//
//  安全设计：
//    - socket 文件 chown 给当前登录用户、chmod 0600
//    - 每个连接都用 getpeereid() 校验对端 uid，非登录用户直接拒绝
//    - 可写入的 pmset 键做白名单，值做数字校验，杜绝参数注入
//    - 只暴露本文件列出的固定命令，不接受任意 shell 字符串
//    - `terminateProcesses`（强制结束进程）不信任调用方给的任何判断：
//      pid 只是「待考察对象」，保护名单与进程树全部用 Shared/ 里的
//      同一份实现重新算一遍。名单在 ProcessGuard.swift，改动前先读那里的注释。
//

import Foundation
import IOKit.pwr_mgt
import SystemConfiguration
import Darwin

// MARK: - 日志

/// 日志写入与轮转。
///
/// 状态都收在这个实例里，且只在它自己的串行队列上访问 ——
/// 助手会并发处理多个连接，日志不能互相踩。
///
/// 轮转同时管两个维度，缺一个都会出事：
///   - **按天**归档：跨天后把当前文件改名成 `xxx.log.YYYY-MM-DD`。
///     只按大小管的话，一个安静的时期会把很久以前的记录一直堆在同一个文件里，
///     根本分不清「什么时候发生的」。
///   - **按大小**截尾：单日文件超过上限时保留末尾内容。
///     原先是超过就直接删掉整个文件 —— 那等于在出问题的时候，
///     把最该看的最近几行一起丢掉。
/// 另外定期清理超过保留天数的归档文件，这才是「不写爆磁盘」的真正保证。
private final class LogWriter {

    static let shared = LogWriter()

    private let queue = DispatchQueue(label: "com.skyc8266.deepsleep.helper.log")
    private let maxBytes = 512 * 1024
    private let retentionDays = 7

    private let archiveFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 上次清理归档的时间，避免每次写日志都扫一遍目录。
    private var lastCleanup = Date.distantPast

    func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("[\(stamp)] [helper] \(message)\n".utf8)
        queue.async { [self] in
            rotateIfNeeded()
            if !append(data) {
                // 写文件失败时才退回 stderr。
                // 正常情况下不写 stderr：LaunchDaemon 的 StandardErrorPath
                // 已经指向同一个日志文件，两边都写会让每一行都重复两次 ——
                // 看起来就像「每个命令都被执行了两次」。
                FileHandle.standardError.write(data)
            }
        }
    }

    // MARK: - 轮转

    private var path: String { HelperConstants.logPath }

    private func rotateIfNeeded() {
        let manager = FileManager.default

        if let attributes = try? manager.attributesOfItem(atPath: path) {
            let size = attributes[.size] as? Int ?? 0
            let modified = attributes[.modificationDate] as? Date ?? Date()

            if !Calendar.current.isDateInToday(modified) {
                let archived = "\(path).\(archiveFormatter.string(from: modified))"
                try? manager.removeItem(atPath: archived)
                try? manager.moveItem(atPath: path, toPath: archived)
            } else if size > maxBytes {
                trimTail(keeping: maxBytes / 2)
            }
        }

        cleanUpArchives(manager)
    }

    /// 保留文件尾部若干字节，并在换行处切割，免得留下半行乱码。
    private func trimTail(keeping bytes: Int) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count > bytes else { return }
        let tail = data.suffix(bytes)
        let cleaned = tail.firstIndex(of: 0x0A).map { tail[tail.index(after: $0)...] } ?? tail
        try? Data(cleaned).write(to: URL(fileURLWithPath: path))
    }

    private func cleanUpArchives(_ manager: FileManager) {
        guard Date().timeIntervalSince(lastCleanup) > 3600 else { return }
        lastCleanup = Date()

        let directory = (path as NSString).deletingLastPathComponent
        let prefix = (path as NSString).lastPathComponent + "."
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()),
              let entries = try? manager.contentsOfDirectory(atPath: directory) else { return }

        for entry in entries where entry.hasPrefix(prefix) {
            let stamp = String(entry.dropFirst(prefix.count))
            guard let date = archiveFormatter.date(from: stamp), date < cutoff else { continue }
            try? manager.removeItem(atPath: (directory as NSString).appendingPathComponent(entry))
        }
    }

    /// 追加到日志文件，返回是否成功。
    private func append(_ data: Data) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                do {
                    try handle.write(contentsOf: data)
                    return true
                } catch {
                    return false
                }
            }
            return false
        } else {
            return manager.createFile(atPath: path, contents: data)
        }
    }
}

private func logLine(_ message: String) {
    LogWriter.shared.write(message)
}

// MARK: - 进程执行

@discardableResult
private func runProcess(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "启动 \(launchPath) 失败：\(error.localizedDescription)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - 控制台用户

private func consoleUser() -> (name: String, uid: uid_t)? {
    guard let store = SCDynamicStoreCreate(nil, "com.skyc8266.deepsleep.helper" as CFString, nil, nil),
          let user = SCDynamicStoreCopyConsoleUser(store, nil, nil) as String?,
          !user.isEmpty, user != "loginwindow",
          let pw = getpwnam(user) else {
        return nil
    }
    return (user, pw.pointee.pw_uid)
}

// MARK: - 内部错误类型

/// 助手内部操作的失败原因。用结构体包一层，方便直接塞进 `Result`。
private struct OperationFailure: Error {
    let message: String
}

/// 简化失败分支的书写。
private func failure<T>(_ message: String) -> Result<T, OperationFailure> {
    .failure(OperationFailure(message: message))
}

// MARK: - assertion 管理

private final class AssertionStore {
    private var identifiers: [String: IOPMAssertionID] = [:]
    private let lock = NSLock()

    /// 创建（或复用）一个 assertion。
    func acquire(kind: PrivilegedAssertionKind, name: String) -> Result<IOPMAssertionID, OperationFailure> {
        lock.lock()
        defer { lock.unlock() }

        if let existing = identifiers[kind.rawValue] {
            return .success(existing)
        }

        var identifier = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kind.iokitType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &identifier
        )

        guard result == kIOReturnSuccess else {
            return failure("IOPMAssertionCreateWithName 返回 0x\(String(result, radix: 16))")
        }

        identifiers[kind.rawValue] = identifier
        return .success(identifier)
    }

    func release(kind: PrivilegedAssertionKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let identifier = identifiers.removeValue(forKey: kind.rawValue) else { return false }
        IOPMAssertionRelease(identifier)
        return true
    }

    func releaseAll() {
        lock.lock()
        defer { lock.unlock() }
        for (_, identifier) in identifiers {
            IOPMAssertionRelease(identifier)
        }
        identifiers.removeAll()
    }

    func heldKinds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return identifiers.keys.sorted()
    }
}

// MARK: - pmset 支持

private enum PMSet {
    /// 允许通过助手写入的键白名单，防止任意键被改写。
    static let writableKeys: Set<String> = [
        "sleep", "displaysleep", "disksleep", "hibernatemode",
        "powernap", "womp", "ttyskeepawake", "lowpowermode",
        "standby", "standbydelaylow", "standbydelayhigh", "networkoversleep",
        "autorestart", "lidwake", "gpuswitch", "halfdim", "disablesleep"
    ]

    /// 读取系统级电源设置（全部走 `pmset -g`，只读不需要 root）。
    /// 解析交给 Shared/PMSetOutput.swift 的共享实现 —— 这里原本有一份
    /// 只按空格切分的副本，读不到 TAB 分隔的 `SleepDisabled`。
    static func readSettings() -> [String: String] {
        PMSetOutput.readCurrent()
    }

    static func writeSetting(key: String, value: String) -> Result<Void, OperationFailure> {
        guard writableKeys.contains(key) else {
            return failure("键 \(key) 不在允许写入的白名单内")
        }
        // 值必须是非负整数，杜绝 `1; rm -rf /` 之类的参数注入。
        guard !value.isEmpty, value.allSatisfy({ $0.isNumber }) else {
            return failure("值 \(value) 必须是非负整数")
        }
        let result = runProcess("/usr/bin/pmset", ["-a", key, value])
        guard result.status == 0 else {
            return failure("pmset -a \(key) \(value) 失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return .success(())
    }

    static func setSleepDisabled(_ disabled: Bool) -> Result<Void, OperationFailure> {
        let result = runProcess("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"])
        guard result.status == 0 else {
            return failure("pmset disablesleep 失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return .success(())
    }

    static func isSleepDisabled() -> Bool {
        readSettings()["SleepDisabled"] == "1"
    }
}

// MARK: - 命令分发

private final class CommandHandler {
    let assertions = AssertionStore()

    func handle(_ request: HelperRequest) -> HelperResponse {
        switch request.command {
        case .ping:
            // 回报自身二进制的摘要：应用据此判断装着的助手是不是它内置的那一份。
            return .ok("pong", payload: [
                "version": "\(HelperConstants.protocolVersion)",
                "digest": HelperSelfUpdate.selfDigest()
            ])

        case .status:
            let settings = PMSet.readSettings()
            return .ok("status", payload: [
                "version": "\(HelperConstants.protocolVersion)",
                "digest": HelperSelfUpdate.selfDigest(),
                "assertions": assertions.heldKinds().joined(separator: ","),
                "sleepDisabled": settings["SleepDisabled"] ?? "0",
                "pid": "\(getpid())"
            ])

        case .acquireAssertion:
            guard let raw = request.arguments["kind"],
                  let kind = PrivilegedAssertionKind(rawValue: raw) else {
                return .failure("缺少或非法的 kind 参数")
            }
            let name = request.arguments["name"] ?? "Deep Sleep"
            switch assertions.acquire(kind: kind, name: name) {
            case .success(let identifier):
                logLine("acquired assertion \(kind.rawValue) id=\(identifier)")
                return .ok("已获取 \(kind.displayName)", payload: ["id": "\(identifier)"])
            case .failure(let error):
                logLine("acquire failed: \(error.message)")
                return .failure(error.message)
            }

        case .releaseAssertion:
            guard let raw = request.arguments["kind"],
                  let kind = PrivilegedAssertionKind(rawValue: raw) else {
                return .failure("缺少或非法的 kind 参数")
            }
            let released = assertions.release(kind: kind)
            logLine("released assertion \(kind.rawValue) → \(released)")
            return released ? .ok("已释放 \(kind.displayName)") : .failure("该 assertion 未被持有")

        case .setSleepDisabled:
            let enabled = ["1", "true", "yes"].contains((request.arguments["enabled"] ?? "0").lowercased())
            switch PMSet.setSleepDisabled(enabled) {
            case .success:
                logLine("disablesleep → \(enabled ? 1 : 0)")
                return .ok(enabled ? "已禁用系统睡眠（合盖也不休眠）" : "已恢复系统正常睡眠")
            case .failure(let error):
                logLine("setSleepDisabled failed: \(error.message)")
                return .failure(error.message)
            }

        case .readPowerSettings:
            return .ok("settings", payload: PMSet.readSettings())

        case .writePowerSetting:
            guard let key = request.arguments["key"], let value = request.arguments["value"] else {
                return .failure("缺少 key 或 value")
            }
            switch PMSet.writeSetting(key: key, value: value) {
            case .success:
                logLine("pmset -a \(key) \(value)")
                return .ok("已设置 \(key) = \(value)")
            case .failure(let error):
                logLine("writePowerSetting failed: \(error.message)")
                return .failure(error.message)
            }

        case .scheduleWake:
            guard let date = request.arguments["date"], !date.isEmpty else {
                return .failure("缺少 date 参数")
            }
            let result = runProcess("/usr/bin/pmset", ["schedule", "wake", date])
            return result.status == 0
                ? .ok("已排定唤醒：\(date)")
                : .failure("排定唤醒失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")

        case .cancelScheduledWake:
            let result = runProcess("/usr/bin/pmset", ["schedule", "cancelall"])
            return result.status == 0
                ? .ok("已取消所有排定的唤醒")
                : .failure("取消失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")

        case .sleepNow:
            assertions.releaseAll()
            // 后台异步执行：立刻睡眠会让本进程来不及回包。
            let script = "sleep 0.4; /usr/bin/pmset sleepnow"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            try? process.run()
            logLine("sleepnow scheduled")
            return .ok("即将进入睡眠")

        case .updateSelf:
            switch HelperSelfUpdate.perform(arguments: request.arguments) {
            case .success:
                logLine("self-update scheduled")
                // 先回包再退出：立刻退出来不及把响应写回 socket，
                // 应用会误判成「助手没响应」。
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { exit(0) }
                return .ok("助手更新已安排，即将重启")
            case .failure(let error):
                logLine("self-update rejected: \(error.message)")
                return .failure(error.message)
            }

        case .terminateProcesses:
            return terminateProcesses(request)

        case .getProcessStats:
            return getProcessStats()

        case .suspendProcesses:
            return suspendProcesses(request)

        case .killProcesses:
            return killProcesses(request)

        case .uninstall:
            logLine("uninstall requested")
            uninstallSelf()
            return .ok("助手已开始卸载")
        }
    }

    // MARK: - 强制结束进程

    /// 强制结束一批进程及其全部子进程。
    ///
    /// 这是助手暴露的行为最重的命令，所以校验全部发生在助手这一侧：
    /// 应用传来的只有一个 pid 列表，其余判断（谁是受保护进程、哪些子进程
    /// 要一起处理）全部用共享实现重新算一遍。调用方就算被替换成一个
    /// 乱发 pid 的程序，能造成的结果也只限于这份名单允许的范围。
    private func terminateProcesses(_ request: HelperRequest) -> HelperResponse {
        guard let raw = request.arguments["pids"] else {
            return .failure("缺少 pids 参数")
        }
        let roots = raw
            .split(separator: ",")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }

        guard !roots.isEmpty else {
            return .failure("pids 为空或无法解析")
        }
        guard roots.count <= ProcessGuard.maximumRootCount else {
            return .failure("一次最多接受 \(ProcessGuard.maximumRootCount) 个目标进程，收到 \(roots.count) 个")
        }

        let snapshot = ProcessInventory.snapshot()
        let plan = ProcessGuard.plan(roots: roots, in: snapshot)

        guard plan.targets.count <= ProcessGuard.maximumTargetCount else {
            // 整体拒绝而不是「杀一部分」：半个进程树比一棵完整的树更难收拾。
            logLine("terminate 拒绝：目标数 \(plan.targets.count) 超过上限")
            return .failure("待结束的进程数 \(plan.targets.count) 超过上限 \(ProcessGuard.maximumTargetCount)，已整体取消")
        }

        let outcome = ProcessTerminator.terminate(plan.targets, in: snapshot)

        var report = TerminationReport()
        report.killed = outcome.killed.map { .init(pid: $0.pid, name: $0.name) }
        report.failed = outcome.failed.map { .init(pid: $0.pid, name: $0.name, reason: $0.reason) }
        report.refused = plan.refusals.map { .init(pid: $0.pid, name: $0.name, reason: $0.reason) }
        report.skippedDescendants = plan.skippedDescendantCount

        logLine("terminate 根进程=\(roots.count) 目标=\(plan.targets.count) "
                + "已退出=\(report.killed.count) 受保护=\(report.refused.count) 失败=\(report.failed.count)")
        for refusal in report.refused {
            logLine("  refused pid=\(refusal.pid) \(refusal.name)：\(refusal.reason)")
        }

        guard !plan.targets.isEmpty || !report.refused.isEmpty else {
            return .failure("没有可结束的进程（目标可能已经退出）")
        }
        return .ok(report.summary, payload: report.encode())
    }

    // MARK: - 进程监控相关（v2 协议）

    /// 返回一份进程快照。CPU% 基于 ProcessSnapshotCache 内部的差值缓存。
    /// 第一次调用所有 cpuPercent=0（这是显式约定，不是计算失败）。
    private func getProcessStats() -> HelperResponse {
        let snapshot = self.collectSnapshotSync()
        let payload = ProcessStats(records: snapshot).encode()
        return .ok("已抓取 \(snapshot.count) 个进程", payload: payload)
    }

    /// 抓快照。`ProcessSnapshotCache` 是 actor，这里同步取结果再立刻返回；
    /// actor 内部把状态锁在自己身上，没有共享问题。
    private func collectSnapshotSync() -> [ProcessStats.Record] {
        // snapshot() 是 async，这里用 semaphore 把 actor 拉同步。
        let sem = DispatchSemaphore(value: 0)
        var result: [ProcessStats.Record] = []
        Task.detached {
            let records = await ProcessSnapshotCache.shared.snapshot()
            result = records
            sem.signal()
        }
        sem.wait()
        return result
    }

    /// 挂起一组进程。SIGSTOP。
    /// 监控场景调用方已是叶子节点，不连带子树，但**仍然走保护名单**：
    /// 命中白名单的 pid 记到 refused，不挂起。
    private func suspendProcesses(_ request: HelperRequest) -> HelperResponse {
        guard let raw = request.arguments["pids"] else {
            return .failure("缺少 pids 参数")
        }
        let targets = parsePids(raw)
        guard !targets.isEmpty else { return .failure("pids 为空或无法解析") }
        guard targets.count <= ProcessGuard.maximumRootCount else {
            return .failure("一次最多接受 \(ProcessGuard.maximumRootCount) 个目标")
        }

        let snapshot = ProcessInventory.snapshot()
        let byPid = Dictionary(snapshot.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        var report = TerminationReport()
        for pid in targets {
            guard let process = byPid[pid] else {
                // 进程在快照期间已经退出 —— 当作「不在」，不是失败
                report.killed.append(.init(pid: pid, name: "pid \(pid)"))
                continue
            }
            if let reason = ProcessGuard.refusalReason(for: process) {
                report.refused.append(.init(pid: pid, name: process.name, reason: reason))
                continue
            }
            if Darwin.kill(pid, SIGSTOP) == 0 {
                report.killed.append(.init(pid: pid, name: process.name))
            } else {
                let err = errno
                report.failed.append(.init(
                    pid: pid, name: process.name,
                    reason: String(cString: strerror(err))))
            }
        }

        logLine("suspend 请求=\\(targets.count) 已挂起=\(report.killed.count) 拒绝=\(report.refused.count) 失败=\(report.failed.count)")
        return .ok(report.summary, payload: report.encode())
    }

    /// 杀掉一组进程。SIGKILL。同 suspend 一样不连带子树但走保护名单。
    /// 注意：监控场景是叶子节点；快速退出场景用 `terminateProcesses`
    /// （那条路径带子树计算）。
    private func killProcesses(_ request: HelperRequest) -> HelperResponse {
        guard let raw = request.arguments["pids"] else {
            return .failure("缺少 pids 参数")
        }
        let targets = parsePids(raw)
        guard !targets.isEmpty else { return .failure("pids 为空或无法解析") }
        guard targets.count <= ProcessGuard.maximumRootCount else {
            return .failure("一次最多接受 \(ProcessGuard.maximumRootCount) 个目标")
        }

        let snapshot = ProcessInventory.snapshot()
        let byPid = Dictionary(snapshot.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        var report = TerminationReport()
        for pid in targets {
            guard let process = byPid[pid] else {
                report.killed.append(.init(pid: pid, name: "pid \(pid)"))
                continue
            }
            if let reason = ProcessGuard.refusalReason(for: process) {
                report.refused.append(.init(pid: pid, name: process.name, reason: reason))
                continue
            }
            if Darwin.kill(pid, SIGKILL) == 0 {
                report.killed.append(.init(pid: pid, name: process.name))
            } else {
                let err = errno
                report.failed.append(.init(
                    pid: pid, name: process.name,
                    reason: String(cString: strerror(err))))
            }
        }

        logLine("kill 请求=\(targets.count) 已杀=\(report.killed.count) 拒绝=\(report.refused.count) 失败=\(report.failed.count)")
        return .ok(report.summary, payload: report.encode())
    }

    private func parsePids(_ raw: String) -> [pid_t] {
        raw.split(separator: ",")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 卸载：写入一个延迟脚本，让本进程退出后再删除文件与 launchd 任务。
    private func uninstallSelf() {
        let script = """
        #!/bin/sh
        sleep 1
        /bin/launchctl bootout system/\(HelperConstants.label) 2>/dev/null || true
        /bin/rm -f '\(HelperConstants.socketPath)'
        /bin/rm -f '\(HelperConstants.installedHelperPath)'
        /bin/rm -f '\(HelperConstants.launchDaemonPath)'
        /bin/rm -f '\(HelperConstants.logPath)'
        /bin/rm -f /tmp/com.skyc8266.deepsleep.uninstall.sh
        """
        let path = "/tmp/com.skyc8266.deepsleep.uninstall.sh"
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [path]
        try? process.run()

        assertions.releaseAll()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            exit(0)
        }
    }
}

// MARK: - 服务器

private final class HelperServer {
    private let handler = CommandHandler()
    private let queue = DispatchQueue(label: "com.skyc8266.deepsleep.helper.server", attributes: .concurrent)
    private var listener: Int32 = -1
    private var allowedUID: uid_t?
    private var running = true

    func start() {
        if let console = consoleUser() {
            allowedUID = console.uid
            logLine("console user: \(console.name) (uid \(console.uid))")
        } else {
            logLine("warning: 未能确定控制台用户，将只接受 root 连接")
        }

        do {
            listener = try UnixSocket.makeListener(at: HelperConstants.socketPath)
        } catch {
            logLine("fatal: 无法创建 socket：\(error.localizedDescription)")
            exit(1)
        }

        // 让当前登录用户可以连接，其他用户无权访问。
        if let uid = allowedUID {
            if chown(HelperConstants.socketPath, uid, 0) != 0 {
                logLine("warning: chown socket 失败：\(String(cString: strerror(errno)))")
            }
        }
        if chmod(HelperConstants.socketPath, 0o600) != 0 {
            logLine("warning: chmod socket 失败：\(String(cString: strerror(errno)))")
        }

        logLine("listening on \(HelperConstants.socketPath) (pid \(getpid()))")

        installSignalHandlers()
        acceptLoop()
    }

    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { [weak self] in
            logLine("received SIGTERM, shutting down")
            self?.shutdown()
        }
        termSource.resume()

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler { [weak self] in
            logLine("received SIGINT, shutting down")
            self?.shutdown()
        }
        intSource.resume()
    }

    private func shutdown() {
        running = false
        handler.assertions.releaseAll()
        if listener >= 0 {
            close(listener)
            listener = -1
        }
        unlink(HelperConstants.socketPath)
        exit(0)
    }

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listener, sa, &length)
                }
            }

            if client < 0 {
                if errno == EINTR { continue }
                logLine("accept 失败：\(String(cString: strerror(errno)))")
                usleep(100_000)
                continue
            }

            queue.async { [weak self] in
                self?.serve(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        UnixSocket.setTimeout(client, seconds: 15)

        // 关键安全检查：只服务当前登录用户与 root。
        guard let credentials = UnixSocket.peerCredentials(client) else {
            logLine("拒绝连接：无法获取对端凭据")
            return
        }
        if credentials.uid != 0 {
            if let allowed = allowedUID {
                guard credentials.uid == allowed else {
                    logLine("拒绝连接：uid \(credentials.uid) 非控制台用户 \(allowed)")
                    _ = try? UnixSocket.sendFrame(client, HelperResponse.failure("权限不足"))
                    return
                }
            } else {
                logLine("拒绝连接：uid \(credentials.uid) 不在允许列表")
                _ = try? UnixSocket.sendFrame(client, HelperResponse.failure("权限不足"))
                return
            }
        }

        do {
            let request = try UnixSocket.readFrame(client, as: HelperRequest.self)
            logLine("← \(request.command.rawValue) \(request.arguments.isEmpty ? "" : "\(request.arguments)")")
            let response = handler.handle(request)
            try UnixSocket.sendFrame(client, response)
        } catch {
            logLine("处理连接出错：\(error.localizedDescription)")
            _ = try? UnixSocket.sendFrame(client, HelperResponse.failure(error.localizedDescription))
        }
    }
}

// MARK: - 入口

// 只允许 root 运行：非 root 时功能不完整且可能误报成功。
guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("deepsleep-helper 必须以 root 身份运行\n".utf8))
    exit(1)
}

logLine("=== deepsleep-helper 启动 (protocol v\(HelperConstants.protocolVersion)) ===")
HelperServer().start()
