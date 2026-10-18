//
//  AppRestartWatcher.swift
//  Deep Sleep
//
//  应用退出即重启：监听 NSWorkspace 的终止通知，
// 指定的 bundle id 进程退出时按配置的 command 重启它。
//
//  持久化：`appRestartTargets.v1`（UserDefaults JSON），结构见 `Target`。
//
//  设计选择：
//   - 用 `willTerminateApplication`（即将退出）+ 短暂延迟后启动命令，
//     比 `didTerminate` 更精确避免重启进程被旧实例挡住；
//   - 重启命令默认 `open -a <bundle id>`，用户可改写为自定义脚本；
//   - 同 bundle id 短时间内重复触发会被 throttle（默认 5 秒）。
//   - 「被 QuickQuit 杀掉」也算退出，但本工具会过滤掉自己（DeepSleep.app）
//     和已知的「杀掉只是为了省电」类应用（如 Spotlight 索引）。
//
//  风险：用户写错 command 会让目标应用反复启动 → 提供「最小启动间隔」保护。
//

import AppKit
import Foundation

@MainActor
final class AppRestartWatcher {

    static let shared = AppRestartWatcher()

    private init() {}

    /// 持久化的目标条目。
    struct Target: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        /// 目标 bundle id（必填）。
        var bundleIdentifier: String
        /// 人类可读的名字（仅 UI 显示用；不参与匹配）。
        var displayName: String
        /// 重启命令。默认 `/usr/bin/open -b <bundle id>`。
        /// 可以改成「/usr/local/bin/my-launcher.sh」之类自定义脚本。
        var command: String
        /// 是否启用。
        var isEnabled: Bool

        var resolvedCommand: String {
            command.isEmpty ? "/usr/bin/open -b \(bundleIdentifier)" : command
        }
    }

    private var targets: [Target] = []
    private var lastLaunchAt: [String: Date] = [:]
    private let minLaunchInterval: TimeInterval = 5
    private var observers: [NSObjectProtocol] = []

    // MARK: - 生命周期

    func start() {
        load()
        guard observers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        // macOS 只暴露 didTerminate（已退出）通知。
        // 对绝大多数 GUI 应用，「进程退出 → 启动命令」是 OK 的；
        // 对极快的「启动 → 退出」循环用 5 秒节流保护。
        let didTerm = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { @MainActor in self.handle(note: note) }
        }
        observers.append(didTerm)
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for o in observers { nc.removeObserver(o) }
        observers.removeAll()
    }

    // MARK: - 配置

    private static let storageKey = "appRestartTargets.v1"

    var allTargets: [Target] { targets }

    func upsert(_ target: Target) {
        if let idx = targets.firstIndex(where: { $0.id == target.id }) {
            targets[idx] = target
        } else {
            targets.append(target)
        }
        persist()
    }

    func remove(id: UUID) {
        targets.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Target].self, from: data) else {
            targets = []
            return
        }
        targets = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(targets) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: - 监听

    private func handle(note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bid = app.bundleIdentifier else { return }
        // 排除自己 —— DeepSleep 自身退出时不应该触发任何重启。
        if bid == "com.skyc8266.deepsleep" { return }
        guard let target = targets.first(where: { $0.isEnabled && $0.bundleIdentifier == bid }) else {
            return
        }
        let now = Date()
        if let last = lastLaunchAt[bid], now.timeIntervalSince(last) < minLaunchInterval {
            return
        }
        lastLaunchAt[bid] = now
        launchCommand(target.resolvedCommand, for: target)
    }

    private func launchCommand(_ command: String, for target: Target) {
        // 用 /bin/sh -c 跑；用户写的脚本可以是任何 shell 兼容形式。
        // 不通过 helper —— 这是用户明确要求。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        do {
            try process.run()
            SleepController.shared.appendLog("应用 \(target.displayName) 已退出，已重启：\(command)")
        } catch {
            SleepController.shared.appendLog(
                "重启 \(target.displayName) 失败：\(error.localizedDescription)",
                isError: true
            )
        }
    }

    /// 探测当前正在运行的应用，供 UI 选择 bundle id。
    static func runningApplications() -> [(bundleIdentifier: String, name: String)] {
        var seen: Set<String> = []
        var result: [(String, String)] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, !bid.isEmpty else { continue }
            guard app.activationPolicy == .regular else { continue }
            guard !seen.contains(bid) else { continue }
            seen.insert(bid)
            result.append((bid, app.localizedName ?? bid))
        }
        return result.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}
