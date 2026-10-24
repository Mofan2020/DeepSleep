//
//  MonitorConfig.swift
//  Deep Sleep
//
//  监控配置（`MonitorConfig`）与它的 UserDefaults 持久化。
//
//  把 MonitorConfig 改成 Codable 并加 UserDefaults 桥。这是用户上一版
//  报的 bug：「启用监控」勾选切页回来没保留、「保存设置」按钮没用。
//  根因：之前是 @State + 内存里唯一的 struct，没有持久化与回读。
//
//  v1.4.1 起改：用 UserDefaults 的 JSON 形式持久化整个 config，
//  MonitoringView onAppear 时 load，任意字段变化时 save。
//
//  v1.8.0 起：结构体定义从 `SystemMonitor.swift` 搬到这里。
//  它是纯数据 + 纯逻辑，不依赖 SystemMonitor 的任何东西；
//  留在 SystemMonitor.swift 里会让 `scripts/test-monitor-config.swift`
//  为了编译一个纯 struct 而拖进整套 IO 依赖。
//

import Foundation

/// 监控配置（持久化到 UserDefaults）。
public struct MonitorConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// RAM 总使用率阈值（0–100）。
    public var ramHighPercent: Double
    /// 累计 CPU% 阈值（0–100，whole-CPU 口径）。
    public var cpuHighPercent: Double
    /// 持续超过阈值多少秒才报警。
    public var highDurationSeconds: Int
    /// 采样间隔（秒）。
    public var sampleIntervalSeconds: Double
    /// 是否允许自动冻结进程（必须在 UI 中显式打开；默认 false）。
    public var autoSuspend: Bool
    /// 单进程 RSS 阈值（字节）。任一进程当前占用 ≥ 此值，立刻报警，不走持续时间。
    public var singleProcessRAMBytes: Int
    /// CPU 温度阈值（°C，Apple Die Max / Average / Aggregate 中的最大值 ≥ 此值即告警）。
    /// 0 表示禁用（CPU 温度监控关闭）。
    public var cpuTempHighCelsius: Double
    /// CPU 温度监控是否启用(与 `enabled` 配合:总开关与子开关)。
    /// 单独保留是为了:总开关可以临时关掉全部监控而不丢温度阈值。
    public var cpuTempEnabled: Bool
    /// 进程优先级（nice）页每页进程数。范围 [10, 30]，默认 20。
    /// 用户在「进程优先级」页可改；改后立刻持久化到 `monitorConfig.v1`。
    public var nicePageSize: Int
    /// 是否启用邮件告警渠道（独立于系统通知）。启用后监控的过载 / 单进程
    /// RAM / CPU 温度事件会同时发一封邮件给用户在「邮件告警」页配的收件人。
    public var emailAlertEnabled: Bool
    /// 邮件告警的冷却时间（秒）：相同事件在窗口内只发一封。
    /// 默认 300（5 分钟）。冷却是按事件种类 + 阈值各自独立计算的，
    /// 与 SystemMonitor 内部的 5 分钟冷却是同源信息但**不再二次去重**。
    public var emailCooldownSeconds: Int

    public init(enabled: Bool = false,
                ramHighPercent: Double = 90,
                cpuHighPercent: Double = 85,
                highDurationSeconds: Int = 60,
                sampleIntervalSeconds: Double = 3,
                autoSuspend: Bool = false,
                singleProcessRAMBytes: Int = 4 * 1024 * 1024 * 1024,
                cpuTempHighCelsius: Double = 90,
                cpuTempEnabled: Bool = true,
                nicePageSize: Int = 20,
                emailAlertEnabled: Bool = false,
                emailCooldownSeconds: Int = 300) {
        self.enabled = enabled
        self.ramHighPercent = ramHighPercent
        self.cpuHighPercent = cpuHighPercent
        self.highDurationSeconds = highDurationSeconds
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.autoSuspend = autoSuspend
        self.singleProcessRAMBytes = singleProcessRAMBytes
        self.cpuTempHighCelsius = cpuTempHighCelsius
        self.cpuTempEnabled = cpuTempEnabled
        self.nicePageSize = NicePageSize.clamp(nicePageSize)
        self.emailAlertEnabled = emailAlertEnabled
        self.emailCooldownSeconds = max(0, min(emailCooldownSeconds, 24 * 60 * 60))
    }

    public static let `default` = MonitorConfig()
}

extension MonitorConfig {
    private static let storageKey = "monitorConfig.v1"

    /// 默认配置的 JSON 形式，用于比较「是否还是默认值」以决定是否落盘。
    /// 避免每次启动都把默认值写一遍 UserDefaults（污染磁盘）。
    ///
    /// **必须用 `.sortedKeys`**：JSONEncoder 对 struct 的键序不固定 ——
    /// 同一个值多次编码能产出好几种字节（实测 11 字段的 struct 连续
    /// 200 次比较，200 次全误判为「不等于默认值」）。不固定键序的话，
    /// 用户把配置改回默认值时判断会出错，该删的 key 删不掉，
    /// UserDefaults 里永远留着一份默认值副本。
    private static let defaultJSON: Data? = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(MonitorConfig.default)
    }()

    /// 从 UserDefaults 读。读不到或损坏时返回 .default。
    public static func load() -> MonitorConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(MonitorConfig.self, from: data)
        } catch {
            return .default
        }
    }

    /// 写到 UserDefaults。如果就是默认值就不写（避免无谓的磁盘改动）。
    public func saveIfNotDefault() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let mine = try? encoder.encode(self) else { return }
        if let defaultData = Self.defaultJSON, mine == defaultData {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
            return
        }
        UserDefaults.standard.set(mine, forKey: Self.storageKey)
    }
}