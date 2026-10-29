//
//  test-fan-stall.swift
//  DeepSleep
//
//  「风扇连续写不进 → 停止修改、交回系统」的判定逻辑自测。
//
//  这一层是纯逻辑，不碰 SMC，所以能单测。测的是三件事：
//    1. 偶发失败不该触发升级（重试就好）；
//    2. 连续失败满 60 秒该触发升级；
//    3. 用户把规则关掉之后，那个失败记录不该自己升级成「交还系统」。
//
//  运行： bash scripts/test-fan-stall.sh
//

import Foundation

@main
struct FanStallTests {

    static func main() {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ actual: String = "") {
            if condition {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)" + (actual.isEmpty ? "" : " —— 实际: \(actual)"))
                failures += 1
            }
        }

        func checkEqual<T: Equatable>(_ name: String, _ lhs: T, _ rhs: T) {
            if lhs == rhs {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)：期望 \(rhs)，实际 \(lhs)")
                failures += 1
            }
        }

        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // MARK: - 阈值

        print("\n== 阈值 ==")
        checkEqual("阈值是 60 秒", FanControl.stallThresholdSeconds, 60.0)
        checkEqual("活动宽限是 30 秒", FanControl.stallActivityGraceSeconds, 30.0)

        // MARK: - 偶发失败

        print("\n== 偶发失败不该升级 ==")

        var tracker = FanWriteFailureTracker()
        _ = tracker.recordFailure(fan: 0, reason: "写后校验失败", now: t0)
        check("第一次失败不触发升级", !tracker.isDue(fan: 0, now: t0))

        // 隔 10 秒又失败一次，之间没有持续失败
        _ = tracker.recordFailure(fan: 0, reason: "写后校验失败", now: t0.addingTimeInterval(10))
        check("10 秒后还没到阈值", !tracker.isDue(fan: 0, now: t0.addingTimeInterval(10)))

        // 一次成功就清零
        tracker.recordSuccess(fan: 0)
        check("成功之后连续失败清零", tracker.streak(for: 0) == nil)
        check("成功之后不再升级", !tracker.isDue(fan: 0, now: t0.addingTimeInterval(100)))

        // MARK: - 持续失败

        print("\n== 持续失败满 60 秒该升级 ==")

        tracker = FanWriteFailureTracker()
        _ = tracker.recordFailure(fan: 1, reason: "SMC 命令失败", now: t0)
        // 持续失败，但每次间隔在宽限窗口内
        for step in 1...12 {
            _ = tracker.recordFailure(fan: 1, reason: "SMC 命令失败",
                                      now: t0.addingTimeInterval(Double(step) * 5))
        }
        check("第 55 秒还没升级", !tracker.isDue(fan: 1, now: t0.addingTimeInterval(55)))
        check("第 60 秒升级", tracker.isDue(fan: 1, now: t0.addingTimeInterval(60)))
        check("到期风扇列表里有它", tracker.fansDue(now: t0.addingTimeInterval(60)) == [1])

        // MARK: - 失败原因要留住

        print("\n== 失败原因 ==")
        tracker = FanWriteFailureTracker()
        _ = tracker.recordFailure(fan: 2, reason: "第一次的原因", now: t0)
        _ = tracker.recordFailure(fan: 2, reason: "最后一次的原因", now: t0.addingTimeInterval(5))
        if let streak = tracker.streak(for: 2) {
            checkEqual("保留最后一次原因", streak.lastReason, "最后一次的原因")
            checkEqual("第一次失败的时刻没被改", streak.firstFailureAt, t0)
        } else {
            check("能读到连续失败记录", false)
        }

        // MARK: - 停手之后不再算

        print("\n== 升级之后清掉 ==")
        tracker = FanWriteFailureTracker()
        _ = tracker.recordFailure(fan: 3, reason: "x", now: t0)
        tracker.clear(fan: 3)
        check("清掉之后没有记录", tracker.streak(for: 3) == nil)
        check("清掉之后不再升级", !tracker.isDue(fan: 3, now: t0.addingTimeInterval(120)))

        // MARK: - 用户关掉规则

        print("\n== 用户把规则关掉后不该自己升级 ==")
        tracker = FanWriteFailureTracker()
        _ = tracker.recordFailure(fan: 4, reason: "x", now: t0)
        // 之后一直没有再试（用户在 10 秒后就关了规则）
        check("很久之后、但没有新失败 → 不升级",
              !tracker.isDue(fan: 4, now: t0.addingTimeInterval(300)))

        // MARK: - 多个风扇互不影响

        print("\n== 多个风扇互不影响 ==")
        tracker = FanWriteFailureTracker()
        _ = tracker.recordFailure(fan: 0, reason: "a", now: t0)
        _ = tracker.recordFailure(fan: 1, reason: "b", now: t0)
        for step in 1...12 {
            _ = tracker.recordFailure(fan: 1, reason: "b", now: t0.addingTimeInterval(Double(step) * 5))
        }
        check("只有风扇 1 到期", tracker.fansDue(now: t0.addingTimeInterval(60)) == [1])
        tracker.recordSuccess(fan: 1)
        check("风扇 1 成功后都不到期", tracker.fansDue(now: t0.addingTimeInterval(60)).isEmpty)

        // MARK: - 汇总
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }

}
