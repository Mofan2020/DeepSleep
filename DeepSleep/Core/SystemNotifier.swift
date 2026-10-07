//
//  SystemNotifier.swift
//  Deep Sleep
//
//  系统过载监控 + 内存泄漏检测用的 UserNotifications 封装。
//
//  通知分类与 action：
//    - LEAK_ALERT：处理（建议）/ 忽略
//    - OVERLOAD_ALERT：处理 / 冻结进程 / 忽略
//
//  通知里的 PID 通过 userInfo[\"pids\"] 传回（逗号分隔），
//  UNUserNotificationCenterDelegate 收到 action 时再走 ProcessStatsProvider。
//

import Foundation
import UserNotifications

@MainActor
public final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {

    public static let shared = SystemNotifier()

    public static let leakCategoryID = "DEEPSLEEP_LEAK_ALERT"
    public static let overloadCategoryID = "DEEPSLEEP_OVERLOAD_ALERT"

    public static let actionHandle = "HANDLE"
    public static let actionSuspend = "IGNORE"  // 在过载分类里实际是冻结
    public static let actionEnd = "END"

    /// 注册分类（应用启动时调一次）。
    public func registerCategories() {
        let leak = UNNotificationCategory(
            identifier: Self.leakCategoryID,
            actions: [
                UNNotificationAction(identifier: Self.actionHandle,
                                     title: "处理（建议）",
                                     options: [.foreground]),
                UNNotificationAction(identifier: Self.actionSuspend,
                                     title: "忽略",
                                     options: [])
            ],
            intentIdentifiers: [],
            options: [])

        let overload = UNNotificationCategory(
            identifier: Self.overloadCategoryID,
            actions: [
                UNNotificationAction(identifier: Self.actionHandle,
                                     title: "处理",
                                     options: [.foreground]),
                UNNotificationAction(identifier: Self.actionSuspend,
                                     title: "冻结进程",
                                     options: [.foreground]),
                UNNotificationAction(identifier: Self.actionEnd,
                                     title: "结束",
                                     options: [.foreground])
            ],
            intentIdentifiers: [],
            options: [])

        UNUserNotificationCenter.current().setNotificationCategories([leak, overload])
        UNUserNotificationCenter.current().delegate = self
    }

    /// 申请通知权限（不影响应用；失败时退化到「只弹对话框」）。
    public func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            // 失败也不报错，UI 在监控设置页用 status 取真实状态。
            _ = granted
        }
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 发内存泄漏通知。
    public func notifyLeak(_ report: LeakReport) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ 疑似内存泄漏：\(report.name)"
        content.body = "占用 \(report.rssMB) MB，窗口内累计增长 \(report.cumulativeMB) MB。建议立即处理"
        content.sound = .defaultCritical
        content.categoryIdentifier = Self.leakCategoryID
        content.userInfo = [
            "pids": String(report.pid),
            "kind": "leak"
        ]

        let request = UNNotificationRequest(
            identifier: "leak-\(report.pid)-\(Int(report.cumulativeMB))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
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

    /// 用户在通知里点的 action：走 ProcessStatsProvider。
    /// 由 AlertWindowController / 主界面统一调度，本类只把 action 翻译成命令。
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