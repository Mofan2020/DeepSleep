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

    /// 提权操作是否每次都要求本地授权确认。
    @Published var requireConfirmationPerAction: Bool {
        didSet {
            UserDefaults.standard.set(requireConfirmationPerAction, forKey: Self.confirmationKey)
        }
    }

    /// 本应用是否开启了 `disablesleep`，用于退出时按需恢复。
    private var didEnableSleepDisabled = false

    let automation = AutomationEngine()

    private var localAssertionIDs: [AssertionKind: IOPMAssertionID] = [:]
    private var remoteHeld: Set<AssertionKind> = []
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var isReconciling = false

    private static let confirmationKey = "com.skyc8266.deepsleep.confirmEachAction"

    private init() {
        requireConfirmationPerAction = UserDefaults.standard.object(forKey: Self.confirmationKey) as? Bool ?? true
        automation.onDesiredAssertionsChanged = { [weak self] desired in
            Task { @MainActor in
                guard let self else { return }
                self.ruleAssertions = desired
                await self.reconcile()
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
        startRefreshLoop()
    }

    func shutdown() async {
        refreshTimer?.invalidate()
        refreshTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        automation.stop()

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

    private func startRefreshLoop() {
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.batteryIsOnAC = AutomationEngine.isOnACPower()
                if !self.helperState.isReady {
                    await self.refreshHelperState()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        batteryIsOnAC = AutomationEngine.isOnACPower()
    }

    // MARK: - 助手状态

    func refreshHelperState() async {
        guard HelperInstaller.isInstalled else {
            helperState = .notInstalled
            return
        }
        let probe = await HelperClient.shared.probe()
        if probe.reachable {
            if let version = probe.version, version != HelperConstants.protocolVersion {
                helperState = .versionMismatch(helper: version, app: HelperConstants.protocolVersion)
            } else {
                helperState = .ready(version: probe.version ?? HelperConstants.protocolVersion)
            }
        } else {
            helperState = .installedNotRunning(probe.detail)
        }
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
                if ruleAssertions.contains(kind) {
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

        let desired = manualAssertions.union(ruleAssertions)

        // 先释放多余的，再申请缺少的，避免「先申请后释放」造成短暂冲突。
        for kind in activeAssertions.subtracting(desired) {
            await release(kind)
        }
        for kind in desired.subtracting(activeAssertions) {
            await acquire(kind)
        }
    }

    private func acquire(_ kind: AssertionKind) async {
        if kind.requiresPrivilege {
            guard helperState.isReady else { return }
            guard await confirmPrivilegedAction(reason: "允许 Deep Sleep \(kind.title)") else {
                manualAssertions.remove(kind)
                return
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
            appendLog("已获取「\(kind.title)」")
        } else {
            appendLog("获取「\(kind.title)」失败，IOReturn 0x\(String(result, radix: 16))", isError: true)
            banner = Banner(level: .error, text: "无法获取「\(kind.title)」，系统拒绝了该请求")
        }
    }

    private func release(_ kind: AssertionKind) async {
        if kind.requiresPrivilege {
            guard remoteHeld.contains(kind) else {
                activeAssertions.remove(kind)
                return
            }
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
        do {
            let response = try await HelperClient.shared.send(.init(
                command: .setSleepDisabled,
                arguments: ["enabled": disabled ? "1" : "0"]
            ))
            if response.success {
                sleepDisabled = disabled
                didEnableSleepDisabled = disabled
                appendLog(response.message)
                banner = Banner(level: .success, text: response.message)
            } else {
                appendLog("设置失败：\(response.message)", isError: true)
                banner = Banner(level: .error, text: response.message)
            }
        } catch {
            appendLog("设置失败：\(error.localizedDescription)", isError: true)
            banner = Banner(level: .error, text: error.localizedDescription)
        }
        // 以系统实际值为准，避免 UI 与真实状态不一致。
        await refreshPowerSettings()
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

    // MARK: - 电源设置读写

    func refreshPowerSettings() async {
        if helperState.isReady {
            if let response = try? await HelperClient.shared.send(.init(command: .readPowerSettings)),
               response.success {
                powerSettings = response.payload
                sleepDisabled = response.payload["SleepDisabled"] == "1"
                return
            }
        }
        // 助手不可用时退回本地只读方式（`pmset -g` 不需要 root）。
        powerSettings = Self.readPowerSettingsLocally()
        sleepDisabled = powerSettings["SleepDisabled"] == "1"
    }

    static func readPowerSettingsLocally() -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var settings: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasSuffix(":") else { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if let paren = value.firstIndex(of: "(") {
                value = String(value[value.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
            }
            settings[String(parts[0])] = value
        }
        return settings
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
        let entry = LogEntry(date: Date(), text: text, isError: isError)
        log.append(entry)
        if log.count > 300 {
            log.removeFirst(log.count - 300)
        }
        NSLog("[DeepSleep] %@", text)
    }

    func clearLog() {
        log.removeAll()
    }
}
