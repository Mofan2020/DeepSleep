//
//  QuickQuit.swift
//  Deep Sleep
//
//  快速退出：按下快捷键，把选定的应用连同它们的全部子进程一起强制结束。
//
//  设计要点：
//    - **杀谁由共享的保护名单决定**（`Shared/ProcessGuard.swift`）。
//      这里只负责「把选定的 bundle id 解析成进程树」与「挑一条执行路径」，
//      判断本身不在这里，避免出现第二份规则。
//    - **两条执行路径**：装了特权助手走助手（能结束 root 拥有的进程，
//      也能结束任何用户的应用），没装就退回本进程的权限（只能结束自己的）。
//      回退不是「降级凑数」：绝大多数情况下用户自己的应用用普通权限就能结束。
//    - **dry-run 是一等公民**：`--dry-run` 与 URL 上的 `dry-run=1` 都能让
//      它只打印「将会结束哪些进程」而不动手。这类功能没有演练模式是说不过去的。
//

import AppKit
import Combine

// MARK: - 目标

/// 被选中的、按下快捷键时要退出的应用。
///
/// 存 bundle id 而不是进程号：进程号每次启动都变，bundle id 不是。
/// 也不存 `.app` 路径：同一个应用可能装在别处（构建目录 / 外置盘），
/// 用户选定的是「这个应用」，不是「这个文件」。
struct QuickQuitTarget: Codable, Identifiable, Equatable {
    var bundleIdentifier: String
    var name: String

    var id: String { bundleIdentifier }
}

/// 可供选择的应用。
struct QuickQuitCandidate: Identifiable, Equatable {
    let bundleIdentifier: String
    let name: String
    let path: String?
    let isRunning: Bool

    var id: String { bundleIdentifier }
}

// MARK: - 结果

/// 一次快速退出的完整结果。UI、日志、CLI 三处共用同一份描述。
struct QuickQuitOutcome: Identifiable {
    let id = UUID()
    let date: Date
    let dryRun: Bool
    let usedHelper: Bool
    let report: TerminationReport
    /// 逐行说明：演练时是「将会结束谁」，正常执行时是结果与原因。
    let details: [String]

    var summary: String { report.summary }
}

// MARK: - 引擎

@MainActor
final class QuickQuitEngine: ObservableObject {

    static let shared = QuickQuitEngine()

    // MARK: 已发布状态

    @Published private(set) var targets: [QuickQuitTarget] = []
    @Published private(set) var lastOutcome: QuickQuitOutcome?
    @Published private(set) var isRunning = false

    /// 快捷键是否启用。默认开启 —— 用户打开这个功能就是为了「按下即杀」。
    @Published var isTriggerEnabled: Bool = true {
        didSet {
            guard isTriggerEnabled != oldValue else { return }
            UserDefaults.standard.set(isTriggerEnabled, forKey: Self.enabledKey)
            applyHotkeyRegistration()
        }
    }

    /// 触发前是否需要 Touch ID 确认。默认关闭：这是 panic 按钮，
    /// 一次指纹确认会让它在真正的紧急场景里失去意义。
    @Published var requiresConfirmation: Bool = false {
        didSet {
            guard requiresConfirmation != oldValue else { return }
            UserDefaults.standard.set(requiresConfirmation, forKey: Self.confirmKey)
        }
    }

    /// 快捷键组合。
    @Published private(set) var hotkey: HotkeyCombo = .default

    /// 快捷键当前的问题（被占用 / 不合法）。nil 表示一切正常。
    @Published private(set) var hotkeyProblem: String?

    /// 当前是否真的注册上了。
    var isHotkeyLive: Bool { isTriggerEnabled && GlobalHotkey.shared.isRegistered }

    // MARK: 存储键

    private static let targetsKey = "com.skyc8266.deepsleep.quickQuit.targets"
    private static let hotkeyKey = "com.skyc8266.deepsleep.quickQuit.hotkey"
    private static let enabledKey = "com.skyc8266.deepsleep.quickQuit.enabled"
    private static let confirmKey = "com.skyc8266.deepsleep.quickQuit.confirm"

    private init() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: Self.targetsKey),
           let decoded = try? JSONDecoder().decode([QuickQuitTarget].self, from: data) {
            targets = decoded
        }
        if let data = defaults.data(forKey: Self.hotkeyKey),
           let decoded = try? JSONDecoder().decode(HotkeyCombo.self, from: data) {
            hotkey = decoded
        }
        if defaults.object(forKey: Self.enabledKey) != nil {
            isTriggerEnabled = defaults.bool(forKey: Self.enabledKey)
        }
        if defaults.object(forKey: Self.confirmKey) != nil {
            requiresConfirmation = defaults.bool(forKey: Self.confirmKey)
        }
    }

    // MARK: - 生命周期

    /// 启动时接线：注册热键。由 AppDelegate 在状态机就绪后调用。
    func activate() {
        GlobalHotkey.shared.onTrigger = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                _ = await self.run(dryRun: false, trigger: "快捷键")
            }
        }
        applyHotkeyRegistration()
    }

    func deactivate() {
        GlobalHotkey.shared.onTrigger = nil
        GlobalHotkey.shared.unregister()
    }

    private func applyHotkeyRegistration() {
        guard isTriggerEnabled else {
            GlobalHotkey.shared.unregister()
            hotkeyProblem = nil
            return
        }
        let problem = GlobalHotkey.shared.register(hotkey)
        hotkeyProblem = problem
        if let problem {
            SleepController.shared.appendLog("快速退出快捷键未生效：\(problem)", isError: true)
        }
    }

    /// 换一个快捷键。注册失败时**保留原来的**，不留下「一个都没注册上」的状态。
    func setHotkey(_ combo: HotkeyCombo) {
        let previous = hotkey
        hotkey = combo
        let problem: String?
        if isTriggerEnabled {
            problem = GlobalHotkey.shared.register(combo)
        } else {
            problem = nil
        }

        if let problem, isTriggerEnabled {
            hotkeyProblem = problem
            hotkey = previous
            _ = GlobalHotkey.shared.register(previous)
            SleepController.shared.appendLog("快捷键切换失败：\(problem)", isError: true)
            return
        }

        hotkeyProblem = nil
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: Self.hotkeyKey)
        }
        SleepController.shared.appendLog("快速退出快捷键已设为 \(combo.displayText)")
    }

    // MARK: - 目标管理

    func add(_ target: QuickQuitTarget) {
        guard !targets.contains(where: { $0.bundleIdentifier == target.bundleIdentifier }) else { return }
        guard !ProcessGuard.isProtected(bundleIdentifier: target.bundleIdentifier, name: target.name) else {
            SleepController.shared.appendLog("「\(target.name)」属于受保护的系统进程，不能加入快速退出名单", isError: true)
            return
        }
        targets.append(target)
        targets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persistTargets()
    }

    func add(bundleIdentifier: String, name: String) {
        add(QuickQuitTarget(bundleIdentifier: bundleIdentifier, name: name))
    }

    func remove(_ target: QuickQuitTarget) {
        targets.removeAll { $0.bundleIdentifier == target.bundleIdentifier }
        persistTargets()
    }

    func removeAll() {
        targets.removeAll()
        persistTargets()
    }

    private func persistTargets() {
        if let data = try? JSONEncoder().encode(targets) {
            UserDefaults.standard.set(data, forKey: Self.targetsKey)
        }
    }

    /// 某个目标此刻是否在运行。列表里显示出来，省得用户去猜为什么按了没反应。
    func isRunning(_ target: QuickQuitTarget) -> Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: target.bundleIdentifier)
            .filter { $0.processIdentifier != getpid() }
            .isEmpty
    }

    // MARK: - 候选应用

    /// 可以加入名单的应用：正在运行的常规应用 + 磁盘上的应用。
    ///
    /// 受保护的系统应用**不出现**在候选里：让用户先选中、按键时再被拒绝，
    /// 是比直接不给选更差的体验。
    func candidates() -> [QuickQuitCandidate] {
        var found: [String: QuickQuitCandidate] = [:]

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy != .prohibited,
                  let bundleIdentifier = app.bundleIdentifier,
                  !bundleIdentifier.isEmpty,
                  bundleIdentifier != Bundle.main.bundleIdentifier,
                  let name = app.localizedName else { continue }
            guard !ProcessGuard.isProtected(bundleIdentifier: bundleIdentifier, name: name) else { continue }
            found[bundleIdentifier] = QuickQuitCandidate(
                bundleIdentifier: bundleIdentifier,
                name: name,
                path: app.bundleURL?.path,
                isRunning: true
            )
        }

        for candidate in Self.applicationsOnDisk() where found[candidate.bundleIdentifier] == nil {
            found[candidate.bundleIdentifier] = candidate
        }

        return found.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 扫描常见安装位置的一层子目录。只扫一层：应用就在这一层。
    private static func applicationsOnDisk() -> [QuickQuitCandidate] {
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        ]

        var result: [QuickQuitCandidate] = []
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(entry)
                guard let bundle = Bundle(path: path),
                      let bundleIdentifier = bundle.bundleIdentifier,
                      bundleIdentifier != Bundle.main.bundleIdentifier else { continue }
                let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? (entry as NSString).deletingPathExtension
                guard !ProcessGuard.isProtected(bundleIdentifier: bundleIdentifier, name: name) else { continue }
                result.append(QuickQuitCandidate(
                    bundleIdentifier: bundleIdentifier,
                    name: name,
                    path: path,
                    isRunning: false
                ))
            }
        }
        return result
    }

    /// 受保护名单，供界面展示「哪些绝不会被结束」。
    static var protectedDisplayList: [String] {
        ["访达（Finder）", "程序坞（Dock）", "窗口服务器（WindowServer）", "登录窗口（loginwindow）",
         "系统界面服务（SystemUIServer）", "控制中心", "通知中心", "聚焦（Spotlight）",
         "系统设置", "内核任务（kernel_task）", "launchd（pid 1）", "电源管理（powerd）",
         "权限服务（tccd）", "偏好写入代理（cfprefsd）", "通知总线（distnoted）",
         "磁盘仲裁（diskarbitrationd）", "Spotlight 索引（mds / mdworker）",
         "目录服务（opendirectoryd）", "音频（coreaudiod）", "蓝牙（bluetoothd）",
         "Deep Sleep 本体与特权助手"]
    }

    // MARK: - 执行

    /// 执行一次快速退出。
    ///
    /// - Parameter dryRun: 只算出「会结束哪些进程」并汇报，不真的动手。
    /// - Parameter trigger: 触发来源（快捷键 / 界面按钮 / URL / 快捷指令），
    ///   只用于日志与结果里的措辞。
    @discardableResult
    func run(dryRun: Bool, trigger: String) async -> QuickQuitOutcome {
        guard !isRunning else {
            return QuickQuitOutcome(
                date: Date(), dryRun: dryRun, usedHelper: false,
                report: TerminationReport(),
                details: ["上一次快速退出还没结束，本次已忽略"]
            )
        }
        isRunning = true
        defer { isRunning = false }

        guard !targets.isEmpty else {
            let outcome = QuickQuitOutcome(
                date: Date(), dryRun: dryRun, usedHelper: false,
                report: TerminationReport(),
                details: ["还没有选定任何应用。到「快速退出」页把要一键结束的应用加进名单。"]
            )
            publish(outcome, trigger: trigger)
            return outcome
        }

        if requiresConfirmation && !dryRun {
            let allowed = await BiometricAuth.authenticate(reason: "强制退出选定的应用")
            guard allowed else {
                let outcome = QuickQuitOutcome(
                    date: Date(), dryRun: false, usedHelper: false,
                    report: TerminationReport(),
                    details: ["已取消：未通过身份确认"]
                )
                publish(outcome, trigger: trigger)
                return outcome
            }
        }

        let snapshot = ProcessInventory.snapshot()
        var details: [String] = []
        var roots: [pid_t] = []

        for target in targets {
            let apps = NSRunningApplication
                .runningApplications(withBundleIdentifier: target.bundleIdentifier)
                .filter { $0.processIdentifier != getpid() && $0.processIdentifier > 1 }
            if apps.isEmpty {
                details.append("\(target.name)：未在运行")
                continue
            }
            roots.append(contentsOf: apps.map(\.processIdentifier))
        }

        let plan = ProcessGuard.plan(roots: roots, in: snapshot)
        var report = TerminationReport(
            refused: plan.refusals.map { .init(pid: $0.pid, name: $0.name, reason: $0.reason) },
            skippedDescendants: plan.skippedDescendantCount
        )

        // 目标数上限由共享常量保证应用侧与助手侧一致 ——
        // 否则会出现「助手因为超限整体拒绝、应用却退回本地照样执行」。
        guard plan.targets.count <= ProcessGuard.maximumTargetCount else {
            details.append("待结束的进程数 \(plan.targets.count) 超过上限 \(ProcessGuard.maximumTargetCount)，已整体取消")
            let outcome = QuickQuitOutcome(date: Date(), dryRun: dryRun, usedHelper: false,
                                           report: report, details: details)
            publish(outcome, trigger: trigger)
            return outcome
        }

        if dryRun {
            let names = snapshot.reduce(into: [pid_t: String]()) { partial, process in
                partial[process.pid] = process.name
            }
            for pid in plan.targets {
                details.append("将会结束 \(names[pid] ?? "pid \(pid)")（pid \(pid)）")
            }
            for refusal in report.refused {
                details.append("跳过 \(refusal.name)（pid \(refusal.pid)）：\(refusal.reason)")
            }
            if report.skippedDescendants > 0 {
                details.append("另有 \(report.skippedDescendants) 个进程因位于受保护进程的子树内而跳过")
            }
            if plan.targets.isEmpty && report.refused.isEmpty {
                details.append("没有需要结束的进程")
            }
            let outcome = QuickQuitOutcome(date: Date(), dryRun: true, usedHelper: false,
                                           report: report, details: details)
            publish(outcome, trigger: trigger)
            return outcome
        }

        guard !plan.targets.isEmpty else {
            if !report.refused.isEmpty {
                details.append("目标全部落在受保护名单内，未结束任何进程")
            }
            let outcome = QuickQuitOutcome(date: Date(), dryRun: false, usedHelper: false,
                                           report: report, details: details)
            publish(outcome, trigger: trigger)
            return outcome
        }

        var usedHelper = false

        if SleepController.shared.helperState.isReady {
            let pidList = roots.map(String.init).joined(separator: ",")
            do {
                let response = try await HelperClient.shared.send(
                    .init(command: .terminateProcesses, arguments: ["pids": pidList]),
                    timeout: 15
                )
                if response.success {
                    // 助手把自己算出来的结果回传，应用照实呈现，不合并两边的猜测。
                    var helperReport = TerminationReport.decode(response.payload)
                    helperReport.skippedDescendants = max(
                        helperReport.skippedDescendants, plan.skippedDescendantCount
                    )
                    report.killed = helperReport.killed
                    report.failed = helperReport.failed
                    if !helperReport.refused.isEmpty { report.refused = helperReport.refused }
                    report.skippedDescendants = helperReport.skippedDescendants
                    usedHelper = true
                } else {
                    details.append("特权助手未执行（\(response.message)），改用本进程权限重试")
                }
            } catch {
                details.append("特权助手不可达（\(error.localizedDescription)），改用本进程权限重试")
            }
        }

        if !usedHelper {
            let outcome = ProcessTerminator.terminate(plan.targets, in: snapshot)
            report.killed.append(contentsOf: outcome.killed.map { .init(pid: $0.pid, name: $0.name) })
            report.failed.append(contentsOf: outcome.failed.map {
                .init(pid: $0.pid, name: $0.name, reason: $0.reason)
            })
        }

        for record in report.killed {
            details.append("已结束 \(record.name)（pid \(record.pid)）")
        }
        for failure in report.failed {
            details.append("结束 \(failure.name)（pid \(failure.pid)）失败：\(failure.reason)")
        }
        for refusal in report.refused {
            details.append("跳过 \(refusal.name)（pid \(refusal.pid)）：\(refusal.reason)")
        }
        if report.skippedDescendants > 0 {
            details.append("另有 \(report.skippedDescendants) 个进程因位于受保护进程的子树内而跳过")
        }

        let outcome = QuickQuitOutcome(date: Date(), dryRun: false, usedHelper: usedHelper,
                                       report: report, details: details)
        publish(outcome, trigger: trigger)
        return outcome
    }

    /// 只解析不执行的演练入口，供 CLI 与 URL 使用。
    func dryRunReport() async -> QuickQuitOutcome {
        await run(dryRun: true, trigger: "演练")
    }

    private func publish(_ outcome: QuickQuitOutcome, trigger: String) {
        lastOutcome = outcome
        let prefix = outcome.dryRun ? "快速退出演练" : "快速退出"
        SleepController.shared.appendLog(
            "\(prefix)（\(trigger)）：\(outcome.summary)", isError: !outcome.report.isClean
        )
        if !outcome.dryRun {
            SleepController.shared.banner = Banner(
                level: outcome.report.isClean ? .success : .info,
                text: "\(prefix)：\(outcome.summary)"
            )
        }
    }
}
