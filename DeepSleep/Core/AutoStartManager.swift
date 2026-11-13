//
//  AutoStartManager.swift
//  Deep Sleep
//
//  开机自启：写入 ~/Library/LaunchAgents/com.skyc8266.deepsleep.plist，
//  再让 launchd 加载它。
//
//  关键决策：
//    - KeepAlive=false：用户主动退出应用后不会被「强行唤起」。
//      开机自启的本意是「开机时启动一次」，不是「让进程永远活着」。
//    - 通过 bundle path 自动适配应用安装位置（不必装在 /Applications）。
//    - 注册 / 注销走 launchctl bootstrap/bootout。
//
//  **launchd 里有一个「disabled 标记」，它比 plist 本身更强势。**
//  一旦某个 label 被写进这个标记（历史版本用过 `launchctl unload -w`、
//  或者用户在某次系统设置里点掉过），之后无论 plist 写得多正确，launchd
//  在登录时都会**默默跳过**这个任务——不报错、不提示、什么都不发生。
//  所以「打开自启」不能只写 plist，必须同时 `launchctl enable`，
//  应用每次启动还要复查一遍（见 repairIfNeeded）。
//

import Foundation

public enum AutoStartManager {

    public static let label = "com.skyc8266.deepsleep"

    public static var plistPath: String {
        let home = NSHomeDirectory()
        return "\(home)/Library/LaunchAgents/\(label).plist"
    }

    /// 用户是不是打开过「开机自启」——判据是 plist 在不在。
    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// launchd 里到底有没有这个任务（**不看 plist**）。
    ///
    /// 这一条是「自启开关是开的、重启后却什么都没发生」的分水岭：plist 在、
    /// 但任务没在 launchd 里注册（或者被 disabled 标记挡住），登录时就不会
    /// 有任何东西被启动。
    public static var isRegistered: Bool {
        launchctl(["print", "gui/\(getuid())/\(label)"]).status == 0
    }

    /// 启用开机自启。
    public static func enable() throws {
        let path = plistPath
        try ensureParentDirectory(path: path)

        let execPath = Bundle.main.executablePath
            ?? "/Applications/Deep Sleep.app/Contents/MacOS/Deep Sleep"
        let plist = plistContent(executablePath: execPath)

        try plist.write(toFile: path, atomically: true, encoding: .utf8)

        // 先清 disabled 标记，再解绑旧任务，最后绑新的。
        // 顺序不能反：被 disabled 的 label 上 bootstrap 只会返回一句
        // 「Input/output error」，看着像文件坏了，其实是标记在挡。
        _ = launchctl(["enable", "gui/\(getUIDText)/\(label)"])
        _ = launchctl(["bootout", "gui/\(getUIDText)/\(label)"])
        let result = launchctl(["bootstrap", "gui/\(getUIDText)/\(label)", path])
        if result.status != 0 && !isRegistered {
            throw AutoStartError.writeFailed(result.output.isEmpty
                ? "launchctl bootstrap 失败（退出码 \(result.status)）"
                : result.output)
        }
    }

    /// 关闭开机自启。
    public static func disable() throws {
        _ = launchctl(["bootout", "gui/\(getUIDText)/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    /// 应用启动时复查一遍自启，需要就修好。返回给用户看的一句话（没动就 nil）。
    ///
    /// 修三件事：
    /// 1. plist 里的可执行文件路径跟当前 app 不一致（app 挪过位置、或者更新
    ///    时换了目录）——按当前路径重写；
    /// 2. label 在 launchd 里被 disabled——清标记；
    /// 3. plist 在、任务却没注册（例如被别的清理工具 bootout 过）——重新 bootstrap。
    /// 复查要做哪几件事。抽成纯函数是为了能测：这里一旦判错，用户看到的就是
    /// 「开关是开的、重启后什么都没发生」，没有报错可循。
    public struct RepairPlan: Equatable {
        public var rewrite: Bool
        public var reregister: Bool
        public var isEmpty: Bool { !rewrite && !reregister }
    }

    /// - Parameters:
    ///   - plistEnabled: 用户是不是打开过自启（plist 在）
    ///   - registered: launchd 里现在有没有这个任务
    ///   - registeredProgram: plist 里登记的程序路径
    ///   - currentProgram: 当前 app 的真实可执行路径
    public static func plan(plistEnabled: Bool, registered: Bool,
                            registeredProgram: String?,
                            currentProgram: String?) -> RepairPlan {
        guard plistEnabled else { return RepairPlan(rewrite: false, reregister: false) }
        let pathChanged: Bool
        if let registeredProgram, let currentProgram,
           !currentProgram.isEmpty, registeredProgram != currentProgram {
            pathChanged = true
        } else {
            pathChanged = false
        }
        return RepairPlan(rewrite: pathChanged, reregister: pathChanged || !registered)
    }

    @discardableResult
    public static func repairIfNeeded() -> String? {
        guard isEnabled else { return nil }
        var notes: [String] = []

        let expected = Bundle.main.executablePath ?? ""
        if !expected.isEmpty,
           let current = currentProgramPath(),
           current != expected {
            // 路径变了就是「plist 指着一个不存在的程序」，登录时静默失败。
            if (try? enable()) != nil {
                notes.append("自启路径已更新")
            }
        }

        if !isRegistered {
            _ = launchctl(["enable", "gui/\(getUIDText)/\(label)"])
            let bootstrap = launchctl(["bootstrap", "gui/\(getUIDText)/\(label)", plistPath])
            if bootstrap.status == 0 || isRegistered {
                notes.append("自启已重新注册")
            } else {
                // 已经加载过但状态是坏的：kickstart 把它拉起来。
                _ = launchctl(["kickstart", "-k", "gui/\(getUIDText)/\(label)"])
                if isRegistered { notes.append("自启已拉起") }
            }
        }

        guard !notes.isEmpty else { return nil }
        return notes.joined(separator: "，")
    }

    // MARK: - 内部

    private static var getUIDText: String { String(getuid()) }

    /// plist 里登记的启动程序路径。
    private static func currentProgramPath() -> String? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              let first = args.first
        else { return nil }
        return first
    }

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

    /// 跑一次 launchctl，拿退出码和输出（诊断要用输出，不能只看码）。
    @discardableResult
    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
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
