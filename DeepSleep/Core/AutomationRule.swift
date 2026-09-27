//
//  AutomationRule.swift
//  Deep Sleep
//
//  自动化规则模型。让「管理睡眠」从手动开关变成可配置的自动行为。
//

import Foundation

/// 规则的触发条件。
enum RuleTrigger: Codable, Equatable, Hashable {
    /// 在指定的时间段内（跨零点自动处理），可限定星期几。
    case timeWindow(startMinutes: Int, endMinutes: Int, weekdays: Set<Int>)
    /// 电源状态变化：接入电源 / 使用电池。
    case powerSource(onAC: Bool)
    /// 指定应用正在运行时。
    case appRunning(bundleIdentifier: String, displayName: String)

    var displayName: String {
        switch self {
        case .timeWindow(let start, let end, let weekdays):
            let dayText = weekdays.isEmpty || weekdays.count == 7
                ? "每天"
                : weekdays.sorted().map { RuleTrigger.weekdayName($0) }.joined(separator: "、")
            return "\(dayText) \(RuleTrigger.timeText(start)) – \(RuleTrigger.timeText(end))"
        case .powerSource(let onAC):
            return onAC ? "接入电源时" : "使用电池时"
        case .appRunning(_, let displayName):
            return "\(displayName) 正在运行时"
        }
    }

    var symbolName: String {
        switch self {
        case .timeWindow:  return "clock"
        case .powerSource: return "powerplug"
        case .appRunning:  return "app.badge"
        }
    }

    /// 规则是否可持久化（应用监视规则在目标应用不存在时会被丢弃）。
    var isPersistable: Bool {
        if case .appRunning(let bundleIdentifier, _) = self {
            return !bundleIdentifier.isEmpty
        }
        return true
    }

    static func timeText(_ minutes: Int) -> String {
        let clamped = max(0, min(24 * 60 - 1, minutes))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    static func weekdayName(_ index: Int) -> String {
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        guard index >= 0, index < names.count else { return "?" }
        return "周" + names[index]
    }
}

/// 一条自动化规则。
struct AutomationRule: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var isEnabled: Bool = true
    var trigger: RuleTrigger
    /// 规则生效时要保持的 assertion 集合。
    var assertions: Set<AssertionKind>

    var summary: String {
        if assertions.isEmpty { return "未选择动作" }
        return assertions
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.title)
            .joined(separator: " + ")
    }
}

/// 内置规则模板，让用户不必从零配置。
enum RuleTemplate {
    static func all() -> [AutomationRule] {
        [
            AutomationRule(
                name: "工作时间保持在线",
                trigger: .timeWindow(startMinutes: 9 * 60, endMinutes: 18 * 60, weekdays: [2, 3, 4, 5, 6]),
                assertions: [.preventIdleSystemSleep]
            ),
            AutomationRule(
                name: "接电源时不合盖睡眠",
                trigger: .powerSource(onAC: true),
                assertions: [.preventIdleSystemSleep, .preventIdleDisplaySleep]
            ),
            AutomationRule(
                name: "演示时屏幕常亮",
                trigger: .powerSource(onAC: true),
                assertions: [.preventIdleDisplaySleep]
            )
        ]
    }
}
