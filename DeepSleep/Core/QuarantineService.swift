//
//  QuarantineService.swift
//  Deep Sleep
//
//  Apple Quarantine 属性管理。
//
//  什么是 Quarantine：macOS 给从浏览器 / 解压工具下载下来的文件打的一个扩展属性
//  `com.apple.quarantine`，双击时 Gatekeeper 看到它会弹「是否打开未知开发者」的提示。
//  对下载下来的工具 / 脚本 / 镜像来说，**第一次**看到这个提示是合理的；但有时候：
//    - 已经知道来源（自己写的、自己包的、签名过的），不想每次都点确认；
//    - 想给一批文件批量去掉（下载目录清完所有 .dmg 之后再分发）；
//    - 调试时想看某个文件是不是被隔离。
//
//  本工具做的事：
//    1. 列出指定目录（含子目录 / 不含子目录）下所有带 quarantine 属性的文件；
//    2. 批量清除（按目录或按勾选）；
//    3. 一切操作走本进程（xattr 不需要 root）。
//
//  不做的事（避免越权）：
//    - 不绕过 Gatekeeper 提示 —— 我们只是去掉 quarantine，让系统走
//      「没有隔离标记」分支；spctl 评估、签名校验由系统决定；
//    - 不绕过公证 —— Apple 的 notarization 是另一回事，quarantine 与之独立。
//
//  实现注意：
//    - 用 `listxattr` + `getxattr` 列属性；不直接 `xattr -lr` 子进程，
//      因为后者走 path 拼接 shell，参数里有空格就炸。
//    - 删除用 `removexattr` —— 单个属性级原子操作，不需要递归遍历。
//    - 软链 / 硬链都不动：link 上 `removexattr` 会作用到 link 本身（macOS 行为），
//      我们跳过 symlink，避免误删源文件的隔离标记。
//

import Foundation

/// `QuarantineService` 是纯计算（xattr 读写 + 文件遍历），不持有任何 UI 状态，
/// 所以不是 actor：调用方在哪个线程都可以直接调。这避免了「MainActor 隔离 →
/// 在 `Task.detached` 里要 await」的繁琐。
final class QuarantineService {

    static let shared = QuarantineService()

    private init() {}

    /// quarantine 属性名。这是 Apple 公开约定的固定字符串。
    static let attributeName = "com.apple.quarantine"

    enum QuarantineError: Error, CustomStringConvertible {
        case io(String)
        case notDirectory(String)

        var description: String {
            switch self {
            case .io(let m):            return "IO 失败：\(m)"
            case .notDirectory(let p):  return "不是目录：\(p)"
            }
        }
    }

    /// 一条记录：哪个文件有 quarantine 属性。
    ///
    /// v1.7.2 起 `.app` 文件折叠显示：本条只代表 `.app` 包本身，
    /// `appContentsQuarantined` 统计包内（不含 symlink）带 quarantine 的文件数。
    /// 清除时如果 `isAppBundle` 为 true，会递归清包内所有 quarantine。
    struct Entry: Identifiable, Equatable {
        /// 完整路径。
        let path: String
        /// 文件大小（字节）。`-1` 表示读不到（不阻塞列目录）。
        let size: Int64
        /// 修改时间（mtime）。为 nil 表示读不到。
        let modifiedAt: Date?
        /// quarantine 属性的值。保留下来给 UI 显示 / 给调试看：
        /// 形如 `0083;61ab35f5;Chrome;…` —— 4 段：`flag;timestamp;agent;UUID`。
        let value: String
        /// 该路径是否是 `.app` 包。
        let isAppBundle: Bool
        /// 该 `.app` 包内（不含 symlink）带 quarantine 的文件数；非 .app 时为 0。
        /// UI 上用「包内另有 N 个文件被隔离」提示用户清除时一并处理。
        let appContentsQuarantined: Int
        /// 解析后的 4 段：flag / timestamp / agent / UUID。
        /// 解析失败时为空数组（value 整体保留在 `value`）。
        let valueSegments: [String]
        var id: String { path }

        /// 「完整隔离状态」单行描述，给 UI「详情」展开用。
        var detailDescription: String {
            if valueSegments.count >= 4 {
                return [
                    "flag=\(valueSegments[0])",
                    "time=\(valueSegments[1])",
                    "agent=\(valueSegments[2])",
                    "uuid=\(valueSegments[3])"
                ].joined(separator: " · ")
            }
            return value.isEmpty ? "(空)" : value
        }
    }

    /// 一次扫描结果。
    struct Report {
        let root: String
        let entries: [Entry]
        let totalScanned: Int
        let totalCleared: Int

        var clearedAll: Bool { totalScanned == totalCleared && totalScanned > 0 }
    }

    /// 列出 `root` 下（含子目录）所有带 quarantine 属性的文件。
    /// - Parameters:
    ///   - root: 扫描根路径。必须是目录；不存在则报错。
    ///   - recursive: 是否递归子目录。
    ///   - includeHidden: 是否包含以 `.` 开头的隐藏文件 / 子目录。
    func scan(root: String, recursive: Bool, includeHidden: Bool) throws -> [Entry] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            throw QuarantineError.notDirectory(root)
        }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        var entries: [Entry] = []
        try walk(rootURL, recursive: recursive, includeHidden: includeHidden, into: &entries)
        return entries.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    /// 批量清除指定文件列表的 quarantine 属性。
    /// - Returns: 实际被清掉的文件数（已无属性的视为跳过，不算失败）。
    func clear(paths: [String]) -> (cleared: Int, failed: [(String, String)]) {
        var cleared = 0
        var failed: [(String, String)] = []
        for path in paths {
            do {
                let removed = try removeQuarantine(at: path)
                if removed { cleared += 1 }
            } catch {
                failed.append((path, error.localizedDescription))
            }
        }
        return (cleared, failed)
    }

    /// 清除一个 `.app` 包及其**内部所有文件**的 quarantine 属性。
    ///
    /// 只清 `com.apple.quarantine`，不动其他 xattr；不动 symlink。
    /// 返回 (app 本体是否被清, 包内清掉的内部文件数, 失败列表)。
    @discardableResult
    func clearAppBundle(at path: String) -> (clearedApp: Bool, clearedInside: Int, failed: [(String, String)]) {
        var clearedApp = false
        do {
            clearedApp = try removeQuarantine(at: path)
        } catch {
            return (false, 0, [(path, error.localizedDescription)])
        }
        var inner: [Entry] = []
        let url = URL(fileURLWithPath: path)
        // 仅扫描包内（递归、非 .app 折叠 —— 这里要拿到全部内部文件条目）
        try? walk(url, recursive: true, includeHidden: false, into: &inner)
        let innerPaths = inner.map(\.path).filter { $0 != path }
        let result = clear(paths: innerPaths)
        return (clearedApp, result.cleared, result.failed)
    }

    /// 批量清除指定目录下所有 quarantine 文件（递归选项同 `scan`）。
    @discardableResult
    func clearAll(root: String, recursive: Bool, includeHidden: Bool) throws -> Report {
        let entries = try scan(root: root, recursive: recursive, includeHidden: includeHidden)
        let paths = entries.map(\.path)
        let result = clear(paths: paths)
        return Report(
            root: root,
            entries: entries,
            totalScanned: entries.count,
            totalCleared: result.cleared
        )
    }

    // MARK: - 快速修复（损坏 .app 的多方案）

    /// 一条修复方案的结果。
    struct RepairOutcome: Equatable {
        let step: String         // 方案名
        let success: Bool
        let detail: String       // 给 UI 看的一句话结果
    }

    /// 对「.app 损坏」的多方案修复，按可靠性递增。
    ///
    /// 用户原话：「对于部分提示已损坏的.app文件，也应当提供快捷解决方案（多方案，保证成功）」。
    /// macOS 的「损坏」提示通常由 quarantine 引起（最常见），其次是签名失效，
    /// 最后是用户对系统 Gatekeeper 的信任设置。**任何方案前都自动先 1)**。
    ///
    /// 顺序：
    ///   1. 清除 quarantine（这一步几乎 90% 的「损坏」提示能消掉）
    ///   2. ad-hoc 重签（`codesign --force --deep --sign -`）—— 处理签名缺失/失效
    ///   3. 全清 xattr（`xattr -cr`）—— 兜底任何 xattr 异常
    ///   4. 引导用户到「系统设置 → 隐私与安全」手动「仍要打开」（最差兜底）
    @discardableResult
    func repairDamagedApp(at path: String) -> [RepairOutcome] {
        var outcomes: [RepairOutcome] = []

        // 1) 清除 quarantine（包本身 + 包内）
        let appClear = clearAppBundle(at: path)
        let appCleared = appClear.clearedApp || appClear.clearedInside > 0
        outcomes.append(RepairOutcome(
            step: "1. 清除 quarantine",
            success: appCleared,
            detail: appCleared
                ? "包\(appClear.clearedApp ? "" : "本体未带") 已清；包内另有 \(appClear.clearedInside) 个文件被清"
                : "未发现 quarantine 属性"
        ))
        if appClear.failed.isEmpty && appCleared {
            // 90% 的场景到此为止
            return outcomes
        }

        // 2) ad-hoc 重签
        let signResult = runAndCapture("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", path])
        outcomes.append(RepairOutcome(
            step: "2. 自签名（ad-hoc）",
            success: signResult.status == 0,
            detail: signResult.status == 0
                ? "已用临时签名重新签名"
                : "失败：\(signResult.output.isEmpty ? "退出码 \(signResult.status)" : signResult.output)"
        ))

        // 3) 全清 xattr
        let xattrResult = runAndCapture("/usr/bin/xattr", ["-cr", path])
        outcomes.append(RepairOutcome(
            step: "3. 清除所有 xattr",
            success: xattrResult.status == 0,
            detail: xattrResult.status == 0
                ? "已清空全部扩展属性"
                : "失败：\(xattrResult.output.isEmpty ? "退出码 \(xattrResult.status)" : xattrResult.output)"
        ))

        // 4) 系统设置指引（不真正执行，UI 上展示文字）
        outcomes.append(RepairOutcome(
            step: "4. 手动从「系统设置」打开",
            success: false,
            detail: "打开后按提示在「仍要打开」按钮上点确认。这是 Gatekeeper 拒绝任何修复方案时的最后兜底。"
        ))

        return outcomes
    }

    private func runAndCapture(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "\(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }

    // MARK: - 私有

    /// 递归扫描实现。
    ///
    /// v1.7.2 起：`.app` 文件**折叠**显示 —— 不递归遍历 .app 内部所有被隔离文件，
    /// 只产生 1 条 `.app` 记录，`appContentsQuarantined` 统计包内文件数。
    /// 清除时按这条记录处理（单独走 `clearAppBundle`）。
    private func walk(_ url: URL,
                      recursive: Bool,
                      includeHidden: Bool,
                      into entries: inout [Entry]) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey,
                                      .fileSizeKey, .contentModificationDateKey]
        let contents = try fm.contentsOfDirectory(at: url,
                                                  includingPropertiesForKeys: keys,
                                                  options: includeHidden ? [] : [.skipsHiddenFiles])
        for child in contents {
            let path = child.path
            let name = (path as NSString).lastPathComponent
            if !includeHidden, name.hasPrefix(".") { continue }

            let resourceValues = try? child.resourceValues(forKeys: Set(keys))
            let isSymlink = resourceValues?.isSymbolicLink ?? false
            let isDirectory = resourceValues?.isDirectory ?? false

            // 不动 symlink：macOS 上 removexattr 会作用到 link 本身，
            // 但解析后的源文件 quarantine 是否该删取决于它的真实来源，
            // 不是当前扫描目录的判定范围。
            if isSymlink { continue }

            // .app 文件：折叠成一条记录 + 统计包内被隔离文件数（不再递归深入子目录）。
            if isDirectory && name.hasSuffix(".app") {
                if let entry = readQuarantine(at: path, resourceValues: resourceValues) {
                    let inner = try? countQuarantined(in: child)
                    entries.append(Entry(
                        path: entry.path,
                        size: entry.size,
                        modifiedAt: entry.modifiedAt,
                        value: entry.value,
                        isAppBundle: true,
                        appContentsQuarantined: inner ?? 0,
                        valueSegments: entry.valueSegments
                    ))
                }
                // 不递归 .app 内部（折叠语义）
                continue
            }

            if let entry = readQuarantine(at: path, resourceValues: resourceValues) {
                entries.append(entry)
            }

            if isDirectory && recursive {
                try walk(child, recursive: recursive, includeHidden: includeHidden, into: &entries)
            }
        }
    }

    /// 递归统计一个目录（含子目录、不含 symlink）下带 quarantine 的文件数。
    /// 仅用于 `.app` 包内统计；非 .app 目录不调它。
    private func countQuarantined(in url: URL) throws -> Int {
        var count = 0
        var inner: [Entry] = []
        try walk(url, recursive: true, includeHidden: false, into: &inner)
        count = inner.count
        return count
    }

    /// 读一个文件的 quarantine 属性；无则返回 nil。
    private func readQuarantine(at path: String,
                                resourceValues: URLResourceValues?) -> Entry? {
        let value = (try? getQuarantineValue(at: path)) ?? ""
        guard !value.isEmpty else { return nil }

        let size: Int64
        let modified: Date?
        if let r = resourceValues {
            size = Int64(r.fileSize ?? 0)
            modified = r.contentModificationDate
        } else {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            modified = attrs?[.modificationDate] as? Date
        }
        let segments = Self.parseQuarantineValue(value)
        return Entry(
            path: path,
            size: size,
            modifiedAt: modified,
            value: value,
            isAppBundle: false,           // walk() 在 .app 分支里覆盖
            appContentsQuarantined: 0,
            valueSegments: segments
        )
    }

    /// 把 `"0083;61ab35f5;Chrome;xxxx-xxxx"` 拆成 4 段。
    /// 段数不匹配时返回空数组（保留原始 value 让 UI 兜底显示）。
    private static func parseQuarantineValue(_ raw: String) -> [String] {
        let segments = raw
            .split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)
        guard segments.count >= 4 else { return [] }
        return Array(segments.prefix(4))
    }

    /// 调 libc 读 quarantine 属性。返回空字符串 = 无此属性。
    private func getQuarantineValue(at path: String) throws -> String {
        // 先 list 看看属性是否存在 —— 直接 getxattr 不存在会回 -1 + errno=ENOATTR，
        // 那是「没找到」而非「真出错」，统一空串返回。
        let listResult = listxattr(path, nil, 0, 0)
        if listResult < 0 {
            throw errnoToError(errno, "listxattr \(path)")
        }
        let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(listResult) + 1)
        defer { nameBuffer.deallocate() }
        let read = listxattr(path, nameBuffer, listResult, 0)
        guard read > 0 else {
            throw errnoToError(errno, "listxattr \(path)")
        }
        let rawNames = String(cString: nameBuffer)
        let names = rawNames.split(separator: "\0").map(String.init)
        guard names.contains(Self.attributeName) else { return "" }

        // 拿属性值。quarantine value 形如 ASCII "0083;61ab35f5;Chrome;…"
        let capacity = 4096
        let valueBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { valueBuffer.deallocate() }
        let length = getxattr(path,
                              Self.attributeName,
                              valueBuffer,
                              capacity,
                              0,
                              0)
        if length < 0 {
            let code = errno
            if code == ENOATTR { return "" }
            throw errnoToError(code, "getxattr \(path)")
        }
        let data = Data(bytes: valueBuffer, count: Int(length))
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 删除 quarantine 属性。返回「是否实际删了一个属性」。
    @discardableResult
    private func removeQuarantine(at path: String) throws -> Bool {
        let result = removexattr(path, Self.attributeName, 0)
        if result == 0 { return true }
        let code = errno
        // 文件在我们读和写之间被删了 —— 不算失败，跳过即可。
        if code == ENOATTR { return false }
        if code == ENOENT { return false }
        throw errnoToError(code, "removexattr \(path)")
    }

    private func errnoToError(_ code: Int32, _ op: String) -> QuarantineError {
        let message = String(cString: strerror(code))
        return .io("\(op) 失败（errno \(code)：\(message)）")
    }
}