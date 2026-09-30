//
//  URLCommands.swift
//  Deep Sleep
//
//  `deepsleep://` URL 接口。
//
//  为什么除了 App Intents 之外还需要它：
//    - App Intents 覆盖的是 Siri 与「快捷指令」。**自动操作（Automator）**、
//      AppleScript 的 `open location`、以及任何能执行 shell 的地方，
//      最省事的接入方式都是一个 URL。
//    - `open -a "Deep Sleep" --args ...` 只在**首次启动**时生效（macOS 单实例
//      行为），重复调用会被静默忽略；URL 则是每次都能送到正在运行的那个实例。
//      这是 docs/gotchas.md 第 9 条的直接后果，也是这里存在的主要理由。
//
//  命令表只写一遍：界面说明区块、`--automation` 自检输出、以及下面的解析
//  分支共用 `commands`，避免出现「文档里有、代码里没有」的漂移。
//

import AppKit
import Foundation

enum DeepSleepURL {

    static let scheme = "deepsleep"

    /// 一条 URL 命令的说明。
    struct Command: Identifiable {
        let name: String
        let example: String
        let summary: String
        var id: String { name }
    }

    /// 命令全集。改这里就要同步 `README.md` 与 `docs/architecture.md`
    /// —— `scripts/check-docs.py` 会比对这张表与文档。
    static let commands: [Command] = [
        Command(name: "hold",
                example: "deepsleep://hold?kind=idle-system,system&minutes=60",
                summary: "保持清醒。kind 逗号分隔（idle-system / display / system / lid / all），minutes 为可选时长"),
        Command(name: "release",
                example: "deepsleep://release",
                summary: "释放全部保持"),
        Command(name: "status",
                example: "deepsleep://status",
                summary: "把当前状态显示在界面上"),
        Command(name: "sleep-now",
                example: "deepsleep://sleep-now",
                summary: "立即进入睡眠"),
        Command(name: "wake",
                example: "deepsleep://wake?in=60",
                summary: "排定定时唤醒。in 为分钟数，或 at=HH:mm"),
        Command(name: "cancel-wake",
                example: "deepsleep://cancel-wake",
                summary: "取消已排定的唤醒"),
        Command(name: "disable-sleep",
                example: "deepsleep://disable-sleep?value=1",
                summary: "完全禁止（value=1）或恢复（value=0）系统睡眠，需要完全控制"),
        Command(name: "quick-quit",
                example: "deepsleep://quick-quit",
                summary: "强制退出选定的应用。加 dry-run=1 只演练不执行"),
        Command(name: "show",
                example: "deepsleep://show",
                summary: "打开主界面")
    ]

    /// 处理一个 URL。
    ///
    /// - Returns: 给日志与横幅用的一句话；不是本应用的 URL 时返回 nil。
    @MainActor
    static func handle(_ url: URL) async -> String? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        let rawName = url.host ?? url.path
        let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard !name.isEmpty else { return nil }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? {
            items.first { $0.name.lowercased() == key }?.value
        }
        func isOn(_ key: String) -> Bool {
            guard let raw = value(key)?.lowercased() else { return false }
            return ["1", "true", "yes", "on", ""].contains(raw)
        }

        let controller = SleepController.shared
        await controller.ensureReady()

        switch name {
        case "hold":
            // kind=all 等价于「连合盖也不睡」，与 --hold 的别名保持一致。
            let rawKinds = value("kind") ?? value("kinds") ?? "idle-system"
            let kinds = Set(rawKinds
                .split(separator: ",")
                .compactMap { AssertionKind.fromCLIName(String($0)) })

            if kindMeansEverything(rawKinds) {
                await controller.setSleepDisabled(true)
                guard controller.sleepDisabled else {
                    return "无法完全禁止睡眠：请先在应用内启用完全控制"
                }
                return "已完全禁止系统睡眠（合盖也不休眠）"
            }

            guard !kinds.isEmpty else {
                return "无法识别的保持类型：\(rawKinds)"
            }

            let minutes = value("minutes").flatMap { Int($0) }
            let result = await controller.hold(assertions: kinds, minutes: minutes)
            if result.applied.isEmpty {
                return "未能生效：\(result.rejected.map(\.title).joined(separator: "、"))（需要完全控制或授权被拒绝）"
            }
            var text = "已保持：\(result.applied.map(\.title).joined(separator: "、"))"
            if !result.rejected.isEmpty {
                text += "；未生效：\(result.rejected.map(\.title).joined(separator: "、"))"
            }
            if let minutes, minutes > 0 {
                text += "；\(minutes) 分钟后自动释放"
            }
            return text

        case "release":
            await controller.releaseAllAssertions()
            return "已释放全部保持"

        case "status":
            WindowCoordinator.shared.showMainWindow()
            let text = controller.statusSummary
            controller.banner = Banner(level: .info, text: text)
            return text

        case "sleep-now":
            await controller.sleepNow()
            return "已请求进入睡眠"

        case "wake":
            let date: Date?
            if let minutes = value("in").flatMap({ Int($0) }) {
                date = Date().addingTimeInterval(TimeInterval(minutes * 60))
            } else if let clock = value("at") {
                date = dateFromClock(clock)
            } else {
                date = nil
            }
            guard let date else {
                return "wake 需要 in=<分钟> 或 at=<HH:mm>"
            }
            await controller.scheduleWake(at: date)
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            return controller.scheduledWake != nil
                ? "已排定唤醒：\(formatter.string(from: date))"
                : "排定唤醒失败：需要完全控制"

        case "cancel-wake":
            await controller.cancelScheduledWake()
            return "已取消排定的唤醒"

        case "disable-sleep":
            let enable = isOn("value")
            await controller.setSleepDisabled(enable)
            if enable && !controller.sleepDisabled { return "无法完全禁止睡眠：需要完全控制" }
            return enable ? "已完全禁止系统睡眠" : "已恢复系统正常睡眠"

        case "quick-quit":
            let outcome = await QuickQuitEngine.shared.run(dryRun: isOn("dry-run"), trigger: "URL")
            return "\(outcome.dryRun ? "演练" : "快速退出")：\(outcome.summary)"

        case "show":
            WindowCoordinator.shared.showMainWindow()
            return "已打开 Deep Sleep 主界面"

        default:
            return "无法识别的命令「\(name)」，可用命令见 --automation"
        }
    }

    /// `kind=all` / `lid` / `clamshell` 这类写法要落到「连合盖也不睡」，
    /// 与 `--hold` 的别名规则一致。
    private static func kindMeansEverything(_ raw: String) -> Bool {
        let normalized = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return normalized.contains(where: ["all", "lid", "clamshell"].contains)
    }

    /// 解析 `HH:mm`。早于此刻的当作明天。
    private static func dateFromClock(_ text: String) -> Date? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        let calendar = Calendar.current
        guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) else {
            return nil
        }
        return today > Date() ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
}
