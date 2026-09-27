//
//  HelperInstaller.swift
//  Deep Sleep
//
//  特权助手的一次性安装 / 卸载。
//
//  为什么不用 SMJobBless：SMJobBless 要求开发者证书签名 + 与 Apple 的
//  信任关系校验，在本地开发 / 自签名场景下无法落地。这里改用更直接、
//  完全可回退的方式：把 app 内置的 helper 二进制与一份 LaunchDaemon
//  描述文件通过**一次**管理员授权写入系统目录，之后 launchd 会常驻拉起它。
//
//  权限提示只出现这一次；此后所有提权操作都走本地授权（Touch ID）。
//
//  实际的 shell 逻辑放在 Resources/install-helper.sh 和
//  Resources/uninstall-helper.sh 两个独立脚本里 —— 这样这两个会以 root
//  身份运行、会改动 /Library 的动作可以被静态检查（sh -n）与 dry-run 验证，
//  而不是藏在 Swift 的字符串插值里。
//

import Foundation

enum HelperInstallError: LocalizedError {
    case embeddedHelperMissing(String)
    case scriptResourceMissing(String)
    case authorizationCancelled
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .embeddedHelperMissing(let path):
            return "应用内置的助手程序不存在：\(path)"
        case .scriptResourceMissing(let name):
            return "应用内置的脚本缺失：\(name)"
        case .authorizationCancelled:
            return "用户取消了管理员授权，助手未安装"
        case .scriptFailed(let output):
            return "脚本执行失败：\(output)"
        }
    }
}

enum HelperInstaller {

    /// app bundle 内置的 helper 路径。
    static var embeddedHelperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/PrivilegedHelperTools/deepsleep-helper")
            .path
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: HelperConstants.installedHelperPath)
    }

    /// 脚本会读取的全部环境变量。集中在这里，保证与脚本里的
    /// `${VAR:?}` 断言一一对应。
    private static func environment(includeSource: Bool) -> [(String, String)] {
        var pairs: [(String, String)] = []
        if includeSource {
            pairs.append(("HELPER_SRC", embeddedHelperPath))
        }
        pairs.append(("HELPER_DEST", HelperConstants.installedHelperPath))
        pairs.append(("DAEMON_PLIST", HelperConstants.launchDaemonPath))
        pairs.append(("DAEMON_LABEL", HelperConstants.label))
        pairs.append(("SOCKET_PATH", HelperConstants.socketPath))
        pairs.append(("LOG_PATH", HelperConstants.logPath))
        return pairs
    }

    /// 执行一次性安装。会弹出系统管理员授权对话框
    /// （在已配置 Touch ID 的机器上该对话框可直接用指纹确认）。
    static func install() async throws {
        guard FileManager.default.isExecutableFile(atPath: embeddedHelperPath) else {
            throw HelperInstallError.embeddedHelperMissing(embeddedHelperPath)
        }
        let script = try scriptPath(named: "install-helper")
        try await runWithAdministratorPrivileges(
            scriptPath: script,
            environment: environment(includeSource: true)
        )
    }

    /// 卸载助手，恢复系统原状。所有写入过的路径都会被清理。
    static func uninstall() async throws {
        let script = try scriptPath(named: "uninstall-helper")
        try await runWithAdministratorPrivileges(
            scriptPath: script,
            environment: environment(includeSource: false)
        )
    }

    // MARK: - 私有

    /// 取出 bundle 内的脚本并返回其路径。
    private static func scriptPath(named name: String) throws -> String {
        if let url = Bundle.main.url(forResource: name, withExtension: "sh") {
            return url.path
        }
        // 开发期直接从源码目录运行二进制时，bundle 资源可能尚未就位。
        // 退回源码目录查找，仅用于本机调试。
        let fallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Privileged/
            .deletingLastPathComponent()   // DeepSleep/
            .appendingPathComponent("Resources/\(name).sh")
            .path
        if FileManager.default.fileExists(atPath: fallback) {
            return fallback
        }
        throw HelperInstallError.scriptResourceMissing(name + ".sh")
    }

    /// 用 osascript 请求一次性管理员授权来运行脚本。
    /// 命令行形如 `VAR='x' VAR2='y' /bin/sh '/path/script.sh'`，
    /// 由 /bin/sh 自行给脚本注入这些环境变量。
    private static func runWithAdministratorPrivileges(
        scriptPath: String,
        environment: [(String, String)]
    ) async throws {
        let assignments = environment
            .map { "\($0.0)=\(shellQuoted($0.1))" }
            .joined(separator: " ")
        let command = "\(assignments) /bin/sh \(shellQuoted(scriptPath))"

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // AppleScript 字符串内的反斜杠与双引号需要转义。
                let escaped = command
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", appleScript]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: HelperInstallError.scriptFailed(error.localizedDescription))
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume()
                } else if output.contains("-128") || output.localizedCaseInsensitiveContains("User canceled") {
                    continuation.resume(throwing: HelperInstallError.authorizationCancelled)
                } else {
                    continuation.resume(throwing: HelperInstallError.scriptFailed(
                        output.isEmpty ? "退出码 \(process.terminationStatus)" : output
                    ))
                }
            }
        }
    }

    /// POSIX 单引号转义：把值安全地包进单引号，内部的单引号用 '\'' 表示。
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
