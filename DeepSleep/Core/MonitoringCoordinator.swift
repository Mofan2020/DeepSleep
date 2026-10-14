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
            AlertWindowController.shared.presentCPUTemperature(event: temp)
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