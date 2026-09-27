//
//  SleepController.swift
//  Deep Sleep
//
//  应用的核心状态机：把「用户手动选择」+「自动化规则」两种意图合并成
//  实际要持有的 assertion 集合，再分别通过本地 IOKit 或特权助手落实。
//

import Foundation
import IOKit.pwr_mgt
import Combine

/// 助手状态机。
enum HelperState: Equatable {
    case unknown
    case notInstalled
    case installedNotRunning(String)
    case ready(version: Int)
    case versionMismatch(helper: Int, app: Int)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .unknown:                 return "正在检测…"
        case .notInstalled:            return "未安装"
        case .installedNotRunning:     return "已安装但未运行"
        case .ready:                   return "已启用"
        case .versionMismatch:         return "版本不匹配"
        case .failed:                  return "异常"
        }
    }

    var detail: String {
        switch self {
        case .unknown:
            return "正在与特权助手握手"
        case .notInstalled:
            return "完全控制功能尚未启用，安装后无需再次输入管理员密码"
        case .installedNotRunning(let reason):
            return "助手文件已就位但进程未响应：\(reason)"
        case .ready(let version):
            return "特权助手运行中（协议 v\(version)），提权操作只要求 \(BiometricAuth.availableMethodDescription) 确认"
        case .versionMismatch(let helper, let app):
            return "助手协议 v\(helper) 与应用协议 v\(app) 不一致，请重新安装"
        case .failed(let reason):
            return reason
        }
    }
}

/// 顶部横幅提示。
struct Banner: Identifiable, Equatable {
    enum Level { case success, error, info }
    let id = UUID()
    let level: Level
    let text: String
}

/// 一条运行日志。
struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let text: String
    let isError: Bool
}

@MainActor
final class SleepController: ObservableObject {

    static let shared = SleepController()

    // MARK: - 已发布状态

    /// 用户手动打开的 assertion。
    @Published private(set) var manualAssertions: Set<AssertionKind> = []
    /// 由自动化规则推导出的 assertion。
    @Published private(set) var ruleAssertions: Set<AssertionKind> = []
    /// 当前实际持有的 assertion。
    @Published private(set) var activeAssertions: Set<AssertionKind> = []

    @Published private(set) var helperState: HelperState = .unknown
    /// `pmset disablesleep` 当前值：true 表示系统被完全禁止睡眠（含合盖）。
    @Published private(set) var sleepDisabled = false
    @Published private(set) var powerSettings: [String: String] = [:]
    @Published private(set) var batteryIsOnAC = false

    /// 倒计时（到点进入睡眠）。
    @Published private(set) var countdownDeadline: Date?
    /// 已排定的唤醒时间。
    @Published private(set) var scheduledWake: Date?

    @Published var banner: Banner?
    @Published private(set) var log: [LogEntry] = []

    /// 日志保留条数上限。超出后从最旧的开始丢弃。
    @Published var logRetentionCount: Int = 500 {
        didSet {
            let clamped = max(50, min(logRetentionCount, 5000))
            guard clamped == logRetentionCount else {
                // 回写会再次触发 didSet，那时值已收敛，不会无限递归。
                logRetentionCount = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.logCountKey)
            trimLog()
        }
    }

    /// 日志保留天数上限。0 表示不按时间清理。
    @Published var logRetentionDays: Int = 7 {
        didSet {
            let clamped = max(0, min(logRetentionDays, 365))
            guard clamped == logRetentionDays else {
                logRetentionDays = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.logDaysKey)
            trimLog()
        }
    }

    /// 已被自动清除的条数。让用户知道日志「被清理过」，
    /// 而不是某天发现记录莫名少了一截。
    @Published private(set) var trimmedLogCount = 0
    @Published private(set) var lastTrimAt: Date?

    /// 提权操作是否每次都要求本地授权确认。
    @Published var requireConfirmationPerAction: Bool {
        didSet {
            UserDefaults.standard.set(requireConfirmationPerAction, forKey: Self.confirmationKey)
        }
    }

    /// 本应用是否开启了 `disablesleep`，用于退出时按需恢复。
    private var didEnableSleepDisabled = false

    /// 用户是否要求「完全禁止系统睡眠」。这是**期望态**：
    /// 外部程序改动 pmset 只会改变实际态，不会改变这里，对账时据此纠正。
    @Published private(set) var desiredSleepDisabled = false

    /// 是否因为「完全禁止系统睡眠」而额外持有 PreventSystemSleep 断言。
    /// disablesleep 是持久设置，但主动睡眠请求（合盖 / 菜单睡眠）不一定等它，
    /// 同时持有断言能让 powerd 在睡眠决策阶段就看到我们的意图。
    @Published private(set) var sleepDisabledBacking = false

    /// 对账失败的历史，用于在日志里说明「恢复失败」而不是静默失效。
    private var consecutiveAuditFailures = 0

    /// 对账统计。暴露出来是为了让「对账在跑」这件事可以被外部验证，
    /// 而不是只能相信代码。
    @Published private(set) var auditCount = 0
    @Published private(set) var lastRestoreAt: Date?

    /// 已进行的对账次数与最近一次自动恢复时间，供 CLI / 界面诊断。
    var auditSummary: String {
        let restore = lastRestoreAt.map {
            ISO8601DateFormatter().string(from: $0)
        } ?? "none"
        return "audits=\(auditCount) lastRestore=\(restore)"
    }

    /// 当前所有意图的并集。
    private var desiredAssertions: Set<AssertionKind> {
        var desired = manualAssertions.union(ruleAssertions)
        if sleepDisabledBacking { desired.insert(.preventSystemSleep) }
        return desired
    }

    /// 用户是否表达了「我要保持清醒」的意图。
    /// 睡前拦截时用它做同步判断（必须极快，不能有 IO）。
    private var wantsToStayAwake: Bool {
        desiredSleepDisabled || !desiredAssertions.isEmpty
    }

    let automation = AutomationEngine()

    private var localAssertionIDs: [AssertionKind: IOPMAssertionID] = [:]
    private var remoteHeld: Set<AssertionKind> = []
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var isReconciling = false

    private static let confirmationKey = "com.skyc8266.deepsleep.confirmEachAction"
    private static let logCountKey = "com.skyc8266.deepsleep.logRetentionCount"
    private static let logDaysKey = "com.skyc8266.deepsleep.logRetentionDays"

    private init() {
        requireConfirmationPerAction = UserDefaults.standard.object(forKey: Self.confirmationKey) as? Bool ?? true
        logRetentionCount = UserDefaults.standard.object(forKey: Self.logCountKey) as? Int ?? 500
        logRetentionDays = UserDefaults.standard.object(forKey: Self.logDaysKey) as? Int ?? 7
        automation.onDesiredAssertionsChanged = { [weak self] desired in
            Task { @MainActor in
                guard let self else { return }
                self.ruleAssertions = desired
                await self.reconcile()
            }
        }

        // 睡前拦截：只读内存状态，必须同步返回。
        PowerWatcher.shared.shouldPreventSleep = { [weak self] in
            guard let self else { return false }
            return MainActor.assumeIsolated { self.wantsToStayAwake }
        }

        // 睡前重建防护（可以做 IO）。
        PowerWatcher.shared.rebuildProtection = { [weak self] in
            guard let self else { return false }
            return await self.rebuildProtection()
        }

        // 唤醒后立刻对账：睡眠期间设置可能被外部改动。
        PowerWatcher.shared.didWake = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.appendLog("系统已唤醒，正在核对电源设置")
                await self.auditExternalState()
            }
        }
    }

    // MARK: - 生命周期

    func bootstrap() async {
        appendLog("Deep Sleep 启动，协议 v\(HelperConstants.protocolVersion)")
        await refreshHelperState()
        await refreshPowerSettings()
        await refreshScheduledWake()
        automation.start()
        PowerWatcher.shared.start()
        startRefreshLoop()
        if !PowerWatcher.shared.isRegistered {
            appendLog("电源事件监听未注册，睡前拦截与唤醒对账不可用", isError: true)
        }

        // 应用更新检查延后执行：启动那几秒要留给助手状态与初始断言，
        // 不让一个网络请求跟它们抢时间。
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            await UpdateManager.shared.autoCheckIfDue()
        }
    }

    func shutdown() async {
        refreshTimer?.invalidate()
        refreshTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        automation.stop()
        PowerWatcher.shared.stop()

        // 释放助手侧的 assertion，避免 app 退出后残留占用。
        for kind in remoteHeld {
            _ = try? await HelperClient.shared.send(.init(
                command: .releaseAssertion,
                arguments: ["kind": privilegeKind(for: kind).rawValue]
            ))
        }
        remoteHeld.removeAll()
        releaseLocalAssertions()
        appendLog("Deep Sleep 退出，已释放全部 assertion")
    }

    /// 对账周期。3 秒是为了把「外部改动 → 恢复」的窗口压到最小：
    /// 空闲睡眠通常以分钟计，3 秒足够赶在计时到点之前纠正；
    /// 主动睡眠请求则由 PowerWatcher 的睡前拦截兜底。
    private func startRefreshLoop() {
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let onAC = AutomationEngine.isOnACPower()
                if self.batteryIsOnAC != onAC { self.batteryIsOnAC = onAC }
                await self.auditExternalState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        batteryIsOnAC = AutomationEngine.isOnACPower()
    }

    // MARK: - 助手状态

    func refreshHelperState() async {
        guard HelperInstaller.isInstalled else {
            if helperState != .notInstalled { helperState = .notInstalled }
            return
        }
        let probe = await HelperClient.shared.probe()
        let next: HelperState
        if probe.reachable {
            if let version = probe.protocolVersion, version != HelperConstants.protocolVersion {
                next = .versionMismatch(helper: version, app: HelperConstants.protocolVersion)
            } else {
                next = .ready(version: probe.protocolVersion ?? HelperConstants.protocolVersion)
            }
        } else {
            next = .installedNotRunning(probe.detail)
        }
        // 3 秒一次对账会反复调用本方法，只有真正变化时才发布，避免无谓的界面重绘。
        if helperState != next { helperState = next }
    }

    /// 一次性安装助手。这是全流程中**唯一**需要管理员授权的一步。
    func installHelper() async {
        do {
            banner = Banner(level: .info, text: "正在请求管理员授权以安装特权助手…")
            try await HelperInstaller.install()
            appendLog("特权助手安装脚本执行完成")

            // 等 launchd 把进程拉起来，最多重试 10 次。
            for attempt in 1...10 {
                await refreshHelperState()
                if helperState.isReady { break }
                try? await Task.sleep(nanoseconds: 400_000_000)
                if attempt == 10 {
                    appendLog("助手安装后未能就绪，请查看 /var/log/com.skyc8266.deepsleep.helper.log", isError: true)
                }
            }

            if helperState.isReady {
                banner = Banner(level: .success, text: "完全控制已启用，后续操作只需 \(BiometricAuth.availableMethodDescription) 确认")
            } else {
                banner = Banner(level: .error, text: "助手已写入但未能就绪：\(helperState.detail)")
            }
        } catch {
            appendLog("安装助手失败：\(error.localizedDescription)", isError: true)
            banner = Banner(level: .error, text: error.localizedDescription)
        }
    }

    func uninstallHelper() async {
        await releaseAllAssertions()
        do {
            try await HelperInstaller.uninstall()
            appendLog("特权助手已卸载")
            banner = Banner(level: .success, text: "完全控制已停用，系统文件已清理")
        } catch {
            appendLog("卸载助手失败：\(error.localizedDescription)", isError: true)
            banner = Banner(level: .error, text: error.localizedDescription)
        }
        await refreshHelperState()
    }

    // MARK: - assertion 操作

    func isManual(_ kind: AssertionKind) -> Bool { manualAssertions.contains(kind) }

    /// 明确设置某个 assertion 的开关状态（供 UI 的 Toggle 使用）。
    func setAssertion(_ kind: AssertionKind, enabled: Bool) async {
        if enabled {
            guard !manualAssertions.contains(kind) else { return }
            if kind.requiresPrivilege && !helperState.isReady {
                banner = Banner(level: .error, text: "「\(kind.title)」需要先启用完全控制")
                return
            }
            manualAssertions.insert(kind)
        } else {
            guard manualAssertions.contains(kind) else {
                if sleepDisabledBacking && kind == .preventSystemSleep {
                    banner = Banner(level: .info, text: "「\(kind.title)」由「完全禁止系统睡眠」加固维持，请在「完全控制」页关闭该功能")
                } else if ruleAssertions.contains(kind) {
                    banner = Banner(level: .info, text: "「\(kind.title)」正由自动化规则维持，请到「自动化」页调整对应规则")
                }
                return
            }
            manualAssertions.remove(kind)
        }
        await reconcile()
    }

    /// 切换一个手动 assertion。
    func toggleManual(_ kind: AssertionKind) async {
        await setAssertion(kind, enabled: !manualAssertions.contains(kind))
    }

    /// 一次性释放所有 assertion。
    func releaseAllAssertions() async {
        manualAssertions.removeAll()
        ruleAssertions.removeAll()
        await reconcile()
    }

    /// 合并意图并落实差异。
    private func reconcile() async {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        let desired = desiredAssertions

        // 先释放多余的，再申请缺少的，避免「先申请后释放」造成短暂冲突。
        for kind in activeAssertions.subtracting(desired) {
            await release(kind)
        }
        for kind in desired.subtracting(activeAssertions) {
            await acquire(kind)
        }
    }

    /// - Parameter requireConfirmation: 自动恢复场景传 false。
    ///   用户此前已经就同一意图授权过，恢复是延续该意图，不该反复弹指纹。
    private func acquire(_ kind: AssertionKind, requireConfirmation: Bool = true) async {
        if kind.requiresPrivilege {
            guard helperState.isReady else { return }
            if requireConfirmation {
                guard await confirmPrivilegedAction(reason: "允许 Deep Sleep \(kind.title)") else {
                    manualAssertions.remove(kind)
                    return
                }
            }
            do {
                let response = try await HelperClient.shared.send(.init(
                    command: .acquireAssertion,
                    arguments: ["kind": privilegeKind(for: kind).rawValue, "name": kind.assertionName]
                ))
                if response.success {
                    remoteHeld.insert(kind)
                    activeAssertions.insert(kind)
                    appendLog("已获取「\(kind.title)」（经特权助手）")
                } else {
                    appendLog("获取「\(kind.title)」失败：\(response.message)", isError: true)
                    banner = Banner(level: .error, text: response.message)
                    manualAssertions.remove(kind)
                }
            } catch {
                appendLog("获取「\(kind.title)」失败：\(error.localizedDescription)", isError: true)
                banner = Banner(level: .error, text: error.localizedDescription)
                manualAssertions.remove(kind)
            }
            return
        }

        var identifier = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kind.iokitType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            kind.assertionName as CFString,
            &identifier
        )
        if result == kIOReturnSuccess {
            localAssertionIDs[kind] = identifier
            activeAssertions.insert(kind)
            // 记录 assertion ID：排查时可用 IOPMAssertionRelease 反证断言归属。
            appendLog("已获取「\(kind.title)」（assertion id \(identifier)）")
        } else {
            appendLog("获取「\(kind.title)」失败，IOReturn 0x\(String(result, radix: 16))", isError: true)
            banner = Banner(level: .error, text: "无法获取「\(kind.title)」，系统拒绝了该请求")
        }
    }

    private func release(_ kind: AssertionKind) async {
        if kind.requiresPrivilege {
            // 不依赖 remoteHeld 判断：对账时可能发现助手持有了我们记录之外的断言，
            // 那种情况同样需要发释放命令。
            _ = try? await HelperClient.shared.send(.init(
                command: .releaseAssertion,
                arguments: ["kind": privilegeKind(for: kind).rawValue]
            ))
            remoteHeld.remove(kind)
            activeAssertions.remove(kind)
            appendLog("已释放「\(kind.title)」")
            return
        }

        if let identifier = localAssertionIDs.removeValue(forKey: kind) {
            IOPMAssertionRelease(identifier)
            activeAssertions.remove(kind)
            appendLog("已释放「\(kind.title)」")
        } else {
            activeAssertions.remove(kind)
        }
    }

    private func releaseLocalAssertions() {
        for (_, identifier) in localAssertionIDs {
            IOPMAssertionRelease(identifier)
        }
        localAssertionIDs.removeAll()
        activeAssertions.removeAll()
    }

    private func privilegeKind(for kind: AssertionKind) -> PrivilegedAssertionKind {
        switch kind {
        case .preventSystemSleep:      return .preventSystemSleep
        case .preventIdleSystemSleep:  return .preventIdleSystemSleep
        case .preventIdleDisplaySleep: return .preventIdleDisplaySleep
        }
    }

    /// 提权操作前的本地授权确认。
    private func confirmPrivilegedAction(reason: String) async -> Bool {
        guard requireConfirmationPerAction else { return true }
        let allowed = await BiometricAuth.authenticate(reason: reason)
        if !allowed {
            appendLog("提权操作被拒绝：\(reason)", isError: true)
        }
        return allowed
    }

    // MARK: - 完全禁用睡眠（disablesleep）

    /// 设置 `pmset disablesleep`。这是「合盖也不休眠」的开关。
    func setSleepDisabled(_ disabled: Bool) async {
        guard helperState.isReady else {
            banner = Banner(level: .error, text: "该功能需要先启用完全控制")
            return
        }
        guard await confirmPrivilegedAction(reason: disabled ? "允许 Deep Sleep 完全禁止系统睡眠" : "允许 Deep Sleep 恢复系统睡眠") else {
            return
        }

        // 先落期望态：即使这一次写入失败，后续对账也会持续把它纠回来。
        desiredSleepDisabled = disabled
        // 加固：同时持有一个 PreventSystemSleep 断言。
        // disablesleep 只在 powerd 评估空闲睡眠时起作用，而合盖 / 菜单睡眠是
        // 主动请求，断言才能让 powerd 在决策阶段就挡下来。
        sleepDisabledBacking = disabled
        await reconcile()

        await applySleepDisabled(disabled, announce: true)
        await refreshPowerSettings()
    }

    /// 真正把 disablesleep 写进系统。
    /// - Parameter announce: 自动恢复时不打扰用户，只写日志。
    @discardableResult
    private func applySleepDisabled(_ enabled: Bool, announce: Bool) async -> Bool {
        do {
            let response = try await HelperClient.shared.send(.init(
                command: .setSleepDisabled,
                arguments: ["enabled": enabled ? "1" : "0"]
            ))
            guard response.success else {
                appendLog("设置 disablesleep 失败：\(response.message)", isError: true)
                if announce { banner = Banner(level: .error, text: response.message) }
                return false
            }
            didEnableSleepDisabled = enabled
            sleepDisabled = enabled
            // 告诉监控器这是自己写的，下一轮 diff 别把它当成外部干预。
            PowerActivityMonitor.shared.noteSelfWrite(
                key: "SleepDisabled", value: enabled ? "1" : "0"
            )
            appendLog(announce ? response.message : "已自动恢复系统睡眠设置：\(response.message)")
            if announce { banner = Banner(level: .success, text: response.message) }
            return true
        } catch {
            appendLog("设置 disablesleep 失败：\(error.localizedDescription)", isError: true)
            if announce { banner = Banner(level: .error, text: error.localizedDescription) }
            return false
        }
    }

    /// 退出时若本应用开启过 disablesleep，则恢复系统默认行为。
    func restoreSleepDisabledIfNeeded() async {
        guard didEnableSleepDisabled, helperState.isReady else { return }
        _ = try? await HelperClient.shared.send(.init(
            command: .setSleepDisabled,
            arguments: ["enabled": "0"]
        ))
        didEnableSleepDisabled = false
        appendLog("退出前已恢复系统睡眠设置")
    }

    // MARK: - 外部改动对账

    /// 核对「我们依赖的系统状态」是否被外部改动，并纠正。
    ///
    /// 与 `reconcile()` 的分工：
    ///   `reconcile()`         让实际持有对齐用户意图（内部一致性）
    ///   `auditExternalState()` 让系统状态对齐我们的期望（对抗外部干扰）
    func auditExternalState() async {
        await auditHelperProcess()
        await auditRemoteAssertions()
        await auditLocalAssertions()
        await auditSleepDisabled()
        auditCount += 1

        // 外部活动扫描不跟 3 秒节奏：枚举断言很便宜，但读一次设置要 spawn
        // 一个 pmset 进程，6 秒一次足够看清变化。
        if auditCount % 2 == 0 {
            PowerActivityMonitor.shared.scan()
        }

        // 助手版本检查不跟 3 秒节奏：自我更新会重启助手、翻动 socket。
        // `% 20 == 1` 让首次检查落在启动后几秒内，之后约每分钟一次。
        if auditCount % 20 == 1 {
            await HelperVersionManager.shared.checkAndUpdateIfNeeded()
        }
    }

    /// 助手进程可能被重启（崩溃、被 bootout、系统更新），
    /// 新进程不持有任何断言，而旧断言已随旧进程消失。
    private func auditHelperProcess() async {
        guard HelperInstaller.isInstalled else { return }
        let wasReady = helperState.isReady
        await refreshHelperState()
        if wasReady && !helperState.isReady {
            appendLog("特权助手已失去响应，待其恢复后将重建断言", isError: true)
        }
    }

    /// 核心：核对助手实际持有的断言是否与我们的期望一致。
    private func auditRemoteAssertions() async {
        guard HelperInstaller.isInstalled, helperState.isReady else { return }
        let expected = desiredAssertions.filter { $0.requiresPrivilege }

        guard let response = try? await HelperClient.shared.send(.init(command: .status), timeout: 5),
              response.success else {
            return
        }

        let held = Set(
            (response.payload["assertions"] ?? "")
                .split(separator: ",")
                .compactMap { PrivilegedAssertionKind(rawValue: String($0)) }
                .map(assertionKind(for:))
        )

        // 1) 助手丢了我们以为还在的断言 —— 最典型的场景是助手进程被重启。
        let lost = remoteHeld.subtracting(held)
        if !lost.isEmpty {
            remoteHeld.subtract(lost)
            activeAssertions.subtract(lost)
            appendLog("助手已丢失「\(lost.map(\.title).sorted().joined(separator: "、"))」，正在重建", isError: true)
        }

        // 2) 助手持有我们不再需要的（此前释放未成功），补一次释放。
        let surplus = held.subtracting(expected)
        for kind in surplus {
            await release(kind)
        }

        // 3) 重建缺失的。这里是自动恢复，不再要求授权确认。
        for kind in expected.subtracting(held) {
            appendLog("重建「\(kind.title)」")
            await acquire(kind, requireConfirmation: false)
        }
    }

    /// 本地断言归本进程所有，外部无法释放，这里只防御内部状态漂移。
    private func auditLocalAssertions() async {
        let drifted = activeAssertions.filter { !$0.requiresPrivilege && localAssertionIDs[$0] == nil }
        for kind in drifted {
            activeAssertions.remove(kind)
            appendLog("本地断言「\(kind.title)」状态异常，正在重新申请", isError: true)
            await acquire(kind, requireConfirmation: false)
        }

        let orphans = localAssertionIDs.keys.filter { !activeAssertions.contains($0) }
        for kind in orphans {
            if let identifier = localAssertionIDs.removeValue(forKey: kind) {
                IOPMAssertionRelease(identifier)
            }
        }
    }

    /// 回应「别的程序把 pmset 改回去了」的核心逻辑。
    private func auditSleepDisabled() async {
        guard desiredSleepDisabled, helperState.isReady else { return }

        if Self.readPowerSettingsLocally()["SleepDisabled"] == "1" {
            consecutiveAuditFailures = 0
            return
        }

        appendLog("检测到 disablesleep 被外部改回，立即恢复以防系统进入睡眠", isError: true)
        let restored = await applySleepDisabled(true, announce: false)
        if restored {
            consecutiveAuditFailures = 0
            lastRestoreAt = Date()
            return
        }
        consecutiveAuditFailures += 1
        if consecutiveAuditFailures >= 3 {
            banner = Banner(
                level: .error,
                text: "系统睡眠设置反复被外部改回且恢复失败，请检查是否有其他电源管理工具在同时运行。"
            )
        }
    }

    /// 睡前拦截调用的重建流程。返回防护是否已恢复。
    private func rebuildProtection() async -> Bool {
        await auditExternalState()
        if desiredSleepDisabled {
            return Self.readPowerSettingsLocally()["SleepDisabled"] == "1"
        }
        return desiredAssertions.subtracting(activeAssertions).isEmpty
    }

    private func assertionKind(for privilegeKind: PrivilegedAssertionKind) -> AssertionKind {
        switch privilegeKind {
        case .preventSystemSleep:      return .preventSystemSleep
        case .preventIdleSystemSleep:  return .preventIdleSystemSleep
        case .preventIdleDisplaySleep: return .preventIdleDisplaySleep
        }
    }

    // MARK: - 电源设置读写

    func refreshPowerSettings() async {
        if helperState.isReady,
           let response = try? await HelperClient.shared.send(.init(command: .readPowerSettings)),
           response.success,
           // 助手读不到 SleepDisabled 时不要把它当成「值为 0」。
           // 旧版助手的解析不认 TAB 分隔就会这样，而「读不到」被当成 0
           // 会让「完全禁止睡眠」看起来根本没生效。这种情况下回退到本地读取
           // （`pmset -g` 不需要 root），以本进程的读数为准。
           response.payload["SleepDisabled"] != nil {
            powerSettings = response.payload
            sleepDisabled = response.payload["SleepDisabled"] == "1"
            return
        }
        // 助手不可用或读数不完整时退回本地只读方式。
        powerSettings = Self.readPowerSettingsLocally()
        sleepDisabled = powerSettings["SleepDisabled"] == "1"
    }

    /// 读取系统电源设置。
    /// 解析逻辑在 Shared/PMSetOutput.swift，与特权助手共用同一份实现 ——
    /// 这里原本有一份自己的解析代码，因为只按空格切而读不到 TAB 分隔的
    /// `SleepDisabled`，导致对账永远误判「设置被外部改回」。
    static func readPowerSettingsLocally() -> [String: String] {
        PMSetOutput.readCurrent()
    }

    func writePowerSetting(key: String, value: String) async {
        guard helperState.isReady else {
            banner = Banner(level: .error, text: "修改电源设置需要先启用完全控制")
            return
        }
        guard await confirmPrivilegedAction(reason: "允许 Deep Sleep 修改电源设置 \(key)") else { return }
        do {
            let response = try await HelperClient.shared.send(.init(
                command: .writePowerSetting,
                arguments: ["key": key, "value": value]
            ))
            banner = Banner(level: response.success ? .success : .error, text: response.message)
            appendLog(response.message, isError: !response.success)
            if response.success {
                // 同上：自己写的改动要标记来源，否则会被当成外部干预。
                PowerActivityMonitor.shared.noteSelfWrite(key: key, value: value)
            }
        } catch {
            appendLog("修改电源设置失败：\(error.localizedDescription)", isError: true)
            banner = Banner(level: .error, text: error.localizedDescription)
        }
        await refreshPowerSettings()
    }

    // MARK: - 立即睡眠 / 倒计时

    func sleepNow() async {
        deleteCountdown()
        appendLog("请求立即睡眠")
        // 先释放自身的 assertion，否则请求会被自己挡住。
        await releaseAllAssertions()
        if helperState.isReady {
            if let response = try? await HelperClient.shared.send(.init(command: .sleepNow)) {
                appendLog(response.message, isError: !response.success)
                return
            }
        }
        // 没有助手时用 `pmset sleepnow`，普通用户即可执行。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        do {
            try process.run()
            appendLog("已请求系统睡眠")
        } catch {
            appendLog("请求睡眠失败：\(error.localizedDescription)", isError: true)
            banner = Banner(level: .error, text: error.localizedDescription)
        }
    }

    /// 开始倒计时，结束后进入睡眠。
    func startCountdown(minutes: Int) {
        deleteCountdown()
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        countdownDeadline = deadline
        appendLog("已设定 \(minutes) 分钟后进入睡眠")
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let deadline = self.countdownDeadline else { return }
                if Date() >= deadline {
                    self.deleteCountdown()
                    await self.sleepNow()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    func cancelCountdown() {
        guard countdownDeadline != nil else { return }
        deleteCountdown()
        appendLog("已取消睡眠倒计时")
    }

    private func deleteCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownDeadline = nil
    }

    // MARK: - 计划唤醒

    func refreshScheduledWake() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "sched"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return }

        // 输出形如：`Repeating power events:` / `Scheduled power events:` 后跟
        // ` [0]  wake at 09/28/26 08:00:00 by 'com.apple.alarm'`
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yy HH:mm:ss"
        var found: Date?
        for line in text.split(separator: "\n") {
            guard line.contains("wake at") || line.contains("poweron at") else { continue }
            guard let range = line.range(of: "at ") else { continue }
            let remainder = line[range.upperBound...]
            let candidate = remainder.split(separator: " ").prefix(2).joined(separator: " ")
            if let date = formatter.date(from: candidate), date > Date() {
                if found == nil || date < found! { found = date }
            }
        }
        scheduledWake = found
    }

    func scheduleWake(at date: Date) async {
        guard helperState.isReady else {
            banner = Banner(level: .error, text: "排定唤醒需要先启用完全控制")
            return
        }
        guard await confirmPrivilegedAction(reason: "允许 Deep Sleep 排定一次唤醒") else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yy HH:mm:ss"
        let text = formatter.string(from: date)

        do {
            let response = try await HelperClient.shared.send(.init(
                command: .scheduleWake,
                arguments: ["date": text]
            ))
            banner = Banner(level: response.success ? .success : .error, text: response.message)
            appendLog(response.message, isError: !response.success)
        } catch {
            appendLog("排定唤醒失败：\(error.localizedDescription)", isError: true)
            banner = Banner(level: .error, text: error.localizedDescription)
        }
        await refreshScheduledWake()
    }

    func cancelScheduledWake() async {
        guard helperState.isReady else {
            banner = Banner(level: .error, text: "取消唤醒需要先启用完全控制")
            return
        }
        do {
            let response = try await HelperClient.shared.send(.init(command: .cancelScheduledWake))
            banner = Banner(level: response.success ? .success : .error, text: response.message)
            appendLog(response.message, isError: !response.success)
        } catch {
            appendLog("取消唤醒失败：\(error.localizedDescription)", isError: true)
            banner = Banner(level: .error, text: error.localizedDescription)
        }
        await refreshScheduledWake()
    }

    // MARK: - 日志

    func appendLog(_ text: String, isError: Bool = false) {
        log.append(LogEntry(date: Date(), text: text, isError: isError))
        trimLog()
        NSLog("[DeepSleep] %@", text)
    }

    /// 按条数与天数两个维度裁剪日志。
    ///
    /// 两个维度都要，因为失效方式不同：只限条数时，一台安静运行的机器会把
    /// 几个月前的日志一直留着；只限天数时，一个话痨循环能在几小时内把内存
    /// 撑爆 —— 对账循环正是后者，判断一错就是每 3 秒一条。
    private func trimLog() {
        var removed = 0

        if log.count > logRetentionCount {
            removed += log.count - logRetentionCount
            log.removeFirst(log.count - logRetentionCount)
        }

        if logRetentionDays > 0,
           let cutoff = Calendar.current.date(byAdding: .day, value: -logRetentionDays, to: Date()),
           let oldest = log.first?.date,
           oldest < cutoff {
            let kept = log.filter { $0.date >= cutoff }
            removed += log.count - kept.count
            log = kept
        }

        guard removed > 0 else { return }
        trimmedLogCount += removed
        lastTrimAt = Date()
    }

    func clearLog() {
        log.removeAll()
        trimmedLogCount = 0
    }
}
