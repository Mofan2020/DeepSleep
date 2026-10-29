//
//  MonitoringCoordinator.swift
//  Deep Sleep
//
//  把 SystemMonitor 的事件接到 AlertWindowController + SystemNotifier。
//
//  这里是「监控 → 用户可见的反应」的唯一翻译层：
//   - onEvent: 弹对话框（保证用户能看到）+ 发通知（不抢焦点时也能看到）
//   - onAction: 通知按钮被点了 → 调用 ProcessStatsProvider 走助手
//

import Foundation
import Combine
import UserNotifications

@MainActor
final class MonitoringCoordinator {

    static let shared = MonitoringCoordinator()

    private init() {}

    /// 单进程内存采样的缓存（GB）。只在有规则用到该指标时才去抓进程快照。
    private var cachedMaxProcessRAMGB: Double?
    private var processRAMSamping: Task<Void, Never>?
    private var rulesObservation: AnyCancellable?

    func wire() {
        SystemMonitor.shared.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
        SystemNotifier.shared.onAction = { [weak self] kind, action, pids in
            Task { @MainActor in
                await self?.handleAction(kind: kind, action: action, pids: pids)
            }
        }
        SystemNotifier.shared.registerCategories()
        SystemNotifier.shared.requestAuthorization()

        wireThermalAndFans()
        wireAlertRules()
    }

    // MARK: - 温度 / 风扇 / 自定义规则接线

    private func wireThermalAndFans() {
        ThermalMonitor.shared.start()

        let fans = FanController.shared
        // 风扇引擎的日志并入应用日志面板，别让它们只躺在 NSLog 里。
        fans.onLog = { text, isError in
            SleepController.shared.appendLog(text, isError: isError)
        }
        // 90°C 兜底是安全事件：复用现有的 CPU 温度通知 + 置顶对话框，
        // 用户不能因为「没在看风扇页」而错过它。
        fans.onEmergencyTriggered = { event in
            let synthetic = CPUTemperatureEvent(
                maxC: event.peakCelsius,
                averageC: nil,
                aggregateC: nil,
                observedMaxC: event.peakCelsius,
                thresholdC: FanControl.emergencyTemperatureCelsius,
                timestamp: event.triggeredAt)
            SystemNotifier.shared.notifyCPUTemperature(synthetic)
            AlertWindowController.shared.presentCPUTemperature(event: synthetic)
            SleepController.shared.appendLog(
                String(format: "风扇已全部强制到最大转速（%.1f°C）", event.peakCelsius),
                isError: true)
        }
        // 风扇控制出问题时也要通知用户 —— 「风扇可能卡在无法控制的状态」
        // 这种事只写日志等于没告诉。
        fans.onFanControlFailure = { failedFans, released in
            SystemNotifier.shared.notifyFanControlFailure(
                fans: failedFans, released: released)
            SleepController.shared.appendLog(
                released
                    ? "风扇 \(failedFans) 连续写不进，已停止修改并交回系统控制"
                    : "风扇 \(failedFans) 连交回系统控制都失败，需要人工检查",
                isError: true)
        }
        // 启动控制循环：内部先清残留 → 同步免责声明 → 起心跳。
        // 注意它**不会**自动开启风扇控制（isEnabled 默认 false），
        // 用户必须在界面里显式打开。
        fans.start()
    }

    private func wireAlertRules() {
        let engine = AlertRuleEngine.shared
        engine.metricsProvider = { [weak self] in
            self?.currentAlertMetrics()
        }
        engine.onTrigger = { [weak self] trigger in
            self?.dispatchAlertRule(trigger)
        }
        engine.start()
        syncProcessRAMSampling()
        // 规则改动后重算「要不要采样单进程内存」。
        rulesObservation = engine.$rules
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncProcessRAMSampling() }
            }
    }

    /// 汇总一次指标快照。取不到的指标是 nil，不是 0。
    private func currentAlertMetrics() -> AlertMetrics {
        let snapshot = SystemMonitor.shared.liveSnapshot()
        let disk = DiskUsage.current()
        let thermal = ThermalMonitor.shared
        return AlertMetrics(
            cpuPercent: snapshot.updatedAt == .distantPast ? nil : snapshot.cpuPercent,
            ramPercent: snapshot.updatedAt == .distantPast ? nil : snapshot.ramPercent,
            singleProcessRAMGB: cachedMaxProcessRAMGB,
            cpuTemperature: thermal.isAvailable ? thermal.hottestCelsius : nil,
            diskUsagePercent: disk.isEmpty ? nil : disk.usedFraction * 100
        )
    }

    /// 有规则用到「单进程内存」时才去抓进程快照，30 秒一次。
    ///
    /// 为什么不复用 SystemMonitor：它只把 Top3（按 CPU 排）暴露出来，
    /// 内存泄漏的进程往往 CPU 不高，按 CPU 排的 Top3 正好会漏掉它。
    private func syncProcessRAMSampling() {
        let needsSampling = AlertRuleEngine.shared.rules.contains {
            $0.isEnabled && $0.metric == .singleProcessRAMGB
        }
        if needsSampling, processRAMSamping == nil {
            processRAMSamping = Task { [weak self] in
                while !Task.isCancelled {
                    guard let stats = try? await ProcessStatsProvider.shared.fetchStats(),
                          !stats.records.isEmpty else {
                        self?.cachedMaxProcessRAMGB = nil
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        continue
                    }
                    let maxRSS = stats.records.map(\.rssBytes).max() ?? 0
                    self?.cachedMaxProcessRAMGB =
                        Double(maxRSS) / 1_073_741_824
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
            }
        } else if !needsSampling {
            processRAMSamping?.cancel()
            processRAMSamping = nil
            cachedMaxProcessRAMGB = nil
        }
    }

    /// 自定义规则触发：按动作发通知 / 邮件。
    private func dispatchAlertRule(_ trigger: AlertTrigger) {
        let rule = trigger.rule
        let value = String(format: "%.1f", trigger.observedValue)
        let message = String(
            format: "规则「%@」触发：%@ %@ %@%@，当前 %@%@",
            rule.name,
            rule.metric.displayName,
            rule.operator.displayName,
            String(format: "%g", rule.threshold),
            rule.metric.unit,
            value,
            rule.metric.unit)

        SleepController.shared.appendLog(message, isError: true)

        if rule.action.wantsNotification {
            postRuleNotification(rule: rule, message: message, trigger: trigger)
        }
        if rule.action.wantsEmail {
            sendRuleEmail(rule: rule, trigger: trigger)
        }
    }

    /// 自定义规则的系统通知。
    ///
    /// 没走 `SystemNotifier`：它是给「过载 / 单进程 / CPU 温度」三类固定事件
    /// 定制的，分类与按钮都绑死在那三条链路上；自定义规则的文字是动态的，
    /// 这里单发一条不带动作按钮的通知更合适（也不该给用户「结束进程」的按钮）。
    private func postRuleNotification(rule: AlertRule, message: String, trigger: AlertTrigger) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ \(rule.name)"
        content.body = message
        content.sound = .default
        content.userInfo = [
            "kind": "alertRule",
            "ruleID": rule.id.uuidString,
        ]
        let request = UNNotificationRequest(
            identifier: "alertRule-\(rule.id.uuidString)-\(Int(trigger.timestamp.timeIntervalSince1970))",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// 自定义规则的邮件。
    ///
    /// 冷却由引擎负责（同一规则 5 分钟一次）；这里仍走 EmailThrottleStore，
    /// 是为「用户连点保存导致规则集合反复变化」这类边角情况兜一层。
    private func sendRuleEmail(rule: AlertRule, trigger: AlertTrigger) {
        let config = MonitorConfig.load()
        guard config.emailAlertEnabled else { return }

        let key = "alertRule-\(rule.id.uuidString)"
        let cooldown = TimeInterval(max(0, config.emailCooldownSeconds))
        let now = Date()
        if cooldown > 0, let last = EmailThrottleStore.shared.lastSent(forKey: key),
           now.timeIntervalSince(last) < cooldown {
            return
        }
        EmailThrottleStore.shared.record(key: key, at: now)

        let body = """
        Deep Sleep 自定义告警规则触发：

        • 规则：\(rule.name)
        • 指标：\(rule.metric.displayName) \(rule.operator.displayName) \(String(format: "%g", rule.threshold))\(rule.metric.unit)
        • 当前值：\(String(format: "%.1f", trigger.observedValue))\(rule.metric.unit)
        • 持续时间要求：\(rule.durationSeconds) 秒

        时间：\(ISO8601DateFormatter().string(from: trigger.timestamp))
        """

        Task { @MainActor in
            let result = await EmailChannel.shared.send(subject: "自定义告警：\(rule.name)", body: body)
            switch result {
            case .success:
                SleepController.shared.appendLog("规则告警邮件已发：\(rule.name)")
            case .failure(let reason):
                EmailThrottleStore.shared.clear(key: key)
                SleepController.shared.appendLog(
                    "规则告警邮件发送失败（\(rule.name)）：\(reason)", isError: true)
            }
        }
    }

    /// 服务器模式期间：只走 notify（若有），跳过 AlertWindow 的「冻结 / 终结」按钮。
    /// 这是用户原话：「系统监控若开启，则不允许自动处理，仅允许告警（若开启）」。
    private func handle(_ event: MonitorEvent) {
        let serverMode = SleepController.shared.isServerModeActive
        switch event {
        case .overload(let overload):
            SystemNotifier.shared.notifyOverload(overload)
            sendEmailIfEnabled(for: overload)
            if serverMode {
                // 仅通知，不弹「冻结 / 终结」对话框。
                // 服务器模式期间冻结/终结可能影响后台服务进程，不应自作主张。
                break
            }
            AlertWindowController.shared.presentOverload(
                event: overload,
                onSuspend: { pids in
                    Task { _ = try? await ProcessStatsProvider.shared.suspend(pids) }
                },
                onEnd: { pids in
                    Task { _ = try? await ProcessStatsProvider.shared.kill(pids) }
                }
            )
        case .singleProcessRAM(let ram):
            SystemNotifier.shared.notifySingleProcessRAM(ram)
            sendEmailIfEnabled(for: ram)
            if serverMode {
                break
            }
            AlertWindowController.shared.presentSingleProcessRAM(
                event: ram,
                onSuspend: { pid in
                    Task { _ = try? await ProcessStatsProvider.shared.suspend([pid]) }
                },
                onEnd: { pid in
                    Task { _ = try? await ProcessStatsProvider.shared.kill([pid]) }
                }
            )
        case .cpuTemp(let temp):
            // CPU 温度场景只告警，不冻结进程 —— 服务器模式与非服务器模式一致。
            SystemNotifier.shared.notifyCPUTemperature(temp)
            sendEmailIfEnabled(for: temp)
            AlertWindowController.shared.presentCPUTemperature(event: temp)
        }
    }

    /// 邮件告警钩子。配置未启用 / 冷却中 / 渠道未配置好 → 静默跳过。
    /// 失败不重试（不打扰用户），只写日志。
    private func sendEmailIfEnabled(for overload: OverloadEvent) {
        Self.sendEmailImpl(for: .overload(overload))
    }
    private func sendEmailIfEnabled(for ram: SingleProcessRAMEvent) {
        Self.sendEmailImpl(for: .singleProcessRAM(ram))
    }
    private func sendEmailIfEnabled(for temp: CPUTemperatureEvent) {
        Self.sendEmailImpl(for: .cpuTemp(temp))
    }

    /// 静态化避开「同方法内调同名」的歧义。
    private static func sendEmailImpl(for event: MonitorEvent) {
        let config = MonitorConfig.load()
        guard config.emailAlertEnabled else { return }

        // 自实现的轻量冷却：每个 event kind 单独记录上次发信时间。
        // 与 SystemMonitor 内置的 5 分钟冷却是平行的（SystemMonitor 冷却
        // 决定 onEvent 是否被调用，邮件冷却决定是否要再发一封）。
        let cooldown = TimeInterval(max(0, config.emailCooldownSeconds))
        let now = Date()
        let key: String
        let subject: String
        let body: String
        switch event {
        case .overload(let o):
            key = "overload"
            let top = o.topThree.map { "\($0.name) (pid \($0.pid))" }.joined(separator: "、")
            subject = "系统过载"
            body = """
            Deep Sleep 检测到系统过载：

            • RAM：\(String(format: "%.0f%%", o.ramPercent))
            • 累计 CPU：\(String(format: "%.0f%%", o.totalCpuPercent))
            • Top 3：\(top.isEmpty ? "—" : top)

            时间：\(ISO8601DateFormatter().string(from: o.timestamp))
            """
        case .singleProcessRAM(let r):
            key = "singleRAM-\(r.record.pid)"
            let gb = Double(r.record.rssBytes) / 1_073_741_824
            let tg = Double(r.thresholdBytes) / 1_073_741_824
            subject = "单进程 RAM 超阈：\(r.record.name)"
            body = """
            Deep Sleep 检测到单进程占用过高：

            • 进程：\(r.record.name)（pid \(r.record.pid)）
            • 当前：\(String(format: "%.2f GB", gb))
            • 阈值：\(String(format: "%.2f GB", tg))

            时间：\(ISO8601DateFormatter().string(from: r.timestamp))
            """
        case .cpuTemp(let t):
            key = "cpuTemp-\(Int(t.thresholdC))"
            subject = "CPU 温度过高"
            let parts: [String] = [
                t.maxC.map { String(format: "Max %.1f°C", $0) },
                t.averageC.map { String(format: "Avg %.1f°C", $0) },
                t.aggregateC.map { String(format: "Agg %.1f°C", $0) },
            ].compactMap { $0 }
            body = """
            Deep Sleep 检测到 CPU 温度过高：

            • 读数：\(parts.isEmpty ? "—" : parts.joined(separator: " / "))
            • 观测峰值：\(String(format: "%.1f°C", t.observedMaxC))
            • 阈值：\(String(format: "%.0f°C", t.thresholdC))

            时间：\(ISO8601DateFormatter().string(from: t.timestamp))
            """
        }

        // 冷却判定
        if cooldown > 0, let last = EmailThrottleStore.shared.lastSent(forKey: key),
           now.timeIntervalSince(last) < cooldown {
            return
        }
        EmailThrottleStore.shared.record(key: key, at: now)

        Task { @MainActor in
            let result = await EmailChannel.shared.send(subject: subject, body: body)
            switch result {
            case .success:
                SleepController.shared.appendLog("邮件告警已发：\(subject)")
            case .failure(let reason):
                // 失败时也要把冷却时间回退，否则同一事件会在 cooldown 期内
                // 一直显示「没发」却再也试不了 —— 用户体验比「每 5 分钟重试」差。
                EmailThrottleStore.shared.clear(key: key)
                SleepController.shared.appendLog(
                    "邮件告警发送失败（\(key)）：\(reason)", isError: true
                )
            }
        }
    }

    private func handleAction(kind: String, action: String, pids: [pid_t]) async {
        guard !pids.isEmpty else { return }
        switch (kind, action) {
        case ("overload", SystemNotifier.actionHandle),
             ("overload", SystemNotifier.actionEnd),
             ("singleRAM", SystemNotifier.actionHandle),
             ("singleRAM", SystemNotifier.actionEnd):
            _ = try? await ProcessStatsProvider.shared.kill(pids)
        case ("overload", SystemNotifier.actionSuspend),
             ("singleRAM", SystemNotifier.actionSuspend):
            _ = try? await ProcessStatsProvider.shared.suspend(pids)
        default:
            break
        }
    }
}