//
//  HangDetector.swift
//  Deep Sleep
//
//  未响应应用的检测引擎。
//
//  设计要点：
//    - **误报比漏报更糟**，而「问应用」这条路本身就会误报。
//
//      最早的做法是拿辅助功能（AX）去问每个应用：
//      `AXUIElementCopyAttributeValue(app, kAXWindowsAttribute)`，超时就算卡死。
//      这条判据把两件完全不同的事混成一件：
//
//        1. 应用真的卡住了，不处理消息；
//        2. 应用活得好好的，只是辅助功能树没实现全、或者响应慢。
//
//      Telegram 属于第二类。它是体量很大的原生应用，辅助功能查询经常
//      赶不上 2 秒，于是被反复误报「未响应」—— 而它其实一点毛病没有。
//
//    - **改问系统**。判据换成 WindowServer 自己维护的「是否响应」状态，
//      也就是活动监视器（Activity Monitor）与「强制退出」窗口背后
//      用的那一份：`CGSEventIsAppUnresponsive`。详见文件末尾
//      `WindowServerResponsiveness` 的注释与实测数据。
//
//      这一条不经过应用，不需要辅助功能授权，也不会因为应用
//      「辅助功能做得不好」而误报。
//
//    - **一次不算数**。连续 2 轮都是「未响应」才提示，宁可漏报。
//    - **系统判定接口取不到就整块停用**，如实告知，绝不拿猜的判据顶替。
//    - **检测不占主线程**：问 WindowServer 是纯 C 调用，放在后台任务里跑。
//
import AppKit
import Combine
import Carbon

// MARK: - 常量

/// 连续几轮都是「未响应」才算数。
///
/// 1 轮太急：应用刚从卡住里恢复的那一刻，系统判定会抖一下，2 轮才稳。
private let hangRequiredConsecutiveFailures = 2

// MARK: - 事件

/// 一次「应用无响应」的事件。
public struct HangEvent: Sendable {
    public let pid: pid_t
    public let bundleID: String
    public let appName: String
    public let detectedAt: Date
    /// 为什么判定它无响应。给用户看的一句话。
    public let reason: String

    public init(pid: pid_t,
                bundleID: String,
                appName: String,
                detectedAt: Date = Date(),
                reason: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.detectedAt = detectedAt
        self.reason = reason
    }
}

/// 一轮检测的结果摘要，给配置页展示。
public struct HangCheckSummary: Equatable, Sendable {
    /// 这一轮什么时候跑的。
    public let date: Date
    /// 这一轮问了多少个应用。
    public let scannedCount: Int
    /// 这一轮有几个被判定为未响应。
    public let hungCount: Int
    /// 当时系统判定接口（WindowServer）能不能用。
    ///
    /// 不再是「有没有辅助功能权限」—— 现在的判据不需要那个授权。
    public let probeAvailable: Bool
    /// 一句话说明。
    public let message: String

    public init(date: Date,
                scannedCount: Int,
                hungCount: Int,
                probeAvailable: Bool,
                message: String) {
        self.date = date
        self.scannedCount = scannedCount
        self.hungCount = hungCount
        self.probeAvailable = probeAvailable
        self.message = message
    }
}

// MARK: - 检测器

/// 后台定时检测哪些应用卡死了。
///
/// 用法（主 Agent 接线）：
/// ```swift
/// HangDetector.shared.onHangDetected = { event in
///     HangAlertPresenter.shared.present(event: event, anchor: anchor) { ... }
/// }
/// HangDetector.shared.start()
/// ```
@MainActor
public final class HangDetector: ObservableObject {

    public static let shared = HangDetector()

    /// 检测到未响应应用时的回调。在主线程调用。
    public var onHangDetected: ((HangEvent) -> Void)?

    /// 上一轮检测的摘要。配置页读它显示「最近一次检测结果」。
    @Published public private(set) var lastSummary: HangCheckSummary?

    /// 系统判定接口（WindowServer 的「是否响应」）当前能不能用。
    ///
    /// 这不是权限问题，是符号可用性问题：那三个 C 函数不是公开 API，
    /// 未来系统版本可能把符号拿掉。取不到时整块检测停用，
    /// 界面如实显示「系统判定接口不可用」，不拿别的判据顶替。
    @Published public private(set) var probeAvailable: Bool = WindowServerResponsiveness.isAvailable

    /// 检测能力是否可用。保留这个名字给界面用。
    public var isProbeAvailable: Bool { probeAvailable }

    /// 辅助功能权限是否已授予。
    ///
    /// 当前的判据走 WindowServer，**不需要**这项权限；它只在排查问题
    /// （对比「系统判定」与「辅助功能」两种口径）时有参考价值。
    /// 保留这个名字是因为对外契约里约定过，界面与接线照旧可读。
    public var isPermissionAvailable: Bool { AXIsProcessTrusted() }

    // MARK: 内部状态

    private var timer: Timer?
    private var isScanning = false
    /// 用户点过「忽略」的进程。在它退出之前不再提示。
    private var ignoredPIDs: Set<pid_t> = []
    /// 每个进程连续超时的轮数。
    private var failureCounts: [pid_t: Int] = [:]
    /// 已经提示过的进程。避免同一个进程反复弹面板。
    private var reportedPIDs: Set<pid_t> = []

    private init() {}

    // MARK: - 生命周期

    /// 开始定时检测。重复调用会按当前配置重新起一次计时器。
    public func start() {
        stop()
        let config = HangDetectionConfig.load()
        guard config.enabled else { return }

        let interval = TimeInterval(max(1, config.detectionIntervalSeconds))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runCycle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // 起一次，马上给用户第一轮结果，不用干等一个间隔。
        Task { @MainActor in
            self.runCycle()
        }
    }

    /// 停止检测。
    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 立刻检测一次，不等计时器。
    public func checkNow() {
        runCycle()
    }

    // MARK: - 检测循环

    private func runCycle() {
        guard !isScanning else { return }
        let config = HangDetectionConfig.load()
        guard config.enabled else { return }

        // 每轮读一次接口可用性，界面显示的是当下真实状态。
        probeAvailable = WindowServerResponsiveness.isAvailable

        let running = runningRegularApplications()
        pruneStaleState(live: Set(running.map(\.pid)))

        let candidates = HangCandidateFilter
            .filter(running.map(\.candidate), config: config, ownBundleIDs: ownBundleIDs)
            .filter { !ignoredPIDs.contains($0.pid) }

        guard !candidates.isEmpty else {
            lastSummary = HangCheckSummary(
                date: Date(),
                scannedCount: 0,
                hungCount: 0,
                probeAvailable: probeAvailable,
                message: "没有需要检测的应用"
            )
            return
        }

        guard probeAvailable else {
            // 接口拿不到就什么都不判 —— 换成别的判据只会重演 Telegram 那次误报。
            lastSummary = HangCheckSummary(
                date: Date(),
                scannedCount: candidates.count,
                hungCount: 0,
                probeAvailable: false,
                message: "系统判定接口不可用，无法检测"
            )
            return
        }

        // 问系统。纯 C 调用，但还是放到后台，别让主线程等 WindowServer 回话。
        isScanning = true
        let pids = candidates.map(\.pid)
        Task { @MainActor [weak self] in
            let outcomes = await Task.detached(priority: .utility) {
                WindowServerResponsiveness.snapshot(pids: pids)
            }.value
            self?.finishCycle(candidates: candidates, outcomes: outcomes)
        }
    }

    /// 处理一轮结果，必要时发出事件。
    ///
    /// 判据只有一个来源：WindowServer 说它未响应。这里只负责
    /// 「连续几轮都这样才算数」和「同一个应用只提示一次」。
    private func finishCycle(candidates: [HangCandidate], outcomes: [pid_t: Bool]) {
        isScanning = false

        var events: [HangEvent] = []
        for candidate in candidates {
            guard let unresponsive = outcomes[candidate.pid] else {
                // 问不出结果（比如这个进程没注册到图形系统）—— 不判定。
                failureCounts[candidate.pid] = nil
                continue
            }
            guard unresponsive else {
                // 系统说它正常。计数清零，下次真卡死还能再提示。
                failureCounts[candidate.pid] = nil
                reportedPIDs.remove(candidate.pid)
                continue
            }
            let count = (failureCounts[candidate.pid] ?? 0) + 1
            failureCounts[candidate.pid] = count
            guard count >= hangRequiredConsecutiveFailures,
                  !reportedPIDs.contains(candidate.pid),
                  !ignoredPIDs.contains(candidate.pid) else { continue }
            reportedPIDs.insert(candidate.pid)
            events.append(HangEvent(
                pid: candidate.pid,
                bundleID: candidate.bundleID,
                appName: candidate.appName,
                detectedAt: Date(),
                reason: "系统连续 \(count) 轮判定为未响应"
            ))
        }

        let hungCount = events.count
        lastSummary = HangCheckSummary(
            date: Date(),
            scannedCount: candidates.count,
            hungCount: hungCount,
            probeAvailable: true,
            message: hungCount > 0
                ? "检查了 \(candidates.count) 个应用，\(hungCount) 个未响应"
                : "检查了 \(candidates.count) 个应用，都正常"
        )

        for event in events {
            onHangDetected?(event)
        }
    }

    /// 清掉已经不在的进程留下的计数。
    private func pruneStaleState(live: Set<pid_t>) {
        for pid in failureCounts.keys where !live.contains(pid) {
            failureCounts.removeValue(forKey: pid)
        }
        for pid in reportedPIDs where !live.contains(pid) {
            reportedPIDs.remove(pid)
        }
        for pid in ignoredPIDs where !live.contains(pid) {
            ignoredPIDs.remove(pid)
        }
    }

    // MARK: - 用户动作

    /// 忽略：这个进程不再提示（直到它退出）。
    public func ignore(event: HangEvent) {
        guard event.pid != getpid() else { return }
        ignoredPIDs.insert(event.pid)
        failureCounts.removeValue(forKey: event.pid)
        reportedPIDs.remove(event.pid)
    }

    /// 强制退出：先温和 terminate，不动就 kill。
    public func forceQuit(event: HangEvent) {
        guard event.pid != getpid() else { return }
        markHandled(event.pid)
        Task { [weak self] in
            await Self.terminateProcess(pid: event.pid)
            self?.markHandled(event.pid)
        }
    }

    /// 重启：先结束，再用它自己的 bundle 重新拉起来。
    public func restart(event: HangEvent) {
        guard event.pid != getpid() else { return }
        // 路径要在进程还在的时候拿 —— 结束后就取不到了。
        let bundleURL = NSRunningApplication(processIdentifier: event.pid)?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: event.bundleID)
        markHandled(event.pid)
        Task { [weak self] in
            await Self.terminateProcess(pid: event.pid)
            self?.markHandled(event.pid)
            guard let bundleURL else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
                if let error {
                    NSLog("Deep Sleep: 重启 \(bundleURL.lastPathComponent) 失败 —— \(error.localizedDescription)")
                }
            }
        }
    }

    private func markHandled(_ pid: pid_t) {
        failureCounts.removeValue(forKey: pid)
        reportedPIDs.remove(pid)
    }

    // MARK: - 进程辅助

    /// 温和退出：先 terminate，给 2 秒，再 kill。
    private nonisolated static func terminateProcess(pid: pid_t) async {
        if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            _ = app.terminate()
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            kill(pid, SIGKILL)
        }
        // 等它真的消失，避免重启时拉起的是旧的残留实例。
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    /// 枚举正在运行的常规应用（`.regular` 激活策略）。
    /// 后台 agent、菜单栏小工具不参与检测。
    private func runningRegularApplications() -> [RunningApp] {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var result: [RunningApp] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { continue }
            result.append(RunningApp(
                pid: app.processIdentifier,
                bundleID: bundleID,
                appName: app.localizedName ?? bundleID,
                bundlePath: app.bundleURL?.path,
                isForeground: app.processIdentifier == frontmost
            ))
        }
        return result
    }

    /// 本应用与特权助手的 bundle id。
    private var ownBundleIDs: Set<String> {
        var ids = HangCandidateFilter.ownBundleIDs
        if let main = Bundle.main.bundleIdentifier {
            ids.insert(main)
        }
        return ids
    }
}

// MARK: - 内部数据结构

/// 枚举应用时用的中间结构。
private struct RunningApp {
    let pid: pid_t
    let bundleID: String
    let appName: String
    let bundlePath: String?
    let isForeground: Bool

    var candidate: HangCandidate {
        HangCandidate(
            pid: pid,
            bundleID: bundleID,
            appName: appName,
            bundlePath: bundlePath,
            isForeground: isForeground,
            isRegularActivationPolicy: true
        )
    }
}

// MARK: - 系统判定（WindowServer）

/// 「这个应用是不是未响应」—— 直接问系统，不问应用。
///
/// 用的是 Activity Monitor 与「强制退出」窗口背后同一个判据：
/// WindowServer 给每个 GUI 连接维护着一个「是否响应」状态，
/// 它自己的 ping 超时之后就把应用标成 unresponsive。
///
/// 三个符号都不是公开 API，用 dlsym 从全局命名空间取：
///
///   - `_CGSDefaultConnection()`              当前图形连接
///   - `GetProcessForPID(pid, &psn)`          把 pid 换成 ProcessSerialNumber
///   - `CGSEventIsAppUnresponsive(cid, &psn)` 真正的判据
///
/// 实测（本机 macOS 27.2）：
///
/// | 场景 | 结果 |
/// | --- | --- |
/// | Telegram / 微信 / QQ / Safari / 访达 等 13 个正常应用 | 全部「正常」 |
/// | TextEdit 被 SIGSTOP 卡住 | 约 15 秒后转为「未响应」 |
/// | 恢复之后 | 半秒内转回「正常」 |
///
/// 那 15 秒是 WindowServer 自己的 ping 周期，不是这里加的延时 ——
/// 刚卡住的十几秒里系统自己也还认为它正常，我们跟系统保持一致。
///
/// **符号取不到时整块停用**（未来系统版本可能移除）。这时如实告诉用户
/// 「系统判定接口不可用」，绝不退回猜的判据 —— 拿辅助功能去问应用，
/// 正是当初把 Telegram 误报成未响应的来路。
enum WindowServerResponsiveness {

    private typealias DefaultConnectionFn = @convention(c) () -> Int32
    private typealias IsAppUnresponsiveFn = @convention(c) (Int32, UnsafePointer<ProcessSerialNumber>) -> Bool
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    /// 三个符号都取到了才算可用。
    static let isAvailable: Bool = {
        defaultConnection != nil && askUnresponsive != nil && convertPID != nil
    }()

    private static let defaultConnection: DefaultConnectionFn? = load("_CGSDefaultConnection")
    private static let askUnresponsive: IsAppUnresponsiveFn? = load("CGSEventIsAppUnresponsive")
    /// `GetProcessForPID` 在 Swift 里被标成 unavailable（10.9 起废弃），
    /// 符号本身还在 —— 用 dlsym 绕开编译期的可用性检查。
    private static let convertPID: GetProcessForPIDFn? = load("GetProcessForPID")

    private static func load<T>(_ name: String) -> T? {
        // RTLD_DEFAULT 在 Swift 里没有常量，用 -2 这个约定值。
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    /// 问 WindowServer 一次。返回 nil 表示问不出结果。
    static func isUnresponsive(pid: pid_t) -> Bool? {
        guard let connection = defaultConnection?(),
              let ask = askUnresponsive,
              let convert = convertPID else { return nil }
        var serial = ProcessSerialNumber()
        guard convert(pid, &serial) == noErr else { return nil }
        return ask(connection, &serial)
    }

    /// 批量问一遍。纯 C 调用，微秒级。
    static func snapshot(pids: [pid_t]) -> [pid_t: Bool] {
        var result: [pid_t: Bool] = [:]
        for pid in pids {
            if let verdict = isUnresponsive(pid: pid) { result[pid] = verdict }
        }
        return result
    }
}
