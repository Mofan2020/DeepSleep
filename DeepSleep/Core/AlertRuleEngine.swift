//
//  AlertRuleEngine.swift
//  Deep Sleep
//
//  自定义告警规则的求值引擎。
//
//  分两层：
//    - `AlertRuleEvaluator`：纯逻辑。输入「规则 + 一次指标快照 + 当前时刻」，
//      输出「该报哪几条」。不碰定时器、不碰 UserDefaults、不碰 UI，
//      所以能拿假时间与假指标直接跑断言。
//    - `AlertRuleEngine`：外壳。5 秒一拍取指标、调求值器、把触发结果交给
//      MonitoringCoordinator 发通知/邮件；规则列表的增删改与持久化也在这里。
//
//  判定语义（与 SystemMonitor 的既有做法一致）：
//    - 条件必须**连续成立 durationSeconds 秒**才报，不是瞬间触发；
//    - 同一规则 5 分钟内不重复告警；
//    - 告警后重新计时（和 SystemMonitor 的 overloadStartedAt = nil 一致）：
//      要再报一次，得重新满足一个完整的持续时间。
//
//  动作只有 notification / email / both。**刻意没有「冻结 / 结束进程」** ——
//  温度与内存类阈值下杀进程会误伤，与项目既有立场一致。
//

import Foundation
import Combine

// MARK: - 指标快照

/// 一次求值用到的指标快照。取不到的指标为 nil（不参与判定，不是 0）。
struct AlertMetrics: Equatable {
    var cpuPercent: Double?
    var ramPercent: Double?
    var singleProcessRAMGB: Double?
    var cpuTemperature: Double?
    var diskUsagePercent: Double?

    init(cpuPercent: Double? = nil,
         ramPercent: Double? = nil,
         singleProcessRAMGB: Double? = nil,
         cpuTemperature: Double? = nil,
         diskUsagePercent: Double? = nil) {
        self.cpuPercent = cpuPercent
        self.ramPercent = ramPercent
        self.singleProcessRAMGB = singleProcessRAMGB
        self.cpuTemperature = cpuTemperature
        self.diskUsagePercent = diskUsagePercent
    }

    static let empty = AlertMetrics()

    /// 取某个指标的值。取不到返回 nil。
    func value(for metric: AlertMetric) -> Double? {
        switch metric {
        case .cpuPercent:         return cpuPercent
        case .ramPercent:         return ramPercent
        case .singleProcessRAMGB: return singleProcessRAMGB
        case .cpuTemperature:     return cpuTemperature
        case .diskUsagePercent:   return diskUsagePercent
        }
    }

    /// 是否一个指标都没有（全 nil 时求值器直接跳过，不产生告警）。
    var isEmpty: Bool {
        cpuPercent == nil && ramPercent == nil && singleProcessRAMGB == nil
            && cpuTemperature == nil && diskUsagePercent == nil
    }
}

// MARK: - 触发结果

/// 一条规则的触发结果。
struct AlertTrigger: Equatable {
    let rule: AlertRule
    /// 触发时观测到的指标值。
    let observedValue: Double
    let timestamp: Date
}

// MARK: - 纯逻辑求值器

/// 纯逻辑求值器：无 IO、无定时器、无 UI。
///
/// 每次 tick 调一次 `evaluate`，把返回的触发结果交给上层派发。
/// 内部只维护两份状态：每条规则的「条件开始成立的时刻」与「上次告警时刻」。
struct AlertRuleEvaluator {

    /// 同一规则的告警冷却（秒）。沿用项目既有的 5 分钟。
    var cooldownSeconds: TimeInterval = 300

    /// 规则 id → 条件开始连续成立的时刻。
    private var breachStartedAt: [UUID: Date] = [:]
    /// 规则 id → 上次告警时刻。
    private var lastFiredAt: [UUID: Date] = [:]

    /// 当前有多少条规则正处于「条件已成立、还在等持续时间」的计时中。
    var pendingCount: Int { breachStartedAt.count }

    /// 求值一次。
    ///
    /// - Parameters:
    ///   - rules: 全部规则（内部按 `isEnabled` 过滤）。
    ///   - metrics: 当前指标快照。
    ///   - now: 当前时刻（测试可传假时间）。
    /// - Returns: 本次应当触发的告警（可能为空）。
    mutating func evaluate(rules: [AlertRule],
                           metrics: AlertMetrics,
                           now: Date) -> [AlertTrigger] {
        var triggers: [AlertTrigger] = []

        // 已删除的规则不该继续占着计时表。
        let aliveIDs = Set(rules.map(\.id))
        breachStartedAt = breachStartedAt.filter { aliveIDs.contains($0.key) }
        lastFiredAt = lastFiredAt.filter { aliveIDs.contains($0.key) }

        for rule in rules where rule.isEnabled {
            guard let value = metrics.value(for: rule.metric) else {
                // 指标取不到 = 「不知道」，既不是「没超阈」也不是「超了」。
                // 清掉计时，避免指标恢复后拿着一段陈旧的时间立刻误报。
                breachStartedAt[rule.id] = nil
                continue
            }

            let matched = rule.operator.matches(value: value, threshold: rule.threshold)
            guard matched else {
                breachStartedAt[rule.id] = nil
                continue
            }

            // 条件成立：第一次见到就记时刻；之后按时间差判持续时间。
            let startedAt = breachStartedAt[rule.id] ?? now
            breachStartedAt[rule.id] = startedAt

            let sustained = now.timeIntervalSince(startedAt)
            guard sustained >= TimeInterval(max(0, rule.durationSeconds)) else {
                continue
            }

            if let last = lastFiredAt[rule.id], now.timeIntervalSince(last) < cooldownSeconds {
                continue
            }

            lastFiredAt[rule.id] = now
            // 与 SystemMonitor 一致：报完重新计时，再报要重新满足完整持续时间。
            breachStartedAt[rule.id] = nil
            triggers.append(AlertTrigger(rule: rule, observedValue: value, timestamp: now))
        }

        return triggers
    }

    /// 清空全部计时与冷却状态（停止引擎 / 规则全集被替换时用）。
    mutating func reset() {
        breachStartedAt.removeAll()
        lastFiredAt.removeAll()
    }
}

// MARK: - 引擎外壳

/// 告警规则引擎：定时取指标、求值、派发触发。
///
/// 与 `AutomationEngine` 一样跑在主 RunLoop 的 5 秒 Timer 上：
/// 求值本身是几十条规则的数值比较，成本可以忽略；放主线程省掉一整套
/// 跨线程同步，也让 `@Published` 的规则列表能直接给界面绑定。
///
/// 指标从 `metricsProvider` 拿（由 MonitoringCoordinator 接到 SystemMonitor /
/// ThermalMonitor / DiskUsage 上）。引擎自己不直接依赖那三个，方便单测与替换。
@MainActor
final class AlertRuleEngine: ObservableObject {

    static let shared = AlertRuleEngine()

    /// 求值周期（秒）。取 5 秒：
    ///   - 规则的持续时间是秒级，5 秒的判别精度够用；
    ///   - 与 AutomationEngine 的 5 秒求值周期同拍，不额外抢 CPU。
    static let tickIntervalSeconds: TimeInterval = 5

    /// 全部规则。改动后立即持久化（`AlertRuleStore`，键 `alertRules.v1`）。
    @Published private(set) var rules: [AlertRule] = [] {
        didSet { AlertRuleStore.save(rules) }
    }

    /// 指标提供者。返回 nil 表示「这一拍拿不到指标」，本次求值跳过。
    var metricsProvider: (() -> AlertMetrics?)?

    /// 触发回调（主线程）。
    var onTrigger: ((AlertTrigger) -> Void)?

    /// 附加的触发观察者。
    ///
    /// 为什么需要它：`onTrigger` 只有一个，而触发事件有两个消费者 ——
    /// 监控协调器用它派发系统通知与邮件，告警规则页用它记录「最近的触发」。
    /// 单个闭包会被后设置的那个覆盖掉，通知就发不出去了。
    /// 所以主要消费者继续用 `onTrigger`，只读观察者走这个列表。
    private var triggerObservers: [(token: UUID, observer: (AlertTrigger) -> Void)] = []

    /// 注册一个触发观察者。返回的令牌可用于移除。
    @discardableResult
    func addTriggerObserver(_ observer: @escaping (AlertTrigger) -> Void) -> UUID {
        let token = UUID()
        triggerObservers.append((token: token, observer: observer))
        return token
    }

    /// 移除指定的观察者。
    func removeTriggerObserver(_ token: UUID) {
        triggerObservers.removeAll { $0.token == token }
    }

    private var evaluator = AlertRuleEvaluator()
    private var timer: Timer?

    private init() {
        rules = AlertRuleStore.load()
    }

    // MARK: - 规则增删改

    func setRules(_ newRules: [AlertRule]) {
        // 规则集合一变就清空计时：否则用户改完阈值，旧计时会立刻撞上新条件，
        // 出现「刚保存就告警」的假触发。
        evaluator.reset()
        rules = newRules
    }

    func add(_ rule: AlertRule) {
        setRules(rules + [rule])
    }

    func update(_ rule: AlertRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        var next = rules
        next[index] = rule
        setRules(next)
    }

    func remove(id: UUID) {
        setRules(rules.filter { $0.id != id })
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        var next = rules
        next[index].isEnabled = enabled
        setRules(next)
    }

    // MARK: - 运行

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common：菜单栏菜单打开、窗口拖动时也要继续跑。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        evaluator.reset()
    }

    /// 立即求值一次（不等定时器）。界面的「立即测试」或手动触发可以调它。
    func evaluateNow() {
        tick()
    }

    /// 跑一拍。
    private func tick() {
        guard let metrics = metricsProvider?(), !metrics.isEmpty else { return }
        let triggers = evaluator.evaluate(rules: rules, metrics: metrics, now: Date())
        guard !triggers.isEmpty else { return }
        for trigger in triggers {
            // 观察者先走：它们只记历史，不该影响通知派发。
            for entry in triggerObservers {
                entry.observer(trigger)
            }
            onTrigger?(trigger)
        }
    }
}
