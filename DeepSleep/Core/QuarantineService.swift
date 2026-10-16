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
        var id: String { path }
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

    // MARK: - 私有

    /// 递归扫描实现。
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

            if let entry = readQuarantine(at: path, resourceValues: resourceValues) {
                entries.append(entry)
            }

            if isDirectory && recursive {
                try walk(child, recursive: recursive, includeHidden: includeHidden, into: &entries)
            }
        }
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
        return Entry(path: path, size: size, modifiedAt: modified, value: value)
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