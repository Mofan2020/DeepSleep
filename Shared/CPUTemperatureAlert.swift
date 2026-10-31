//
//  CPUTemperatureAlert.swift
//  Deep Sleep
//
//  CPU 温度告警的判定逻辑（纯逻辑，无 IO、无 AppKit，可脱离 App 单独测）。
//
//  为什么要抽出来：`SystemMonitor` 那一层要连 helper socket、跑在串行队列上，
//  不好测。而「多少度算超阈」「冷却期内要不要再报一次」这两条是真正会出错的
//  地方 —— 阈值取错会误报，冷却写错会刷屏。放在这里可以写断言。
//
//  温度数据来源：助手侧的 IOHID 私有温度事件通道（`getTemperatureSnapshot`），
//  与 90°C 风扇兜底同一份数据。v1.7.2 那版走 SMC，Apple Silicon 上 firmware
//  根本不回 key（实测 `dataSize = 0`），整条路是死的，功能因此下架。
//

import Foundation

/// CPU 温度告警的判定器。
///
/// 状态只有两样：一个冷却时间戳。冷却的作用是「同一阈值 5 分钟内不重复报」——
/// 温度掉到阈值以下再涨上来，属于正常波动，不该每次都弹窗。
public struct CPUTemperatureAlert: Sendable {

    /// 同一阈值内重复告警的冷却时间（秒）。
    public static let cooldownSeconds: TimeInterval = 300

    /// 判定用的阈值（°C）。<= 0 表示「不启用这一档」。
    public var thresholdCelsius: Double

    /// 上一次发出告警的时刻。nil = 还没报过。
    public var lastReportedAt: Date?

    public init(thresholdCelsius: Double, lastReportedAt: Date? = nil) {
        self.thresholdCelsius = thresholdCelsius
        self.lastReportedAt = lastReportedAt
    }

    /// 判定结果。
    public enum Decision: Equatable {
        /// 没到阈值，只更新缓存不告警。
        case belowThreshold
        /// 到阈值了，但还在冷却期里 —— 不重复报。
        case suppressedByCooldown
        /// 该报。
        case report
    }

    /// 判断一次读数要不要告警。
    ///
    /// - Parameters:
    ///   - observedCelsius: 本次读到的最高传感器温度（°C）。nil = 没读到。
    ///   - now: 当前时刻。
    ///   - isEnabled: 用户有没有打开这一档。
    /// - Returns: 判定结果。**不修改自身状态** —— 调用方按结果决定要不要
    ///   更新 `lastReportedAt`（这样「更新冷却时间戳」这一步是显式的，
    ///   不会在一次纯判定里悄悄改了状态）。
    public func decide(observedCelsius: Double?, now: Date, isEnabled: Bool) -> Decision {
        guard isEnabled, thresholdCelsius > 0 else { return .belowThreshold }
        guard let observed = observedCelsius else { return .belowThreshold }
        guard observed >= thresholdCelsius else { return .belowThreshold }
        if let last = lastReportedAt, now.timeIntervalSince(last) < Self.cooldownSeconds {
            return .suppressedByCooldown
        }
        return .report
    }

    /// 记下「刚刚报过一次」，开始冷却。
    public mutating func markReported(at now: Date) {
        lastReportedAt = now
    }
}
