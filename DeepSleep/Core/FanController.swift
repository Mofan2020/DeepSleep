//
//  FanController.swift
//  Deep Sleep
//
//  风扇控制引擎：自动 / 固定转速 / 规则调速三种模式，外加 90°C 强制最大转速兜底。
//
//  分层（为了能单测）：
//    - `FanControlPolicy` / `FanEmergencyTracker`：纯逻辑，无 IO、无定时器。
//      线性映射、滞回、节流、紧急状态机全在这里，可以直接喂假时间断言。
//    - `FanController`：外壳。取温度、调助手、续租约、维护发布状态。
//
//  三条硬约束（都来自契约）：
//    1. 90°C 兜底优先级最高，压过任何模式与规则；紧急状态下**拒绝一切降速意图**，
//       温度回落后还要等 `FanControl.emergencyCooldownSeconds`（60 秒）才恢复原模式。
//    2. 未同意免责声明时，**一切写风扇的操作一律拒绝**（不调用助手、不下发）。
//       闸门在 FanController，不靠界面禁用 —— 界面只是"好用的做法"。
//    3. 租约：每次下发的 setFanSpeed 都带 `FanControl.leaseSeconds`，控制循环每拍
//       重发当前期望状态（刷新租约）。应用退出/启动各发一次 releaseFanControl，
//       保证不会留下一个"没人管的手动风扇"。
//
//  防抖：映射出的目标转速与上次实际下发值相差 < 100 RPM 不下发（滞回）；
//  两次下发之间至少隔 10 秒（节流）。写 SMC 走 socket，很贵。
//

import Foundation
import Combine

// MARK: - 模式

/// 单个风扇的工作模式。
enum FanMode: Codable, Equatable {
    /// 交给系统（写 F<n>Md = 0）
    case automatic
    /// 固定转速
    case fixed(rpm: Int)
    /// 按温度线性调速：作用在 `targetFan` 上，温度区间 [minTempC, maxTempC]
    /// 线性映射到该风扇的 [minRPM, maxRPM]。
    case rule(targetFan: Int, minTempC: Double, maxTempC: Double)

    /// 界面显示名。
    var displayName: String {
        switch self {
        case .automatic:      return "交给系统"
        case .fixed(let rpm): return "固定 \(rpm) RPM"
        case .rule(let fan, let lo, let hi):
            return String(format: "规则：风扇 %d，%.0f–%.0f°C", fan, lo, hi)
        }
    }
}

/// 写风扇失败的原因。UI 直接拿 `errorDescription` 显示。
enum FanControlError: LocalizedError, Equatable {
    /// 未同意免责声明。
    case disclaimerNotAccepted
    /// 紧急兜底生效中，拒绝降速。
    case emergencyActive
    /// 助手不可用 / 未安装。
    case helperUnavailable(String)
    /// 助手不认识风扇命令（旧助手），静默降级即可。
    case unsupportedHelper
    /// 风扇序号不存在，或该风扇的转速区间不可用（SMC 没给出有效 min/max）。
    case fanNotWritable(Int)

    var errorDescription: String? {
        switch self {
        case .disclaimerNotAccepted:
            return "需先同意风扇控制免责声明"
        case .emergencyActive:
            return "温度已达 90°C，强制最大转速生效中，已拒绝降速"
        case .helperUnavailable(let detail):
            return "特权助手不可用：\(detail)"
        case .unsupportedHelper:
            return "助手版本不支持风扇控制，需要更新助手"
        case .fanNotWritable(let index):
            return "风扇 \(index) 当前不可写（读数或转速区间无效）"
        }
    }
}

// MARK: - 纯逻辑：映射与节流

/// 风扇控制的纯策略。所有判定都是纯函数，方便单测。
enum FanControlPolicy {

    /// 滞回阈值（RPM）：目标与上次下发值相差不到这么多就不下发，
    /// 避免温度在映射结果附近小幅波动时风扇转速来回抖、SMC 被高频写。
    static let hysteresisRPM = 100

    /// 同一风扇两次下发的最小间隔（秒）。写 SMC 走 socket，很贵。
    static let minDispatchInterval: TimeInterval = 10

    /// 租约刷新间隔（秒）。必须**小于** `FanControl.leaseSeconds`（15），
    /// 否则租约会在下一次下发之前到期，助手把风扇交回系统。
    static let leaseRefreshInterval: TimeInterval = 10

    /// 控制循环周期（秒）。与助手心跳同拍。
    static let tickInterval: TimeInterval = TimeInterval(FanControl.heartbeatSeconds)

    /// 温度 → 目标转速的线性映射。
    ///
    /// - 温度 ≤ minTempC → minRPM
    /// - 温度 ≥ maxTempC → maxRPM
    /// - 中间线性插值并四舍五入
    ///
    /// 异常输入（`maxTempC <= minTempC`、`minRPM >= maxRPM`）一律夹到
    /// 安全结果：区间无从判断时按「最热」处理，给 maxRPM —— 宁可吵，
    /// 不可让一台已经热的机器停在低转速。
    static func mappedRPM(temperature: Double,
                           minTempC: Double,
                           maxTempC: Double,
                           minRPM: Int,
                           maxRPM: Int) -> Int {
        let lowRPM = max(0, minRPM)
        let highRPM = max(lowRPM, maxRPM)

        // 温度区间无效：没有可用的映射依据，按最热处理。
        guard maxTempC > minTempC else { return highRPM }
        // 风扇区间无效（min >= max）：也只能给上限。
        guard highRPM > lowRPM else { return highRPM }

        if temperature <= minTempC { return lowRPM }
        if temperature >= maxTempC { return highRPM }

        let ratio = (temperature - minTempC) / (maxTempC - minTempC)
        let raw = Double(lowRPM) + ratio * Double(highRPM - lowRPM)
        return min(highRPM, max(lowRPM, Int(raw.rounded())))
    }

    /// 写入前的夹取：不低于该风扇的 minRPM（SMC 会拒绝低于 F0Mn 的目标值），
    /// 不高于 maxRPM。`FanControl.minRpmSafetyRatio` 只用于表达「不要踩在
    /// 最低边界上」的意图 —— 它算出来仍低于 minRPM，所以实际下限就是 minRPM。
    static func clampForWrite(_ rpm: Int, minRPM: Int, maxRPM: Int) -> Int {
        let floor = max(minRPM, Int(Double(minRPM) * FanControl.minRpmSafetyRatio))
        let ceiling = max(floor, maxRPM)
        return min(ceiling, max(floor, rpm))
    }

    /// 下发决策的结果。
    enum DispatchAction: Equatable {
        /// 把 `rpm` 下发给该风扇。
        case write(rpm: Int, reason: DispatchReason)
        /// 本拍不下发。
        case skip(reason: DispatchReason)

        var isWrite: Bool {
            if case .write = self { return true }
            return false
        }

        var reason: DispatchReason {
            switch self {
            case .write(_, let reason): return reason
            case .skip(let reason):     return reason
            }
        }
    }

    enum DispatchReason: String, Equatable {
        /// 该风扇还从没被写过。
        case firstWrite
        /// 目标转速变化超过滞回阈值。
        case targetChanged
        /// 目标没变，只是到点刷新租约（重发同一个值）。
        case leaseRefresh
        /// 紧急兜底：无视滞回与节流，立刻写。
        case emergencyOverride
        /// 距上次下发不足最小间隔。
        case throttled
        /// 目标没变且租约还新鲜。
        case unchanged
    }

    /// 决定这一拍要不要给某个风扇下发、下发什么值。
    ///
    /// - Parameters:
    ///   - target: 本拍算出的目标转速（紧急态时是 maxRPM）。
    ///   - lastWrittenRPM: 上次实际下发的值（nil = 从未下发）。
    ///   - lastWrittenAt: 上次下发时刻。
    ///   - emergency: 紧急兜底是否生效。生效时目标变化**绕过节流与滞回**。
    ///   - refreshLease: 目标不变时是否按租约间隔重发（自动模式不需要）。
    static func decide(target: Int,
                       lastWrittenRPM: Int?,
                       lastWrittenAt: Date?,
                       now: Date,
                       emergency: Bool,
                       refreshLease: Bool = true,
                       hysteresis: Int = FanControlPolicy.hysteresisRPM,
                       minInterval: TimeInterval = FanControlPolicy.minDispatchInterval,
                       leaseRefreshInterval: TimeInterval = FanControlPolicy.leaseRefreshInterval)
        -> DispatchAction {

        // 紧急兜底：目标只要和上次不同，立刻写，不看节流。
        if emergency, lastWrittenRPM != target {
            return .write(rpm: target, reason: .emergencyOverride)
        }

        guard let lastRPM = lastWrittenRPM, let lastAt = lastWrittenAt else {
            return .write(rpm: target, reason: .firstWrite)
        }

        let elapsed = now.timeIntervalSince(lastAt)
        guard elapsed >= minInterval else {
            return .skip(reason: .throttled)
        }

        if abs(target - lastRPM) >= hysteresis {
            return .write(rpm: target, reason: .targetChanged)
        }

        if refreshLease, elapsed >= leaseRefreshInterval {
            // 重发**上次的值**，不是新目标 —— 小幅波动不该真的改变转速，
            // 这里只是为了不让租约过期。
            return .write(rpm: lastRPM, reason: .leaseRefresh)
        }

        return .skip(reason: .unchanged)
    }
}

// MARK: - 纯逻辑：紧急兜底状态机

/// 90°C 兜底状态机的状态迁移结果。
enum FanEmergencyTransition: Equatable {
    /// 没变化。
    case none
    /// 本拍触发了兜底。
    case triggered
    /// 本拍解除了兜底（温度回落且冷却已满）。
    case released
}

/// 90°C 兜底状态机。
///
/// 触发：任一传感器 >= `FanControl.emergencyTemperatureCelsius`。
/// 解除：温度回落到阈值以下后，**再保持** `FanControl.emergencyCooldownSeconds`
/// （60 秒）才解除 —— 避免温度在阈值附近抖动导致风扇反复冲高又回落。
struct FanEmergencyTracker: Equatable {

    private(set) var isActive = false
    /// 本次兜底的触发时刻。
    private(set) var triggeredAt: Date?
    /// 本次兜底期间见过的最高温。
    private(set) var peakCelsius: Double?
    /// 温度首次回落到阈值以下的时刻（冷却计时起点）。
    private(set) var cooledSince: Date?

    /// 喂一拍照温。
    ///
    /// - Parameter hottest: 全部传感器里的最高读数；nil 表示这一拍读不到温度。
    ///   读不到时**不改状态** —— 「不知道」既不能触发也不能解除，
    ///   已经在兜底的就继续兜着（安全侧）。
    mutating func update(hottest: Double?, now: Date) -> FanEmergencyTransition {
        guard let hottest else { return .none }

        if hottest >= FanControl.emergencyTemperatureCelsius {
            peakCelsius = max(peakCelsius ?? hottest, hottest)
            cooledSince = nil
            guard !isActive else { return .none }
            isActive = true
            triggeredAt = now
            return .triggered
        }

        // 已经低于阈值。没在兜底就什么都不用做。
        guard isActive else { return .none }

        // 冷却从「第一次回落到阈值以下」开始算，之后持续低于阈值就一直等着。
        let cooled = cooledSince ?? now
        cooledSince = cooled
        guard now.timeIntervalSince(cooled) >= FanControl.emergencyCooldownSeconds else {
            return .none
        }

        isActive = false
        triggeredAt = nil
        cooledSince = nil
        return .released
    }

    /// 强制清空（停止控制时用）。
    mutating func reset() {
        isActive = false
        triggeredAt = nil
        peakCelsius = nil
        cooledSince = nil
    }
}

// MARK: - 兜底记录

/// 一次兜底事件（UI 用来列「触发过几次、什么时候、当时多热」）。
struct FanEmergencyEvent: Identifiable, Equatable {
    let id = UUID()
    let triggeredAt: Date
    /// 触发时（以及兜底期间）看到的最高温。
    let peakCelsius: Double
    var releasedAt: Date?

    var isOngoing: Bool { releasedAt == nil }
}

// MARK: - 引擎

/// 风扇控制引擎。界面只跟它打交道，不直接发助手命令。
@MainActor
final class FanController: ObservableObject {

    static let shared = FanController()

    // MARK: 对外状态

    /// 当前各风扇状态（来自 getFanState）。读不到时为空。
    @Published private(set) var fans: [FanState.Fan] = []
    /// 每个风扇的当前模式。键是风扇序号。
    @Published private(set) var modes: [Int: FanMode] = [:]
    /// 90°C 兜底是否生效（UI 必须可见，不能静默）。
    @Published private(set) var isEmergencyActive = false
    /// 兜底事件历史（新的在前）。
    @Published private(set) var emergencyEvents: [FanEmergencyEvent] = []
    /// 风扇控制总开关。关闭时会把风扇交回系统。
    @Published private(set) var isEnabled = false
    /// 最近一次错误（界面横幅用）。成功后清空。
    @Published private(set) var lastError: String?
    /// 免责声明是否已同意（镜像 FanDisclaimer，方便 SwiftUI 观察）。
    @Published private(set) var isDisclaimerAccepted = FanDisclaimer.isAccepted

    /// 日志出口。MonitoringCoordinator 会接到 SleepController.appendLog 上；
    /// 没接的时候退化成 NSLog，不会丢日志。
    var onLog: ((String, Bool) -> Void)?

    /// 兜底触发回调。MonitoringCoordinator 接到 SystemNotifier 上发告警通知。
    var onEmergencyTriggered: ((FanEmergencyEvent) -> Void)?

    // MARK: 内部状态

    private let queue = DispatchQueue(label: "com.skyc8266.deepsleep.fancontrol")
    private var timer: DispatchSourceTimer?
    private var emergencyTracker = FanEmergencyTracker()
    /// 上次真正下发的值 / 时刻，按风扇序号记。滞回与节流都靠它。
    private var lastWrittenRPM: [Int: Int] = [:]
    private var lastWrittenAt: [Int: Date] = [:]
    /// 温度来源。默认读 ThermalMonitor；测试或上层可替换。
    var temperatureProvider: () -> TemperatureSnapshot? = { ThermalMonitor.shared.currentSnapshot }
    /// 助手不可用时只记一次日志，不刷屏。
    private var didLogHelperUnavailable = false
    /// 助手不认识风扇命令（旧助手）→ 静默降级并停掉控制循环。
    private var helperLacksFanCommands = false

    private init() {}

    // MARK: - 免责声明

    /// 用户是否已同意当前版本的免责声明。
    static func hasAcceptedDisclaimer() -> Bool {
        FanDisclaimer.isAccepted
    }

    /// 落盘「已同意」，并把状态同步给助手（助手侧也要有自己的门禁）。
    static func acceptDisclaimer() {
        FanDisclaimer.accept()
        Task { @MainActor in
            FanController.shared.isDisclaimerAccepted = true
            await FanController.shared.syncDisclaimerToHelper()
            FanController.shared.log("已同意风扇控制免责声明", isError: false)
        }
    }

    /// 把当前同意状态同步给助手（`setFanDisclaimerAccepted`）。
    /// 应用启动时与用户点同意后各调一次。
    func syncDisclaimerToHelper() async {
        let accepted = FanDisclaimer.isAccepted
        do {
            _ = try await HelperClient.shared.send(.init(
                command: .setFanDisclaimerAccepted,
                arguments: ["accepted": accepted ? "true" : "false"]
            ), timeout: 5)
        } catch {
            // 旧助手不认识这条命令、或助手没跑 —— 都不是错误：
            // 应用侧门禁仍然生效，只是助手侧没同步到。
            log("免责声明状态未同步到助手：\(error.localizedDescription)", isError: false)
        }
    }

    // MARK: - 生命周期

    /// 启动控制循环。
    ///
    /// 启动顺序有讲究：先 releaseFanControl 清掉上一次可能残留的手动模式，
    /// 再同步免责声明状态，最后才起循环。应用被强杀时助手可能还持有租约，
    /// 不清一次就可能继续按上一次的目标转速跑。
    func start() {
        guard !helperLacksFanCommands else { return }
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        await releaseAllFans(reason: "应用启动清理残留")
        await syncDisclaimerToHelper()
        await refreshFanState()
        startLoop()
    }

    /// 应用退出时调用。SleepController.shutdown 里接一行即可。
    func releaseOnShutdown() async {
        stopLoop()
        await releaseAllFans(reason: "应用退出交回系统")
    }

    private func startLoop() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + FanControlPolicy.tickInterval,
                       repeating: FanControlPolicy.tickInterval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.tick()
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func stopLoop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - 模式设置（界面入口）

    /// 开启 / 关闭风扇控制。
    ///
    /// 关闭时把所有风扇交回系统 —— 这是安全动作，不能只改一个布尔值。
    func setEnabled(_ enabled: Bool) async {
        if enabled {
            guard FanDisclaimer.isAccepted else {
                lastError = FanControlError.disclaimerNotAccepted.errorDescription
                log("未同意免责声明，风扇控制保持关闭", isError: true)
                return
            }
            isEnabled = true
            await syncDisclaimerToHelper()
            await refreshFanState()
            startLoop()
            log("风扇控制已开启", isError: false)
        } else {
            isEnabled = false
            stopLoop()
            await releaseAllFans(reason: "用户关闭风扇控制")
            log(FanDisclaimer.handoverNotice, isError: false)
        }
    }

    /// 设置某个风扇的模式。
    ///
    /// 未同意免责声明 / 紧急兜底生效中 → 直接拒绝，不调用助手。
    @discardableResult
    func setMode(_ mode: FanMode, for fanIndex: Int) async -> Result<Void, FanControlError> {
        guard FanDisclaimer.isAccepted else {
            let error = FanControlError.disclaimerNotAccepted
            lastError = error.errorDescription
            return .failure(error)
        }
        // 紧急状态下拒绝一切降速意图（交回系统 / 规则调速 / 更低转速）。
        guard !emergencyTracker.isActive else {
            let error = FanControlError.emergencyActive
            lastError = error.errorDescription
            log("兜底生效中，拒绝设置风扇 \(fanIndex) 为 \(mode.displayName)", isError: true)
            return .failure(error)
        }
        guard let fan = writableFan(at: fanIndex) else {
            let error = FanControlError.fanNotWritable(fanIndex)
            lastError = error.errorDescription
            return .failure(error)
        }

        // 固定转速先夹进合法区间，避免界面传上来一个 SMC 会拒绝的值。
        var effective = mode
        if case .fixed(let rpm) = mode {
            effective = .fixed(rpm: FanControlPolicy.clampForWrite(
                rpm, minRPM: fan.minRPM, maxRPM: fan.maxRPM))
        }

        modes[fanIndex] = effective
        lastError = nil
        log("风扇 \(fanIndex) 模式 → \(effective.displayName)", isError: false)

        // 立刻下发一次，不等下一拍（用户点了按钮就该有反应）。
        await applyMode(fanIndex: fanIndex, mode: effective, fan: fan,
                        emergency: false, force: true)
        return .success(())
    }

    /// 「交给系统」的便捷入口（= 设置为 .automatic）。
    @discardableResult
    func handOverToSystem(fanIndex: Int) async -> Result<Void, FanControlError> {
        await setMode(.automatic, for: fanIndex)
    }

    /// 重新读一次风扇状态（界面刷新 / 切页时调）。
    func refreshFanState() async {
        do {
            let response = try await HelperClient.shared.send(
                .init(command: .getFanState), timeout: 5)
            guard response.success else {
                if Self.isUnknownCommand(response.message) {
                    helperLacksFanCommands = true
                    log("助手不支持风扇命令（旧版本），风扇控制静默降级", isError: false)
                } else {
                    log("读取风扇状态失败：\(response.message)", isError: true)
                }
                return
            }
            let state = FanState.decode(response.payload)
            fans = state.fans
            didLogHelperUnavailable = false
            helperLacksFanCommands = false
            // 新出现 / 消失的风扇：把模式表对齐，避免留下无效键。
            let alive = Set(state.fans.map(\.index))
            modes = modes.filter { alive.contains($0.key) }
        } catch {
            logHelperUnavailable(error, context: "读取风扇状态")
        }
    }

    // MARK: - 控制循环

    private func tick() async {
        guard isEnabled, FanDisclaimer.isAccepted else { return }
        guard !helperLacksFanCommands else { return }

        // 1) 温度 → 兜底状态机（必须在所有模式判断之前）
        let snapshot = temperatureProvider()
        let hottest = snapshot?.readings.map(\.celsius).max()
        let now = Date()
        let transition = emergencyTracker.update(hottest: hottest, now: now)

        switch transition {
        case .triggered:
            isEmergencyActive = true
            let event = FanEmergencyEvent(
                triggeredAt: now,
                peakCelsius: hottest ?? FanControl.emergencyTemperatureCelsius)
            emergencyEvents.insert(event, at: 0)
            if emergencyEvents.count > 50 { emergencyEvents.removeLast(emergencyEvents.count - 50) }
            log(String(format: "温度 %.1f°C ≥ %.0f°C，强制所有风扇最大转速",
                       hottest ?? 0, FanControl.emergencyTemperatureCelsius), isError: true)
            onEmergencyTriggered?(event)
        case .released:
            isEmergencyActive = false
            if let index = emergencyEvents.firstIndex(where: { $0.isOngoing }) {
                emergencyEvents[index].releasedAt = now
            }
            log("温度回落且冷却期满，恢复原风扇模式", isError: false)
        case .none:
            break
        }

        // 2) 状态可能过期（插拔扩展坞、机器唤醒），定期刷新一次风扇读数。
        if fans.isEmpty || now.timeIntervalSince(lastWrittenAt.values.max() ?? .distantPast) > 30 {
            await refreshFanState()
        }
        guard !fans.isEmpty else { return }

        // 3) 逐风扇算目标并下发
        let emergency = emergencyTracker.isActive
        for fan in fans {
            let mode = modes[fan.index] ?? .automatic
            await applyMode(fanIndex: fan.index, mode: mode, fan: fan,
                            emergency: emergency, force: false)
        }
    }

    /// 把某个风扇的当前模式落实成一次下发（或决定不写）。
    private func applyMode(fanIndex: Int,
                           mode: FanMode,
                           fan: FanState.Fan,
                           emergency: Bool,
                           force: Bool) async {
        let now = Date()
        var refreshLease = true
        var target: Int

        if emergency {
            // 兜底压过一切：所有可写风扇拉满，保持手动。
            target = fan.maxRPM
        } else {
            switch mode {
            case .automatic:
                // 交回系统：rpm = 0，不续租约（没有租约可续）。
                target = 0
                refreshLease = false
            case .fixed(let rpm):
                target = FanControlPolicy.clampForWrite(
                    rpm, minRPM: fan.minRPM, maxRPM: fan.maxRPM)
            case .rule(let targetFan, let minTemp, let maxTemp):
                guard targetFan == fanIndex else {
                    // 规则写的是别的风扇 —— 这个风扇不该由这条规则驱动。
                    return
                }
                guard let hottest = temperatureProvider()?.readings.map(\.celsius).max() else {
                    // 温度读不到时不动这个风扇：拿 0 去映射会让它掉到最低转速。
                    return
                }
                target = FanControlPolicy.clampForWrite(
                    FanControlPolicy.mappedRPM(
                        temperature: hottest,
                        minTempC: minTemp,
                        maxTempC: maxTemp,
                        minRPM: fan.minRPM,
                        maxRPM: fan.maxRPM),
                    minRPM: fan.minRPM,
                    maxRPM: fan.maxRPM)
            }
        }

        let decision: FanControlPolicy.DispatchAction
        if force {
            decision = .write(rpm: target, reason: .targetChanged)
        } else {
            decision = FanControlPolicy.decide(
                target: target,
                lastWrittenRPM: lastWrittenRPM[fanIndex],
                lastWrittenAt: lastWrittenAt[fanIndex],
                now: now,
                emergency: emergency,
                refreshLease: refreshLease)
        }

        switch decision {
        case .skip:
            return
        case .write(let rpm, let reason):
            do {
                try await sendFanSpeed(fanIndex: fanIndex, rpm: rpm, reason: reason)
                lastWrittenRPM[fanIndex] = rpm
                lastWrittenAt[fanIndex] = now
                lastError = nil
                if reason == .emergencyOverride {
                    log("风扇 \(fanIndex) 强制最大转速 \(rpm) RPM", isError: true)
                }
            } catch let error as FanControlError {
                if case .unsupportedHelper = error {
                    helperLacksFanCommands = true
                    stopLoop()
                    log("助手不支持风扇命令（旧版本），风扇控制静默降级", isError: false)
                } else {
                    lastError = error.errorDescription
                    log("风扇 \(fanIndex) 写入失败：\(error.localizedDescription)", isError: true)
                }
            } catch {
                logHelperUnavailable(error, context: "写风扇 \(fanIndex)")
            }
        }
    }

    // MARK: - 助手交互

    private func sendFanSpeed(fanIndex: Int, rpm: Int, reason: FanControlPolicy.DispatchReason) async throws {
        // 双重闸门：即便上层漏判，这里也不会在未同意时下发。
        guard FanDisclaimer.isAccepted else {
            throw FanControlError.disclaimerNotAccepted
        }

        let request = HelperRequest(command: .setFanSpeed, arguments: [
            "fan": "\(fanIndex)",
            "rpm": "\(rpm)",
            "lease": "\(FanControl.leaseSeconds)",
            "reason": reason.rawValue,
        ])
        let response = try await HelperClient.shared.send(request, timeout: 5)
        guard response.success else {
            if Self.isUnknownCommand(response.message) {
                throw FanControlError.unsupportedHelper
            }
            throw FanControlError.helperUnavailable(response.message)
        }
    }

    /// 所有风扇交回系统自动控制。
    private func releaseAllFans(reason: String) async {
        // 未同意免责声明时连 release 也不发：助手侧同样会拒绝，
        // 发了只会让日志里多一条必然失败的命令。
        guard FanDisclaimer.isAccepted else { return }
        do {
            let response = try await HelperClient.shared.send(
                .init(command: .releaseFanControl, arguments: ["reason": reason]), timeout: 5)
            lastWrittenRPM.removeAll()
            lastWrittenAt.removeAll()
            if response.success {
                log("已交回风扇控制权（\(reason)）", isError: false)
            } else {
                log("交回风扇控制权失败：\(response.message)", isError: true)
            }
        } catch {
            lastWrittenRPM.removeAll()
            lastWrittenAt.removeAll()
            logHelperUnavailable(error, context: "交回风扇控制权")
        }
    }

    /// 取一个可写风扇（minRPM / maxRPM 都有效）。
    private func writableFan(at index: Int) -> FanState.Fan? {
        guard let fan = fans.first(where: { $0.index == index }) else { return nil }
        guard fan.minRPM > 0, fan.maxRPM > fan.minRPM else { return nil }
        return fan
    }

    private static func isUnknownCommand(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("unknown command")
    }

    // MARK: - 日志

    private func logHelperUnavailable(_ error: Error, context: String) {
        if didLogHelperUnavailable { return }
        didLogHelperUnavailable = true
        log("\(context)失败（助手不可用）：\(error.localizedDescription)", isError: false)
    }

    private func log(_ text: String, isError: Bool) {
        if let onLog {
            onLog(text, isError)
        } else {
            NSLog("[DeepSleep] %@", text)
        }
    }
}
