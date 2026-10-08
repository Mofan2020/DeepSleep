//
//  SystemNotifier.swift
//  Deep Sleep
//
//  系统过载监控用的 UserNotifications 封装。
//
//  通知分类：
//    - OVERLOAD_ALERT：处理 / 冻结进程 / 结束
//    - SINGLE_RAM_ALERT：处理 / 冻结进程 / 结束（单进程 RSS 超阈）
//
//  pid 通过 userInfo["pids"] 传回（逗号分隔），
//  UNUserNotificationCenterDelegate 收到 action 时再走 ProcessStatsProvider。
//

import Foundation
import UserNotifications

@MainActor
public final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {

    public static let shared = SystemNotifier()

    public static let overloadCategoryID = "DEEPSLEEP_OVERLOAD_ALERT"
    public static let singleRAMCategoryID = "DEEPSLEEP_SINGLE_RAM_ALERT"
    public static let cpuTempCategoryID = "DEEPSLEEP_CPU_TEMP_ALERT"

    public static let actionHandle = "HANDLE"
    public static let actionSuspend = "IGNORE"  // 在过载 / 单进程 RAM 分类里实际是冻结
    public static let actionEnd = "END"
    public static let actionDismiss = "DISMISS"  // CPU 温度通知只允许「知道了」

    /// 注册分类（应用启动时调一次）。
    public func registerCategories() {
        let actions: [UNNotificationAction] = [
            UNNotificationAction(identifier: Self.actionHandle,
                                 title: "处理",
                                 options: [.foreground]),
            UNNotificationAction(identifier: Self.actionSuspend,
                                 title: "冻结进程",
                                 options: [.foreground]),
            UNNotificationAction(identifier: Self.actionEnd,
                                 title: "结束",
                                 options: [.foreground])
        ]
        let overload = UNNotificationCategory(
            identifier: Self.overloadCategoryID,
            actions: actions,
            intentIdentifiers: [],
            options: [])
        let singleRAM = UNNotificationCategory(
            identifier: Self.singleRAMCategoryID,
            actions: actions,
            intentIdentifiers: [],
            options: [])
        // CPU 温度告警分类：只给「知道了」一个按钮 —— 冻结进程不能降温,
        // 让用户自己决定是关大程序、清理风扇、还是继续扛。
        let dismiss = UNNotificationAction(identifier: Self.actionDismiss,
                                           title: "知道了",
                                           options: [])
        let cpuTemp = UNNotificationCategory(
            identifier: Self.cpuTempCategoryID,
            actions: [dismiss],
            intentIdentifiers: [],
            options: [])

        UNUserNotificationCenter.current().setNotificationCategories([overload, singleRAM, cpuTemp])
        UNUserNotificationCenter.current().delegate = self
    }

    /// 申请通知权限（不影响应用；失败时退化到「只弹对话框」）。
    public func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            _ = granted
        }
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 发过载通知。
    public func notifyOverload(_ event: OverloadEvent) {
        let names = event.topThree.map(\.name).joined(separator: "、")
        let content = UNMutableNotificationContent()
        content.title = "⚠️ 系统过载"
        content.body = String(format: "RAM %.0f%% / 累计 CPU %.0f%%\nTop 3：%@",
                              event.ramPercent, event.totalCpuPercent, names)
        content.sound = .defaultCritical
        content.categoryIdentifier = Self.overloadCategoryID
        content.userInfo = [
            "pids": event.topThree.map { String($0.pid) }.joined(separator: ","),
            "kind": "overload"
        ]

        let request = UNNotificationRequest(
            identifier: "overload-\(Int(event.timestamp.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// 发单进程 RAM 超阈通知。
    public func notifySingleProcessRAM(_ event: SingleProcessRAMEvent) {
        let rssGB = Double(event.record.rssBytes) / 1_073_741_824
        let thresholdGB = Double(event.thresholdBytes) / 1_073_741_824
        let content = UNMutableNotificationContent()
        content.title = "⚠️ 单进程占用过高：\(event.record.name)"
        content.body = String(format: "当前 %.2f GB，已超过阈值 %.2f GB", rssGB, thresholdGB)
        content.sound = .defaultCritical
        content.categoryIdentifier = Self.singleRAMCategoryID
        content.userInfo = [
            "pids": String(event.record.pid),
            "kind": "singleRAM"
        ]

        let request = UNNotificationRequest(
            identifier: "singleRAM-\(event.record.pid)-\(Int(event.timestamp.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// 发 CPU 温度超阈通知。
    public func notifyCPUTemperature(_ event: CPUTemperatureEvent) {
        let content = UNMutableNotificationContent()
        content.title = "🌡️ CPU 温度过高"
        let parts: [String] = [
            event.maxC.map { String(format: "Max %.1f°C", $0) },
            event.averageC.map { String(format: "Avg %.1f°C", $0) },
            event.aggregateC.map { String(format: "Agg %.1f°C", $0) },
        ].compactMap { $0 }
        let body = parts.isEmpty
            ? String(format: "已超过 %.0f°C", event.thresholdC)
            : parts.joined(separator: " / ") + String(format: "（阈值 %.0f°C）", event.thresholdC)
        content.body = body
        content.sound = .defaultCritical
        content.categoryIdentifier = Self.cpuTempCategoryID
        content.userInfo = [
            "kind": "cpuTemp",
            "observedMax": String(format: "%.2f", event.observedMaxC),
            "threshold": String(format: "%.2f", event.thresholdC)
        ]

        let request = UNNotificationRequest(
            identifier: "cpuTemp-\(Int(event.timestamp.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// 用户在通知里点的 action：走 ProcessStatsProvider。
    public var onAction: ((_ kind: String, _ action: String, _ pids: [pid_t]) -> Void)?

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let kind = (info["kind"] as? String) ?? ""
        let pidsRaw = (info["pids"] as? String) ?? ""
        let pids = pidsRaw.split(separator: ",").compactMap { pid_t($0) }
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            Task { @MainActor in
                self.onAction?(kind, action, pids)
            }
        }
        completionHandler()
    }
}