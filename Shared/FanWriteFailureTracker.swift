//
//  FanWriteFailureTracker.swift
//  Deep Sleep
//
//  记录「某个风扇连续写不进」这件事，并判断什么时候该放手。
//
//  为什么要这个：
//
//  风扇写 SMC 失败有两种：
//    1. 写入操作本身失败（SMC 命令报错、连接断了、键不存在）；
//    2. 写入成功但写后校验不通过 —— 期望目标转速和写后读回的实际目标转速不同。
//
//  这两种都算「改不动转速」。偶发一次不稀奇（机器刚从睡眠醒来、SMC 正在重置、
//  扩展坞热插拔），重试就好。但如果**持续**改不动，继续每几秒重试一次
// 只会一直失败，而且风扇可能停在一个不合适的转速上没人管。
//
//  所以：连续失败满 `FanControl.stallThresholdSeconds`（60 秒）就升级处理 ——
//  停止修改这个风扇的转速，交回系统控制。如果连交还都失败，那是严重问题，
//  必须告诉用户（风扇可能卡在一个我们控制不了的状态）。
//
//  判定口径：
//   - 一次成功就把连续失败清零（这个风扇又听话了）。
//   - 升级条件是「距第一次失败 ≥ 60 秒」**且**「最近一次失败在 30 秒内」。
//     后半条是为了区分「持续改不动」和「早先失败过一次、之后一直没再试」：
//     比如用户把规则关掉了，那个失败记录不该在 60 秒后自己升级成「交还系统」。
//
//  这个类型不碰 SMC，纯逻辑，可以单测。
//

import Foundation

public struct FanWriteFailureTracker: Sendable {

    /// 一个风扇的连续失败记录。
    public struct Streak: Sendable, Equatable {
        public let fan: Int
        /// 连续失败的第一次发生时刻。
        public let firstFailureAt: Date
        /// 最近一次失败的时刻。
        public var lastFailureAt: Date
        /// 最近一次失败的原因。
        public var lastReason: String

        public init(fan: Int, firstFailureAt: Date, lastFailureAt: Date, lastReason: String) {
            self.fan = fan
            self.firstFailureAt = firstFailureAt
            self.lastFailureAt = lastFailureAt
            self.lastReason = lastReason
        }
    }

    /// 连续失败满多久算「持续改不动」。
    public let thresholdSeconds: TimeInterval
    /// 「还在失败」的宽限：最近一次失败超过这个时间就算没在持续失败。
    public let activityGraceSeconds: TimeInterval

    private var streaks: [Int: Streak] = [:]

    public init(thresholdSeconds: TimeInterval = FanControl.stallThresholdSeconds,
                activityGraceSeconds: TimeInterval = FanControl.stallActivityGraceSeconds) {
        self.thresholdSeconds = thresholdSeconds
        self.activityGraceSeconds = activityGraceSeconds
    }

    /// 记一次失败。返回 true 表示这个风扇已经「持续改不动」，该升级处理了。
    @discardableResult
    public mutating func recordFailure(fan: Int, reason: String, now: Date) -> Bool {
        if var existing = streaks[fan] {
            existing.lastFailureAt = now
            existing.lastReason = reason
            streaks[fan] = existing
        } else {
            streaks[fan] = Streak(fan: fan, firstFailureAt: now, lastFailureAt: now, lastReason: reason)
        }
        return isDue(fan: fan, now: now)
    }

    /// 记一次成功 —— 这个风扇又听话了，连续失败清零。
    public mutating func recordSuccess(fan: Int) {
        streaks.removeValue(forKey: fan)
    }

    /// 这个风扇当前是否「持续改不动」。
    public func isDue(fan: Int, now: Date) -> Bool {
        guard let streak = streaks[fan] else { return false }
        let elapsed = now.timeIntervalSince(streak.firstFailureAt)
        let idle = now.timeIntervalSince(streak.lastFailureAt)
        return elapsed >= thresholdSeconds && idle <= activityGraceSeconds
    }

    /// 所有「持续改不动」的风扇序号。
    public func fansDue(now: Date) -> [Int] {
        streaks.keys.filter { isDue(fan: $0, now: now) }.sorted()
    }

    /// 某个风扇的连续失败记录。
    public func streak(for fan: Int) -> Streak? {
        streaks[fan]
    }

    /// 升级处理之后清掉 —— 已经决定「不再修改」，不再统计。
    public mutating func clear(fan: Int) {
        streaks.removeValue(forKey: fan)
    }

    public mutating func removeAll() {
        streaks.removeAll()
    }

    /// 当前有连续失败记录的风扇。
    public var trackedFans: [Int] {
        streaks.keys.sorted()
    }
}
