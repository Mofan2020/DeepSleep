//
//  ServerModeIdlePolicy.swift
//  Shared
//
//  服务器模式的「空闲判定」纯逻辑：给定当前阶段与空闲秒数，决定下一步。
//
//  抽成独立文件的原因：ServerModeController 依赖 AppKit / SleepController /
//  HelperClient，没法在命令行里直接跑；而这段判定恰恰是最容易出错、最需要
//  回归测试的部分（v1.6.2 的两处 bug 都在这里）。
//
//  测试见 `scripts/test-servermode-fsm.swift`。
//
//  ## 语义
//
//    off / starting         → idle（不参与倒计时）
//    waitingForIdle + 到点  → sleepNow（该关屏了）
//    waitingForIdle + 未到  → countdown(remaining)
//    locked + 仍空闲        → holdAtZero（保持归零，**不**重复关屏）
//    locked + 掉回阈值以下  → countdown(remaining)（用户回来了，重新计时）
//
//  `locked` 那一行是 v1.6.3 的核心修正：屏幕已经关着，只要用户没回来就
//  一直保持归零显示，绝不因为「idle 又超过阈值」而反复执行关屏。
//
//  而「用户回来」的判据是 idle **掉回阈值以下** —— 也就是「距离上次操作
//  过去多久」这个值被重置了。两种空闲检测方式（内核计时 / 事件监听）都
//  提供同样的语义，所以这里不需要区分模式。
//

import Foundation

public enum ServerModeIdlePolicy {

    /// 服务器模式运行阶段。
    public enum Phase: Equatable, Sendable {
        /// 未开启
        case off
        /// 已开启，正在 initialSleepDelaySeconds 内关屏 + 锁屏
        case starting
        /// 屏幕已关、系统未睡；倒计时保持归零，等用户操作
        case locked
        /// 用户操作过；空闲达到阈值后再次关屏锁屏
        case waitingForIdle

        public var isActive: Bool {
            switch self {
            case .off: return false
            default:   return true
            }
        }
    }

    /// 一次判定的结果。
    public enum Decision: Equatable, Sendable {
        /// 当前不需要计时（off / starting）
        case idle
        /// 刷新倒计时显示
        case countdown(remaining: Int)
        /// 空闲到点，应当关屏
        case sleepNow
        /// 已熄屏且仍然空闲 —— 保持归零，不重复关屏
        case holdAtZero
    }

    /// 决定这一 tick 该做什么。
    ///
    /// - Parameters:
    ///   - phase: 当前阶段
    ///   - idle: 当前空闲秒数（距离用户上次操作过去多久）
    ///   - threshold: 用户设定的空闲阈值
    public static func decide(phase: Phase,
                              idle: TimeInterval,
                              threshold: TimeInterval) -> Decision {
        switch phase {
        case .off, .starting:
            return .idle
        case .waitingForIdle:
            if idle >= threshold { return .sleepNow }
            return .countdown(remaining: max(0, Int(threshold - idle)))
        case .locked:
            if idle >= threshold { return .holdAtZero }
            return .countdown(remaining: max(0, Int(threshold - idle)))
        }
    }
}
