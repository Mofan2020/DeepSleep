//
//  AlertRule.swift
//  Deep Sleep
//
//  自定义告警规则的数据模型 + 持久化。
//
//  字段与枚举严格照 docs/protocol-contract-v1.9.md §8，不增不减不改名。
//  刻意**不提供**「冻结进程 / 结束进程」动作 —— 温度与内存类阈值下杀进程
//  会误伤，这与项目既有的「温度场景只告警不杀进程」立场一致。
//
//

import Foundation

/// 一条自定义告警规则。
struct AlertRule: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    /// 指标
    var metric: AlertMetric
    /// 比较方式
    var `operator`: AlertOperator
    /// 阈值
    var threshold: Double
    /// 持续超阈多少秒才告警
    var durationSeconds: Int
    /// 动作
    var action: AlertAction

    init(id: UUID = UUID(),
         name: String,
         isEnabled: Bool = true,
         metric: AlertMetric,
         comparison: AlertOperator,
         threshold: Double,
         durationSeconds: Int,
         action: AlertAction = .notification) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.metric = metric
        self.operator = comparison
        self.threshold = threshold
        self.durationSeconds = max(0, durationSeconds)
        self.action = action
    }

    /// 界面校验：返回 nil 表示这条规则可以直接保存，否则返回给用户看的原因。
    ///
    /// 放在模型上而不是视图里，是为了能单测 —— 这条校验曾经把「温度阈值不许
    /// 超过 90°C」当成规则，而那个限制是错的：
    ///
    /// 90°C 兜底接管的是**风扇转速**（把风扇拉到最大），跟告警是两条独立的路。
    /// 兜底生效的时候告警照样该报 —— 「温度已经到 90 了」正是最该报的时刻。
    /// 把告警阈值也卡在 90 以下，等于在最该报警的时候禁止报警。
    ///
    /// 风扇那条路径上的 89°C 上限是另一回事、也仍然保留：那里的区间是
    /// 「规则自己映射转速的范围」，超过 90 的部分会被兜底接管，写了也不生效，
    /// 属于「配了死设置」的防护。
    static func validationError(for rule: AlertRule) -> String? {
        if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "名称不能为空。"
        }
        if rule.durationSeconds < 0 {
            return "持续时间不能为负。"
        }
        if rule.threshold < 0 {
            return "阈值不能为负。"
        }
        return nil
    }
}

/// 可选指标。
enum AlertMetric: String, Codable, CaseIterable {
    /// 全机 CPU 累计使用百分比（0–100，whole-CPU 口径）
    case cpuPercent
    /// 内存总使用率（0–100）
    case ramPercent
    /// 单进程 RSS（GB）
    case singleProcessRAMGB
    /// CPU 温度（°C）
    case cpuTemperature
    /// 根卷已用百分比（0–100）
    case diskUsagePercent

    /// 界面显示名。
    var displayName: String {
        switch self {
        case .cpuPercent:          return "CPU 使用率"
        case .ramPercent:          return "内存使用率"
        case .singleProcessRAMGB:  return "单进程内存"
        case .cpuTemperature:      return "CPU 温度"
        case .diskUsagePercent:    return "磁盘使用率"
        }
    }

    /// 阈值单位（界面展示用）。
    var unit: String {
        switch self {
        case .cpuPercent, .ramPercent, .diskUsagePercent: return "%"
        case .singleProcessRAMGB:  return "GB"
        case .cpuTemperature:      return "°C"
        }
    }
}

/// 比较方式。
enum AlertOperator: String, Codable, CaseIterable {
    case greaterThan
    case lessThan

    /// 界面显示名。
    var displayName: String {
        switch self {
        case .greaterThan: return "大于"
        case .lessThan:    return "小于"
        }
    }

    /// 按 operator 比较。`greaterThan` 是严格大于，`lessThan` 是严格小于。
    func matches(value: Double, threshold: Double) -> Bool {
        switch self {
        case .greaterThan: return value > threshold
        case .lessThan:    return value < threshold
        }
    }
}

/// 触发后的动作。
enum AlertAction: String, Codable, CaseIterable {
    /// 只发系统通知
    case notification
    /// 只发邮件
    case email
    /// 通知 + 邮件
    case both

    /// 是否要发系统通知。
    var wantsNotification: Bool {
        self == .notification || self == .both
    }

    /// 是否要发邮件。
    var wantsEmail: Bool {
        self == .email || self == .both
    }

    /// 界面显示名。
    var displayName: String {
        switch self {
        case .notification: return "通知"
        case .email:        return "邮件"
        case .both:         return "通知 + 邮件"
        }
    }
}

// MARK: - 持久化

/// 告警规则列表的 UserDefaults 持久化。
///
/// 键名 `alertRules.v1`（契约 §8 钉死）。
///
/// **必须用 `.sortedKeys`**：JSONEncoder 对 struct 的键序不固定，
/// 同一个值多次编码能产出好几种字节（项目在 MonitorConfig 上踩过这个坑）。
/// 这里虽然不像 MonitorConfig 那样做「逐字节等于默认值」的比较，
/// 但固定键序仍然让落盘内容可复现 —— 便于排查「规则列表到底存了什么」。
enum AlertRuleStore {

    static let storageKey = "alertRules.v1"

    /// 读全部规则。读不到或损坏时返回空列表。
    static func load() -> [AlertRule] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([AlertRule].self, from: data)
        } catch {
            NSLog("[DeepSleep] 告警规则读取失败，已忽略：\(error.localizedDescription)")
            return []
        }
    }

    /// 写全部规则。空列表时删掉 key，不留空壳。
    static func save(_ rules: [AlertRule]) {
        let defaults = UserDefaults.standard
        guard !rules.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(rules) else {
            NSLog("[DeepSleep] 告警规则编码失败，本次改动未落盘")
            return
        }
        defaults.set(data, forKey: storageKey)
    }
}
