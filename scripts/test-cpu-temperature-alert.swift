//
//  test-cpu-temperature-alert.swift
//  DeepSleep
//
//  CPU 温度告警判定逻辑的自测（真实源码 Shared/CPUTemperatureAlert.swift）。
//
//  为什么这层要单独测：阈值判定和冷却是这个功能里唯一会「静默出错」的部分。
//  阈值取错 → 用户在正常温度下被弹窗轰炸；
//  冷却写错 → 温度在阈值附近抖动时反复告警。
//  两种都不报 crash，只会让人觉得「这功能有问题」，很难定位。
//
//  运行： bash scripts/test-cpu-temperature-alert.sh
//

import Foundation

@main
struct CPUTemperatureAlertTests {

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

        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // MARK: - 阈值判定

        print("\n== 阈值判定 ==")

        let alert = CPUTemperatureAlert(thresholdCelsius: 90)

        checkEqual(
            "低于阈值不告警",
            alert.decide(observedCelsius: 89.9, now: now, isEnabled: true),
            .belowThreshold)
        checkEqual(
            "正好等于阈值算超阈",
            alert.decide(observedCelsius: 90.0, now: now, isEnabled: true),
            .report)
        checkEqual(
            "高于阈值告警",
            alert.decide(observedCelsius: 95.5, now: now, isEnabled: true),
            .report)

        // 读到 nil（助手不可用）不能当成 0°C，更不能当成超阈。
        checkEqual(
            "读数缺失时按未超阈处理",
            alert.decide(observedCelsius: nil, now: now, isEnabled: true),
            .belowThreshold)

        // 开关关着 → 永远不告警，哪怕温度早就爆表。
        checkEqual(
            "开关关闭时不告警",
            alert.decide(observedCelsius: 120.0, now: now, isEnabled: false),
            .belowThreshold)

        // 阈值 0 = 不启用这一档（0 是「关闭」的约定值）。
        let zeroThreshold = CPUTemperatureAlert(thresholdCelsius: 0)
        checkEqual(
            "阈值为 0 时不告警",
            zeroThreshold.decide(observedCelsius: 120.0, now: now, isEnabled: true),
            .belowThreshold)

        // MARK: - 冷却

        print("\n== 冷却 ==")

        var cooling = CPUTemperatureAlert(thresholdCelsius: 90)
        cooling.markReported(at: now)

        checkEqual(
            "刚报过立刻又超阈 → 冷却期内不重复报",
            cooling.decide(observedCelsius: 95.0, now: now, isEnabled: true),
            .suppressedByCooldown)
        checkEqual(
            "冷却期内温度再高也不重复报",
            cooling.decide(observedCelsius: 110.0,
                           now: now.addingTimeInterval(299),
                           isEnabled: true),
            .suppressedByCooldown)
        checkEqual(
            "冷却期满后恢复告警",
            cooling.decide(observedCelsius: 95.0,
                           now: now.addingTimeInterval(300),
                           isEnabled: true),
            .report)

        // 冷却期间温度掉回阈值以下 —— 界面上照样要刷到温度，
        // 判定层只管「报不报」。
        checkEqual(
            "冷却期内温度回落仍按未超阈处理",
            cooling.decide(observedCelsius: 60.0, now: now, isEnabled: true),
            .belowThreshold)

        // MARK: - 状态更新时机

        print("\n== 状态更新时机 ==")

        var mutable = CPUTemperatureAlert(thresholdCelsius: 90)
        check("初始没有报过", mutable.lastReportedAt == nil)
        checkEqual(
            "判定本身不改状态",
            mutable.decide(observedCelsius: 95.0, now: now, isEnabled: true),
            .report)
        check("判定之后 lastReportedAt 仍是 nil", mutable.lastReportedAt == nil)

        mutable.markReported(at: now)
        checkEqual("标记后 lastReportedAt 等于标记时刻",
                   mutable.lastReportedAt?.timeIntervalSince1970 ?? -1,
                   now.timeIntervalSince1970)

        // MARK: - 冷却时长约定

        print("\n== 冷却时长约定 ==")
        checkEqual("冷却时长是 300 秒", CPUTemperatureAlert.cooldownSeconds, 300.0)

        // MARK: - 汇总

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
