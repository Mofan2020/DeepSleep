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
//  v1.4.0 早期还有泄漏分支；v1.4.1 起只做过载监控。
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

    private func handle(_ event: MonitorEvent) {
        switch event {
        case .overload(let overload):
            SystemNotifier.shared.notifyOverload(overload)
            AlertWindowController.shared.presentOverload(
                event: overload,
                onSuspend: { pids in
                    Task { _ = try? await ProcessStatsProvider.shared.suspend(pids) }
                },
                onEnd: { pids in
                    Task { _ = try? await ProcessStatsProvider.shared.kill(pids) }
                }
            )
        }
    }

    private func handleAction(kind: String, action: String, pids: [pid_t]) async {
        guard !pids.isEmpty else { return }
        switch (kind, action) {
        case ("overload", SystemNotifier.actionHandle),
             ("overload", SystemNotifier.actionEnd):
            _ = try? await ProcessStatsProvider.shared.kill(pids)
        case ("overload", SystemNotifier.actionSuspend):
            _ = try? await ProcessStatsProvider.shared.suspend(pids)
        default:
            // 忽略 / 未知：什么都不做
            break
        }
    }
}