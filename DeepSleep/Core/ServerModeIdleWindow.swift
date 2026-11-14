//
//  ServerModeIdleWindow.swift
//  Deep Sleep
//
//  服务器模式的倒计时口径：开启之前的空闲不算数。
//
//  为什么单独一个文件：这是纯算术，判定它只需要两个数字。放在
//  ServerModeController 里就没法离线验证 —— 那个类依赖 AppKit / 助手，
//  命令行起不来。测试见 `scripts/test-state-restore.swift`。
//
//  ## 要解决的问题
//
//  旧行为是「一进入服务器模式就执行首次关屏」：开启后固定几秒就熄屏。
//  用户要的是「进入之后不立刻关屏，等真正空闲到设定时长再关」。
//
//  空闲值本身是「距最后一次键盘 / 鼠标操作多久」，它不关心服务器模式是
//  什么时候打开的。远程开启（URL / Siri / 命令行）时机器可能已经空闲了
//  几个小时 —— 直接用原始空闲值，会把「刚开启」变成「立刻熄屏」，正是
//  要改掉的那件事。
//
//  ## 口径
//
//  有效空闲 = min(原始空闲, 开启后经过的时间)
//
//  两个数取小，含义就是「以最后一次操作为准，但不早于开启那一刻」：
//    - 开启前就空闲很久 → 以开启时刻起算，等满设定时长才关；
//    - 开启后一直在用 → 原始空闲更小，按真实的最后一次操作计时。
//

import Foundation

/// 服务器模式的倒计时口径。
enum ServerModeIdleWindow {

    /// 用来做倒计时的「有效空闲时长」。
    ///
    /// - Parameters:
    ///   - rawIdle: 距用户最后一次操作的秒数。
    ///   - sinceEnabled: 服务器模式开启至今的秒数。
    static func effectiveIdle(rawIdle: TimeInterval, sinceEnabled: TimeInterval) -> TimeInterval {
        // 负值只可能来自时钟回拨，按 0 处理 —— 否则倒计时会突然归零并立刻关屏。
        let raw = max(0, rawIdle)
        let window = max(0, sinceEnabled)
        return min(raw, window)
    }
}
