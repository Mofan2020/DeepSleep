//
//  test-servermode-fsm.swift
//  Deep Sleep 回归测试
//
//  服务器模式空闲判定状态机（`Shared/ServerModeIdlePolicy.swift`）的回归测试。
//
//  为什么必须有这层测试：v1.6.2 的两处 bug 全在这里，而且都是「无声错误」——
//  界面看起来正常在倒计时，但到点不动、或者归零后卡死，只有真跑一晚上才
//  发现。用户在实测中直接踩中。
//
//    bug 1：倒计时归零后不关屏。原因在 controller 里，不在 policy 里
//           （`performSleepAndLock` 的 guard 只放行 `.starting`）。policy
//           这里保证「waitingForIdle + 到点 → sleepNow」这一判定是对的。
//    bug 2：归零后把 tick timer 停掉，界面永远停在 0，用户操作也不会重置。
//           policy 这里保证「locked + 仍空闲 → holdAtZero（不重复关屏）」
//           与「locked + 用户回来 → countdown」这两条都成立。
//
//  运行：
//    swiftc Shared/ServerModeIdlePolicy.swift scripts/test-servermode-fsm.swift \
//           -o /tmp/fsm && /tmp/fsm
//

import Foundation

@main struct ServerModeFSMTests {
    static var failures = 0

    static func expect(_ actual: ServerModeIdlePolicy.Decision,
                       _ expected: ServerModeIdlePolicy.Decision,
                       _ label: String) {
        if actual == expected {
            print("[通过] \(label)")
        } else {
            print("FAIL [\(label)]  期望 \(expected)，实际 \(actual)")
            failures += 1
        }
    }

    static func main() {
        let T: TimeInterval = 600  // 阈值 10 分钟

        print("—— 不参与倒计时的阶段 ——")
        expect(ServerModeIdlePolicy.decide(phase: .off, idle: 9999, threshold: T),
               .idle, "off 阶段不动作")
        expect(ServerModeIdlePolicy.decide(phase: .starting, idle: 9999, threshold: T),
               .idle, "starting 阶段不动作（首次关屏由一次性定时器负责）")

        print("")
        print("—— waitingForIdle：倒计时 ——")
        expect(ServerModeIdlePolicy.decide(phase: .waitingForIdle, idle: 0, threshold: T),
               .countdown(remaining: 600), "刚操作过 → 剩余 600 秒")
        expect(ServerModeIdlePolicy.decide(phase: .waitingForIdle, idle: 300, threshold: T),
               .countdown(remaining: 300), "过 5 分钟 → 剩余 300 秒")
        expect(ServerModeIdlePolicy.decide(phase: .waitingForIdle, idle: 599, threshold: T),
               .countdown(remaining: 1), "还剩 1 秒 → 剩余 1 秒")
        expect(ServerModeIdlePolicy.decide(phase: .waitingForIdle, idle: 600, threshold: T),
               .sleepNow, "正好到阈值 → 关屏（边界包含）")
        expect(ServerModeIdlePolicy.decide(phase: .waitingForIdle, idle: 601, threshold: T),
               .sleepNow, "超过阈值 → 关屏")
        expect(ServerModeIdlePolicy.decide(phase: .waitingForIdle, idle: 100000, threshold: T),
               .sleepNow, "远超阈值 → 关屏（这正是 v1.6.2 被 guard 挡掉的场景）")

        print("")
        print("—— locked：已熄屏，倒计时保持归零 ——")
        expect(ServerModeIdlePolicy.decide(phase: .locked, idle: 600, threshold: T),
               .holdAtZero, "熄屏后刚好到阈值 → 保持归零，不重复关屏")
        expect(ServerModeIdlePolicy.decide(phase: .locked, idle: 3600, threshold: T),
               .holdAtZero, "熄屏后一小时没人动 → 保持归零，不重复关屏")
        expect(ServerModeIdlePolicy.decide(phase: .locked, idle: 86400, threshold: T),
               .holdAtZero, "熄屏后一整天没人动 → 保持归零，不重复关屏")
        expect(ServerModeIdlePolicy.decide(phase: .locked, idle: 599, threshold: T),
               .countdown(remaining: 1), "用户回来（idle 掉回阈值下）→ 重新计时")
        expect(ServerModeIdlePolicy.decide(phase: .locked, idle: 0, threshold: T),
               .countdown(remaining: 600), "用户刚操作 → 从满阈值重新计时")

        print("")
        print("—— 完整生命周期（模拟你实测的流程）——")
        var phase = ServerModeIdlePolicy.Phase.starting
        var idle: TimeInterval = 0

        // 开启后 5 秒：首次关屏由一次性定时器做，policy 不插手
        expect(ServerModeIdlePolicy.decide(phase: phase, idle: idle, threshold: T),
               .idle, "[1] 开启中：policy 不动作")
        phase = .locked  // 首次关屏完成

        // 用户没回来：idle 一路涨，从到阈值那一刻起应当一直保持归零
        var decisions: [ServerModeIdlePolicy.Decision] = []
        for step in stride(from: 600.0, through: 1800.0, by: 300.0) {
            idle = step
            decisions.append(ServerModeIdlePolicy.decide(phase: phase, idle: idle, threshold: T))
        }
        let allHold = decisions.allSatisfy { $0 == .holdAtZero }
        if allHold {
            print("[通过] [2] 熄屏后 10~30 分钟没人动：始终 holdAtZero（不重复关屏、界面停在归零）")
        } else {
            print("FAIL [2] 熄屏后应当始终 holdAtZero，实际 \(decisions)")
            failures += 1
        }

        // 用户回来操作
        idle = 0.0
        expect(ServerModeIdlePolicy.decide(phase: phase, idle: idle, threshold: T),
               .countdown(remaining: 600), "[3] 用户回来操作 → 重新从 600 秒计时")

        // 走回倒计时阶段（controller 在 countdown 分支里做这个切换）
        phase = .waitingForIdle
        expect(ServerModeIdlePolicy.decide(phase: phase, idle: 570, threshold: T),
               .countdown(remaining: 30), "[4] 又过 30 秒 → 剩余 30 秒")
        expect(ServerModeIdlePolicy.decide(phase: phase, idle: 600, threshold: T),
               .sleepNow, "[5] 再次到点 → 应当关屏")

        print("")
        if failures == 0 {
            print("测试结论: 全部通过")
        } else {
            print("测试结论: \(failures) 项失败")
            exit(1)
        }
    }
}
