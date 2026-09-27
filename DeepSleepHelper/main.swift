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
//

import Foundation
import IOKit.pwr_mgt
import SystemConfiguration
import Darwin

// MARK: - 日志

private let logQueue = DispatchQueue(label: "com.skyc8266.deepsleep.helper.log")
private let maxLogBytes = 1 * 1024 * 1024

private func logLine(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] [helper] \(message)\n"
    logQueue.async {
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)
        let path = HelperConstants.logPath
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attributes[.size] as? Int, size > maxLogBytes {
            try? FileManager.default.removeItem(atPath: path)
        }
        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
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

    /// 读取系统级电源设置，解析成键值对（全部走 `pmset -g`，只读不需要 root）。
    static func readSettings() -> [String: String] {
        let result = runProcess("/usr/bin/pmset", ["-g"])
        var settings: [String: String] = [:]
        for rawLine in result.output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasSuffix(":") else { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            // `sleep 1 (sleep prevented by ...)` → 只保留数值部分
            if let paren = value.firstIndex(of: "(") {
                value = String(value[value.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
            }
            settings[key] = value
        }
        return settings
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
            return .ok("pong", payload: ["version": "\(HelperConstants.protocolVersion)"])

        case .status:
            let settings = PMSet.readSettings()
            return .ok("status", payload: [
                "version": "\(HelperConstants.protocolVersion)",
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

        case .uninstall:
            logLine("uninstall requested")
            uninstallSelf()
            return .ok("助手已开始卸载")
        }
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
