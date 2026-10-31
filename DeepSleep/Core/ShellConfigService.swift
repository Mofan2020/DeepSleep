//
//  ShellConfigService.swift
//  Deep Sleep
//
//  Shell 启动文件（.zshrc / .zprofile / .bash_profile …）的读写。
//
//  这个文件**不 import SwiftUI** —— 纯 Foundation + POSIX。
//  这么做是为了让 scripts/test-shell-config.swift 能直接编译**真实源码**来测，
//  而不是抄一份副本（副本会漂移）。测试时把 home 换成临时目录，
//  绝不碰用户真实的 ~/.zshrc。
//
//  关键决策：
//    - 直接读写家目录，不需要助手授权：这些文件本来就在用户自己名下，
//      走 root 反而会留下 root 拥有的文件让用户下次改不动。
//    - 写入用「同目录临时文件 + rename」原子替换：rename 在同一卷内是原子的，
//      写到一半断电也只会留下旧文件，不会留下半截的 .zshrc。
//    - 不用 `Data.write(to:options:.atomic)`：它建临时文件时用 0600，
//      替换后原文件的 0644 就丢了 —— 而 .zshrc 被别的工具读是常态。
//    - 每次保存前把旧内容备份到 <路径>.deepsleep.bak，可一键回滚。
//      与 /etc/hosts.deepsleep.bak 同一路子。
//    - 语法检查用系统自带的 `zsh -n` / `bash -n`：只解析不执行，
//      安全，且错误信息是用户熟悉的原文。
//

import Foundation
import Darwin

// MARK: - 模型

/// shell 家族：决定用哪个解释器做语法检查。
enum ShellConfigShell: String {
    case zsh
    case bash

    /// 解释器路径。用系统自带的，不依赖用户 PATH 里装了什么。
    var executablePath: String {
        switch self {
        case .zsh:  return "/bin/zsh"
        case .bash: return "/bin/bash"
        }
    }

    var displayName: String {
        switch self {
        case .zsh:  return "zsh"
        case .bash: return "bash"
        }
    }
}

/// 一个可编辑的 shell 配置文件。
struct ShellConfigFile: Identifiable, Equatable {
    let url: URL
    let exists: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    /// 属于哪个 shell（决定语法检查用哪个解释器）。
    var shell: ShellConfigShell { ShellConfigService.shellKind(for: url.lastPathComponent) }

    /// 文件大小（字节）。文件不存在时为 nil。
    ///
    /// 刻意做成计算属性而不是存字段：`exists` 是候选清单生成时的快照，
    /// 存进去的大小 / 时间也会一起过期。现场 stat 一次更诚实。
    var byteCount: Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.size] as? NSNumber else { return nil }
        return number.intValue
    }

    /// 最后修改时间。文件不存在时为 nil。
    var modifiedAt: Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }
}

// MARK: - 服务

enum ShellConfigService {

    /// 备份文件后缀。与 `/etc/hosts.deepsleep.bak` 同一路子。
    static let backupSuffix = ".deepsleep.bak"

    /// 候选文件名，按「shell + 加载顺序」排列。
    ///
    /// zsh：.zshenv → .zprofile → .zshrc → .zlogin
    /// bash：.bash_profile（通常再 source .bashrc）→ .bashrc
    /// .profile 是 POSIX sh 的老写法，bash 语法是它的超集，用 bash -n 检查即可。
    static let candidateNames = [
        ".zshenv", ".zprofile", ".zshrc", ".zlogin",
        ".bash_profile", ".bashrc", ".profile"
    ]

    /// 候选文件清单（按 shell 与加载顺序）。
    ///
    /// `home` 可注入 —— 测试用临时目录做假 HOME，避免碰用户真实家目录。
    /// 路径用 `FileManager.default.homeDirectoryForCurrentUser` 拼，
    /// 不硬编码 /Users/xxx。
    static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ShellConfigFile] {
        let root = normalizedDirectory(home)
        return candidateNames.map { name in
            let url = root.appendingPathComponent(name)
            return ShellConfigFile(url: url, exists: FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// 文件名 → shell 家族。
    static func shellKind(for fileName: String) -> ShellConfigShell {
        switch fileName {
        case ".zshenv", ".zprofile", ".zshrc", ".zlogin":
            return .zsh
        default:
            return .bash
        }
    }

    /// 读文件内容。
    ///
    /// 文件不存在时**抛错**，不返回空串 —— 「存在但为空」和「不存在」
    /// 在这个工具里是两回事：后者保存时会新建文件，界面要分开提示。
    static func read(_ file: ShellConfigFile) throws -> String {
        guard FileManager.default.fileExists(atPath: file.url.path) else {
            throw ShellConfigError.notFound(file.url.path)
        }
        do {
            return try String(contentsOf: file.url, encoding: .utf8)
        } catch {
            throw ShellConfigError.readFailed("\(file.url.path)：\(error.localizedDescription)")
        }
    }

    /// 写文件内容：先备份 → 原子写入 → 回读校验。
    static func write(_ content: String, to file: ShellConfigFile) throws {
        let fm = FileManager.default
        let url = resolvedTarget(for: file.url)
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 1) 备份「保存前」的内容。文件本来不存在时备份为空串，
        //    这样「恢复备份」总是能回到保存前的状态。
        let oldData = fm.fileExists(atPath: url.path) ? (try? Data(contentsOf: url)) ?? Data() : Data()
        try writeAtomically(oldData, to: backupURL(for: file))

        // 2) 原子写入。权限跟随原文件；新文件用 0644。
        let permissions = currentPermissions(of: url) ?? 0o644
        try writeAtomically(Data(content.utf8), to: url, permissions: permissions)

        // 3) 回读校验：写进去的和想要的不一样就是失败，不能装作成功。
        guard let written = try? Data(contentsOf: url),
              String(decoding: written, as: UTF8.self) == content else {
            throw ShellConfigError.verifyFailed(url.path)
        }
    }

    /// 备份文件路径：<原路径>.deepsleep.bak。
    static func backupURL(for file: ShellConfigFile) -> URL {
        URL(fileURLWithPath: file.url.path + backupSuffix)
    }

    /// 是否存在备份。
    static func hasBackup(for file: ShellConfigFile) -> Bool {
        FileManager.default.fileExists(atPath: backupURL(for: file).path)
    }

    /// 把备份写回原文件。备份本身保持不变（可以反复恢复）。
    static func restoreBackup(for file: ShellConfigFile) throws {
        let backup = backupURL(for: file)
        guard let data = try? Data(contentsOf: backup) else {
            throw ShellConfigError.noBackup(backup.path)
        }
        let url = resolvedTarget(for: file.url)
        let permissions = currentPermissions(of: url) ?? 0o644
        try writeAtomically(data, to: url, permissions: permissions)
        guard let written = try? Data(contentsOf: url), written == data else {
            throw ShellConfigError.verifyFailed(url.path)
        }
    }

    /// 语法检查。返回 nil = 语法没问题；返回字符串 = 错误原文。
    ///
    /// `label` 是错误信息里临时文件路径的替身 —— 用户看到的是
    /// ".zshrc:12: parse error …"，而不是一串 /var/folders 临时路径。
    static func syntaxCheck(content: String,
                            shell: ShellConfigShell,
                            label: String = "内容") -> String? {
        let fm = FileManager.default
        // 每次检查用独立目录：并发检查时共用一个文件会互相删对方的临时文件。
        let dir = fm.temporaryDirectory
            .appendingPathComponent("deepsleep-shellcheck-\(UUID().uuidString)", isDirectory: true)
        let tmp = dir.appendingPathComponent("check.\(shell.rawValue)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: tmp)
        } catch {
            return "语法检查无法运行：\(error.localizedDescription)"
        }
        defer { try? fm.removeItem(at: dir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell.executablePath)
        process.arguments = ["-n", tmp.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "语法检查无法运行：\(error.localizedDescription)"
        }
        // 先读完管道再 wait：否则子进程写满管道缓冲区会死锁。
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return nil }
        let text = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: tmp.path, with: label)
        if text.isEmpty {
            return "语法检查未通过（\(shell.displayName) 退出码 \(process.terminationStatus)）"
        }
        return text
    }

    /// 语法检查磁盘上的文件内容。
    static func syntaxCheck(file: ShellConfigFile) -> String? {
        guard let content = try? read(file) else { return nil }
        return syntaxCheck(content: content, shell: file.shell, label: file.name)
    }

    // MARK: - 内部

    /// 目录 URL 归一化：去掉结尾多余的 /，保证拼出来的路径干净。
    private static func normalizedDirectory(_ url: URL) -> URL {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return URL(fileURLWithPath: path)
    }

    /// 当前文件的 POSIX 权限位。文件不存在时返回 nil。
    private static func currentPermissions(of url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.posixPermissions] as? NSNumber else { return nil }
        return number.intValue
    }

    /// 符号链接解析：只解析最后一层，且只跟随文件自身的软链。
    ///
    /// 为什么重要：.zshrc 有时是 dotfiles 工具（chezmoi / stow / 自建脚本）
    /// 建的符号链接。直接 rename 覆盖会把链接本身换成普通文件 ——
    /// 用户的 dotfiles 仓库就此失联，下次拉取会把内容覆盖回去。
    /// 所以要写到链接指向的真实文件上。
    private static func resolvedTarget(for url: URL) -> URL {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeSymbolicLink else { return url }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
              !destination.isEmpty else { return url }
        // 相对链接按链接所在目录解析
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination)
        }
        return url.deletingLastPathComponent().appendingPathComponent(destination)
    }

    /// 原子写入：同目录临时文件 + rename。
    ///
    /// 临时文件必须在同一目录 —— rename 要求同卷，跨卷会退化成拷贝，
    /// 那就不是原子替换了。
    private static func writeAtomically(_ data: Data,
                                        to url: URL,
                                        permissions: Int? = nil) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).deepsleep.tmp.\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: tmp.path) }

        guard fm.createFile(atPath: tmp.path, contents: data) else {
            throw ShellConfigError.writeFailed("无法创建临时文件 \(tmp.path)")
        }
        let mode = permissions ?? (currentPermissions(of: url) ?? 0o644)
        do {
            try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: tmp.path)
        } catch {
            throw ShellConfigError.writeFailed("无法设置临时文件权限：\(error.localizedDescription)")
        }

        // rename 覆盖是原子的：要么还是旧文件，要么已经是新文件。
        if rename(tmp.path, url.path) != 0 {
            throw ShellConfigError.writeFailed("替换 \(url.path) 失败：\(String(cString: strerror(errno)))")
        }
    }
}

// MARK: - 错误

enum ShellConfigError: LocalizedError {
    case notFound(String)
    case readFailed(String)
    case writeFailed(String)
    case verifyFailed(String)
    case noBackup(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "文件不存在：\(path)"
        case .readFailed(let detail):
            return "读取失败：\(detail)"
        case .writeFailed(let detail):
            return "写入失败：\(detail)"
        case .verifyFailed(let path):
            return "写入后校验不一致：\(path)"
        case .noBackup(let path):
            return "没有备份可恢复：\(path)"
        }
    }
}
