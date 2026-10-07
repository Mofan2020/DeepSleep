//
//  AutoStartManager.swift
//  Deep Sleep
//
//  开机自启：写入 ~/Library/LaunchAgents/com.skyc8266.deepsleep.plist，
//  配合 launchctl bootstrap 让 launchd 在用户登录后启动 Deep Sleep。
//
//  关键决策：
//    - KeepAlive=false：用户主动退出应用后不会被「强行唤起」。
//      开机自启的本意是「开机时启动一次」，不是「让进程永远活着」。
//    - 通过 bundle path 自动适配应用安装位置（不必装在 /Applications）。
//    - 注册 / 注销走 launchctl bootstrap/bootout 而非 lsregister：
//      lsregister 主要用于服务发现，bootstrap/bootout 是 LaunchAgent 的
//      标准生命周期管理命令。
//
//  这份实现不导入系统服务专属框架，纯 Foundation + Process + shell，
//  不需要「完全控制」被安装。
//

import Foundation

public enum AutoStartManager {

    public static let label = "com.skyc8266.deepsleep"

    public static var plistPath: String {
        let home = NSHomeDirectory()
        return "\(home)/Library/LaunchAgents/\(label).plist"
    }

    /// 当前是否已启用。
    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// 启用开机自启。
    public static func enable() throws {
        let path = plistPath
        try ensureParentDirectory(path: path)

        let execPath = Bundle.main.executablePath ?? "/Applications/Deep Sleep.app/Contents/MacOS/Deep Sleep"
        let plist = plistContent(executablePath: execPath)

        try plist.write(toFile: path, atomically: true, encoding: .utf8)

        // 让 launchd 立即加载（已存在则先解绑再绑）。
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"], allowFailure: true)
        runLaunchctl(["bootstrap", "gui/\(getuid())/\(label)", path])
    }

    /// 关闭开机自启。
    public static func disable() throws {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"], allowFailure: true)
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    // MARK: - 内部

    private static func ensureParentDirectory(path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true,
            attributes: nil)
    }

    static func plistContent(executablePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
                <string>--autostart</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
        </dict>
        </plist>
        """
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String], allowFailure: Bool = false) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            if allowFailure { return false }
            return false
        }
    }
}

public enum AutoStartError: LocalizedError {
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let detail):
            return "无法写入 LaunchAgent plist：\(detail)"
        }
    }
}