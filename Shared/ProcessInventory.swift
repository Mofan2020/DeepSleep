//
//  ProcessInventory.swift
//  Deep Sleep
//
//  进程枚举与进程树计算。**应用与特权助手编译同一份。**
//
//  为什么必须共用：应用侧要「把选定的 app 解析成一棵进程树」，助手侧要
//  「独立地再算一遍、再校验一遍」。如果两边各写一份，规则迟早会漂移 ——
//  而这类漂移的后果是「应用以为杀的是这棵树，助手杀的是另一棵」，
//  属于不能靠肉眼发现的那类 bug。这与 `Shared/PMSetOutput.swift` 的
//  共用理由完全相同（那里曾经真的踩过一次）。
//

import Foundation
import Darwin

/// 某一时刻的一个进程。
///
/// 字段刻意收窄到「判断需不需要保护」以及「怎么把它杀掉」所必需的部分：
/// 不做通用进程查看器，免得为了展示无关信息引入不必要的权限要求。
public struct RunningProcess: Sendable, Equatable {
    public let pid: pid_t
    public let parentPID: pid_t
    public let uid: uid_t
    /// 进程短名（`p_comm`，最多 16 字节）。保护名单就是按它匹配的。
    public let name: String
    /// 可执行文件绝对路径。读不到时为空串。
    public let executablePath: String
    /// 可执行文件所属的 `.app` 束路径；可执行文件不在任何 app 束内时为 nil。
    public let bundlePath: String?
    /// app 束的 `CFBundleIdentifier`；取不到时为 nil。
    public let bundleIdentifier: String?

    public init(pid: pid_t,
                parentPID: pid_t,
                uid: uid_t,
                name: String,
                executablePath: String,
                bundlePath: String?,
                bundleIdentifier: String?) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.name = name
        self.executablePath = executablePath
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum ProcessInventory {

    // MARK: - 枚举

    /// 抓一份当前进程的快照。
    ///
    /// 用 `proc_listpids` + `proc_pidinfo` 而不是 `sysctl(KERN_PROC_ALL)`：
    /// 前者能直接拿到父进程、uid 与短名，且不需要再解析一遍 kinfo_proc 的
    /// 可变长度布局（那部分在不同系统版本上并不可靠）。
    public static func snapshot(limit: Int = 8192) -> [RunningProcess] {
        var pids = [pid_t](repeating: 0, count: max(1, limit))
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }

        let count = Int(bytes) / MemoryLayout<pid_t>.size
        guard count > 0 else { return [] }

        var result: [RunningProcess] = []
        result.reserveCapacity(count)

        for index in 0..<min(count, pids.count) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            if let process = describe(pid: pid) {
                result.append(process)
            }
        }
        return result
    }

    /// 读单个进程的详情。进程在两次系统调用之间退出时返回 nil。
    public static func describe(pid: pid_t) -> RunningProcess? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard written == size else { return nil }

        let name = withUnsafeBytes(of: info.pbi_comm) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : ""

        let bundle = bundlePath(forExecutablePath: path)
        return RunningProcess(
            pid: pid,
            parentPID: pid_t(bitPattern: info.pbi_ppid),
            uid: info.pbi_uid,
            name: name,
            executablePath: path,
            bundlePath: bundle,
            bundleIdentifier: bundle.flatMap(bundleIdentifier(forBundlePath:))
        )
    }

    // MARK: - app 束识别

    /// 从可执行文件路径里找出所属的 `.app` 束。
    /// 形如 `/Applications/Foo.app/Contents/MacOS/Foo` → `/Applications/Foo.app`。
    ///
    /// 取**最内层**的 `.app`：游戏与部分 app 会把子 app 套在框架里
    /// （`X.app/Contents/Frameworks/Y.app`），此时 Y 才是真正要杀的那个。
    public static func bundlePath(forExecutablePath path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.lastIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + parts[0...index].joined(separator: "/")
    }

    /// 读 app 束的 bundle id。读不到（无 Info.plist、损坏、权限不足）返回 nil。
    /// 读不到也记进缓存（存空串作哨兵）—— 一次动作里会反复问同一个束。
    public static func bundleIdentifier(forBundlePath bundlePath: String) -> String? {
        identifierCache.lock.lock()
        if let cached = identifierCache.values[bundlePath] {
            identifierCache.lock.unlock()
            return cached.isEmpty ? nil : cached
        }
        identifierCache.lock.unlock()

        let plistPath = bundlePath + "/Contents/Info.plist"
        var identifier = ""
        if let data = FileManager.default.contents(atPath: plistPath),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dictionary = plist as? [String: Any] {
            identifier = dictionary["CFBundleIdentifier"] as? String ?? ""
        }

        identifierCache.lock.lock()
        identifierCache.values[bundlePath] = identifier
        identifierCache.lock.unlock()
        return identifier.isEmpty ? nil : identifier
    }

    /// 进程「当前正跑着的那份 app」的 bundle id。命令行工具与守护进程为 nil。
    public static func bundleIdentifier(forExecutablePath path: String) -> String? {
        bundlePath(forExecutablePath: path).flatMap(bundleIdentifier(forBundlePath:))
    }

    // MARK: - 进程树

    /// 指定进程的全部后代（不含自己）。
    public static func descendants(of roots: [pid_t], in snapshot: [RunningProcess]) -> [pid_t] {
        let children = childrenMap(snapshot)
        var seen = Set<pid_t>(roots)
        var queue = roots
        var result: [pid_t] = []

        while let current = queue.popLast() {
            for child in children[current] ?? [] where !seen.contains(child) {
                seen.insert(child)
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    /// 传给 `kill` 的顺序：**子进程在前、根进程在后**。
    ///
    /// 反过来（先杀父）会让父进程来不及被观察就消失，而且某些应用
    /// （Electron、部分游戏启动器）会在父进程退出时触发子进程清理逻辑，
    /// 先把子进程杀干净更干净利落。
    public static func orderedForTermination(roots: [pid_t],
                                             in snapshot: [RunningProcess]) -> [pid_t] {
        let children = childrenMap(snapshot)
        var emitted = Set<pid_t>()
        var order: [pid_t] = []

        func visit(_ pid: pid_t) {
            guard !emitted.contains(pid) else { return }
            emitted.insert(pid)
            for child in children[pid] ?? [] {
                visit(child)
            }
            order.append(pid)
        }

        for root in roots {
            visit(root)
        }
        return order
    }

    private static func childrenMap(_ snapshot: [RunningProcess]) -> [pid_t: [pid_t]] {
        var map: [pid_t: [pid_t]] = [:]
        for process in snapshot {
            map[process.parentPID, default: []].append(process.pid)
        }
        return map
    }

    // MARK: - 缓存

    /// 引用类型 + 锁：`static let` 结构体无法在 Swift 里原地修改成员。
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: String] = [:]
    }

    /// bundle id 的读盘缓存。一次动作里同一棵树的多个进程会指向同一个束，
    /// 不缓存就会重复读同一个 Info.plist。
    private static let identifierCache = Cache()
}
