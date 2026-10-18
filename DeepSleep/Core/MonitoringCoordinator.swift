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

@MainActor
final class MonitoringCoordinator {

    static let shared = MonitoringCoordinator()

    private init() {}

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