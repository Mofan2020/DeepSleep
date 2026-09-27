//
//  AutomationEngine.swift
//  Deep Sleep
//
//  自动化规则求值引擎。
//
//  每 5 秒重新评估全部规则，把「当前应当保持的 assertion 集合」算出来，
//  通过回调交给 SleepController 去实际申请/释放。
//  规则只负责表达意图，不直接碰 IOKit。
//

import Foundation
import AppKit
import IOKit.ps

@MainActor
final class AutomationEngine: ObservableObject {

    /// 全部规则，改动后立即持久化。
    @Published var rules: [AutomationRule] = [] {
        didSet { persist() }
    }

    /// 当前条件成立的规则 id 集合。
    @Published private(set) var satisfiedRuleIDs: Set<UUID> = []

    /// 规则希望持有的 assertion 集合发生变化时回调。
    var onDesiredAssertionsChanged: ((Set<AssertionKind>) -> Void)?

    /// 引擎是否在运行。
    @Published private(set) var isRunning = false

    private var timer: Timer?
    private var lastDesired: Set<AssertionKind> = []
    private let evaluationInterval: TimeInterval = 5
    private let storageKey = "com.skyc8266.deepsleep.automationRules"

    init() {
        load()
    }

    // MARK: - 生命周期

    func start() {
        guard !isRunning else { return }
        isRunning = true
        evaluate()
        let timer = Timer(timeInterval: evaluationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        satisfiedRuleIDs = []
        publishDesired([])
    }

    // MARK: - 求值

    /// 立即求值一次，同时把结果通过回调传出。
    func evaluate() {
        guard isRunning else { return }
        var satisfied: Set<UUID> = []
        var desired: Set<AssertionKind> = []

        for rule in rules where rule.isEnabled {
            if isTriggered(rule.trigger) {
                satisfied.insert(rule.id)
                desired.formUnion(rule.assertions)
            }
        }

        if satisfied != satisfiedRuleIDs {
            satisfiedRuleIDs = satisfied
        }
        publishDesired(desired)
    }

    private func publishDesired(_ desired: Set<AssertionKind>) {
        guard desired != lastDesired else { return }
        lastDesired = desired
        onDesiredAssertionsChanged?(desired)
    }

    // MARK: - 触发条件判定

    private func isTriggered(_ trigger: RuleTrigger) -> Bool {
        switch trigger {
        case .timeWindow(let start, let end, let weekdays):
            return Self.isWithinTimeWindow(
                now: Date(),
                startMinutes: start,
                endMinutes: end,
                weekdays: weekdays
            )

        case .powerSource(let onAC):
            return Self.isOnACPower() == onAC

        case .appRunning(let bundleIdentifier, _):
            guard !bundleIdentifier.isEmpty else { return false }
            return NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
            }
        }
    }

    /// 判定当前时间是否落在时间窗口内。支持跨零点（如 22:00–06:00）。
    static func isWithinTimeWindow(
        now: Date,
        startMinutes: Int,
        endMinutes: Int,
        weekdays: Set<Int>,
        calendar: Calendar = .current
    ) -> Bool {
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = components.weekday, let hour = components.hour, let minute = components.minute else {
            return false
        }
        // Calendar 的 weekday 是 1=周日…7=周六，转成 0=周日…6=周六。
        let dayIndex = weekday - 1
        let currentMinutes = hour * 60 + minute

        if startMinutes == endMinutes { return false }

        if startMinutes < endMinutes {
            // 同日区间：需要所在的这一天被选中。
            guard weekdays.isEmpty || weekdays.contains(dayIndex) else { return false }
            return currentMinutes >= startMinutes && currentMinutes < endMinutes
        } else {
            // 跨零点区间：前半段属于「当天」，后半段属于「次日」。
            let previousDay = (dayIndex + 6) % 7
            if currentMinutes >= startMinutes {
                return weekdays.isEmpty || weekdays.contains(dayIndex)
            }
            if currentMinutes < endMinutes {
                return weekdays.isEmpty || weekdays.contains(previousDay)
            }
            return false
        }
    }

    static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = description[kIOPSPowerSourceStateKey] as? String,
               state == kIOPSACPowerValue {
                return true
            }
        }
        return false
    }

    // MARK: - 持久化

    private func persist() {
        do {
            let encodable = rules.filter { $0.trigger.isPersistable }
            let data = try JSONEncoder().encode(encodable)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            NSLog("[DeepSleep] 规则持久化失败：\(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            rules = []
            return
        }
        do {
            rules = try JSONDecoder().decode([AutomationRule].self, from: data)
        } catch {
            NSLog("[DeepSleep] 规则读取失败，已忽略：\(error.localizedDescription)")
            rules = []
        }
    }

    // MARK: - 编辑操作

    func add(_ rule: AutomationRule) {
        rules.append(rule)
    }

    func remove(_ rule: AutomationRule) {
        rules.removeAll { $0.id == rule.id }
        evaluate()
    }

    func update(_ rule: AutomationRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        evaluate()
    }

    func toggleEnabled(_ rule: AutomationRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].isEnabled.toggle()
        evaluate()
    }

    /// 把当前正在运行、且具有 bundle id 的应用列出来，供规则选择。
    static func runningApplications() -> [(bundleIdentifier: String, name: String)] {
        var seen: Set<String> = []
        var result: [(String, String)] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let identifier = app.bundleIdentifier, !identifier.isEmpty else { continue }
            guard app.activationPolicy == .regular else { continue }
            guard !seen.contains(identifier) else { continue }
            seen.insert(identifier)
            result.append((identifier, app.localizedName ?? identifier))
        }
        return result.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}
