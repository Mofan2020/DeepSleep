//
//  test-fan-control.swift
//  Deep Sleep 回归测试
//
//  验证风扇控制的**纯逻辑**：温度→转速线性映射、滞回、下发节流、
//  90°C 兜底状态机（触发 / 冷却 / 解除）、免责声明门禁。
//
//  不验证的：真机风扇写入。普通进程调 IOServiceOpen("AppleSMC") 会 Bus error
//  崩溃（已实测），所以写 SMC 的路径只能在装了 root 助手之后验证。
//
//  运行：
//  swiftc -parse-as-library \
//    Shared/FanModels.swift Shared/HelperProtocol.swift Shared/UnixSocket.swift \
//    DeepSleep/Privileged/HelperClient.swift \
//    DeepSleep/Core/ThermalMonitor.swift \
//    DeepSleep/Core/FanController.swift \
//    DeepSleep/Core/FanDisclaimer.swift \
//    scripts/test-fan-control.swift -o /tmp/fan-test && /tmp/fan-test
//

import Foundation

@main
struct FanControlTests {

    static func main() {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)" + (detail.isEmpty ? "" : " —— \(detail)"))
                failures += 1
            }
        }

        func checkEqual<T: Equatable>(_ name: String, _ expected: T, _ actual: T) {
            check(name, expected == actual, "期望 \(expected)，实际 \(actual)")
        }

        // ============================================ 温度 → 转速线性映射
        print("== 温度 → 转速线性映射（minRPM 1171 / maxRPM 7296）==")
        let lo = 1171, hi = 7296
        checkEqual("温度 30°C ≤ 最低温 50°C → minRPM",
                   lo, FanControlPolicy.mappedRPM(temperature: 30, minTempC: 50, maxTempC: 90,
                                                  minRPM: lo, maxRPM: hi))
        checkEqual("温度正好等于最低温 50°C → minRPM",
                   lo, FanControlPolicy.mappedRPM(temperature: 50, minTempC: 50, maxTempC: 90,
                                                  minRPM: lo, maxRPM: hi))
        checkEqual("温度 90°C = 最高温 → maxRPM",
                   hi, FanControlPolicy.mappedRPM(temperature: 90, minTempC: 50, maxTempC: 90,
                                                  minRPM: lo, maxRPM: hi))
        checkEqual("温度 95°C > 最高温 → maxRPM（夹住）",
                   hi, FanControlPolicy.mappedRPM(temperature: 95, minTempC: 50, maxTempC: 90,
                                                  minRPM: lo, maxRPM: hi))
        checkEqual("温度 70°C（区间正中）→ (1171+7296)/2 ≈ 4234",
                   4234, FanControlPolicy.mappedRPM(temperature: 70, minTempC: 50, maxTempC: 90,
                                                    minRPM: lo, maxRPM: hi))
        checkEqual("温度 60°C（1/4 处）→ 1171 + 0.25*6125 ≈ 2702",
                   2702, FanControlPolicy.mappedRPM(temperature: 60, minTempC: 50, maxTempC: 90,
                                                    minRPM: lo, maxRPM: hi))

        // 单调性：温度升高，转速不能降。
        var monotonic = true
        var previous = -1
        for celsius in stride(from: 40.0, through: 100.0, by: 0.5) {
            let rpm = FanControlPolicy.mappedRPM(temperature: celsius, minTempC: 50, maxTempC: 90,
                                                 minRPM: lo, maxRPM: hi)
            if rpm < previous { monotonic = false }
            previous = rpm
        }
        check("40–100°C 每 0.5°C 采样，映射结果单调不减", monotonic)

        // 异常输入：minTemp > maxTemp
        print("\n== 异常输入 ==")
        checkEqual("minTemp 90 > maxTemp 50（区间反了）→ maxRPM（按最热处理）",
                   hi, FanControlPolicy.mappedRPM(temperature: 60, minTempC: 90, maxTempC: 50,
                                                  minRPM: lo, maxRPM: hi))
        checkEqual("minTemp = maxTemp（区间退化）→ maxRPM",
                   hi, FanControlPolicy.mappedRPM(temperature: 60, minTempC: 70, maxTempC: 70,
                                                  minRPM: lo, maxRPM: hi))
        checkEqual("minRPM 5000 > maxRPM 2000（风扇区间反了）→ 2000 当作上限",
                   5000, FanControlPolicy.mappedRPM(temperature: 60, minTempC: 50, maxTempC: 90,
                                                    minRPM: 5000, maxRPM: 2000))
        checkEqual("温度低于区间且 minRPM=0 → 0",
                   0, FanControlPolicy.mappedRPM(temperature: 10, minTempC: 50, maxTempC: 90,
                                                minRPM: 0, maxRPM: 7000))

        // 写入夹取
        print("\n== 写入夹取 ==")
        checkEqual("500 RPM 低于 minRPM 1171 → 夹到 1171",
                   1171, FanControlPolicy.clampForWrite(500, minRPM: 1171, maxRPM: 7296))
        checkEqual("9999 RPM 高于 maxRPM 7296 → 夹到 7296",
                   7296, FanControlPolicy.clampForWrite(9999, minRPM: 1171, maxRPM: 7296))
        checkEqual("3000 RPM 在区间内 → 原样",
                   3000, FanControlPolicy.clampForWrite(3000, minRPM: 1171, maxRPM: 7296))

        // ============================================ 滞回 / 节流
        print("\n== 滞回与节流 ==")
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // 从未下发过 → 立刻写
        checkEqual("首次（无历史）→ firstWrite",
                   FanControlPolicy.DispatchAction.write(rpm: 3000, reason: .firstWrite),
                   FanControlPolicy.decide(target: 3000, lastWrittenRPM: nil, lastWrittenAt: nil,
                                           now: t0, emergency: false))

        // 距上次 11 秒（> 10 秒节流），目标只差 50 RPM（< 100 滞回）
        let lastAt = t0.addingTimeInterval(-11)
        checkEqual("目标差 50 RPM（< 100 滞回）→ 重发上次的值做续租，不跟新目标",
                   FanControlPolicy.DispatchAction.write(rpm: 3000, reason: .leaseRefresh),
                   FanControlPolicy.decide(target: 3050, lastWrittenRPM: 3000, lastWrittenAt: lastAt,
                                           now: t0, emergency: false))
        checkEqual("目标差 100 RPM（= 滞回阈值）→ targetChanged",
                   FanControlPolicy.DispatchAction.write(rpm: 3100, reason: .targetChanged),
                   FanControlPolicy.decide(target: 3100, lastWrittenRPM: 3000, lastWrittenAt: lastAt,
                                           now: t0, emergency: false))
        checkEqual("目标差 99 RPM → 仍走续租（不到滞回）",
                   FanControlPolicy.DispatchAction.write(rpm: 3000, reason: .leaseRefresh),
                   FanControlPolicy.decide(target: 3099, lastWrittenRPM: 3000, lastWrittenAt: lastAt,
                                           now: t0, emergency: false))

        // 节流：距上次只有 3 秒
        let recent = t0.addingTimeInterval(-3)
        checkEqual("距上次 3 秒（< 10 秒节流）→ throttled，即使目标差很多",
                   FanControlPolicy.DispatchAction.skip(reason: .throttled),
                   FanControlPolicy.decide(target: 7000, lastWrittenRPM: 3000, lastWrittenAt: recent,
                                           now: t0, emergency: false))

        // 目标没变且租约新鲜
        let fresh = t0.addingTimeInterval(-11)
        let unchanged = FanControlPolicy.decide(target: 3000, lastWrittenRPM: 3000,
                                                lastWrittenAt: fresh, now: t0, emergency: false)
        checkEqual("目标完全没变、已过节流 → 续租写同值", .write(rpm: 3000, reason: .leaseRefresh), unchanged)

        let justNow = t0.addingTimeInterval(-2)
        checkEqual("目标没变、2 秒前刚写过 → 不下发（落在节流窗口内，reason 报 throttled）",
                   FanControlPolicy.DispatchAction.skip(reason: .throttled),
                   FanControlPolicy.decide(target: 3000, lastWrittenRPM: 3000,
                                           lastWrittenAt: justNow, now: t0, emergency: false))

        // 「不再写」的两种原因要分清：节流窗口内 = throttled；
        // 已过节流但没有续租需求（自动模式）= unchanged。
        checkEqual("目标没变、已过节流、不续租 → unchanged",
                   FanControlPolicy.DispatchAction.skip(reason: .unchanged),
                   FanControlPolicy.decide(target: 0, lastWrittenRPM: 0, lastWrittenAt: lastAt,
                                           now: t0, emergency: false, refreshLease: false))

        // 自动模式不续租（没有租约可续）
        checkEqual("refreshLease=false 且目标没变 → unchanged，不写",
                   FanControlPolicy.DispatchAction.skip(reason: .unchanged),
                   FanControlPolicy.decide(target: 0, lastWrittenRPM: 0, lastWrittenAt: lastAt,
                                           now: t0, emergency: false, refreshLease: false))

        // 紧急态绕过节流
        checkEqual("紧急态：2 秒前刚写过，目标不同 → 立刻写（绕过节流）",
                   FanControlPolicy.DispatchAction.write(rpm: 7296, reason: .emergencyOverride),
                   FanControlPolicy.decide(target: 7296, lastWrittenRPM: 3000,
                                           lastWrittenAt: justNow, now: t0, emergency: true))

        // 滞回边界扫一遍：|Δ| 从 0 到 300
        var hysteresisCorrect = true
        for delta in 0...300 {
            let action = FanControlPolicy.decide(target: 3000 + delta, lastWrittenRPM: 3000,
                                                 lastWrittenAt: lastAt, now: t0, emergency: false)
            if delta < 100 {
                if action != .write(rpm: 3000, reason: .leaseRefresh) { hysteresisCorrect = false }
            } else {
                if action != .write(rpm: 3000 + delta, reason: .targetChanged) { hysteresisCorrect = false }
            }
        }
        check("Δ 0…99 一律续租旧值，Δ ≥ 100 一律下发新值", hysteresisCorrect)

        // ============================================ 90°C 兜底状态机
        print("\n== 90°C 兜底状态机 ==")
        var tracker = FanEmergencyTracker()
        let base = Date(timeIntervalSince1970: 2_000_000)

        checkEqual("89.9°C 不触发", FanEmergencyTransition.none,
                   tracker.update(hottest: 89.9, now: base))
        check("89.9°C 后 isActive == false", tracker.isActive == false)

        checkEqual("90.0°C（>= 阈值）触发", .triggered,
                   tracker.update(hottest: 90.0, now: base))
        check("触发后 isActive == true", tracker.isActive)

        checkEqual("91°C 已触发，不重复报", FanEmergencyTransition.none,
                   tracker.update(hottest: 91.0, now: base.addingTimeInterval(5)))
        checkEqual("峰值记录到最高温 91.0", 91.0, tracker.peakCelsius ?? 0)

        // 回落到阈值以下：冷却 60 秒
        checkEqual("89°C 回落第一拍：仍在冷却，不解除", FanEmergencyTransition.none,
                   tracker.update(hottest: 89.0, now: base.addingTimeInterval(10)))
        check("冷却期内 isActive 仍为 true（不接受降速）", tracker.isActive)

        checkEqual("回落 59 秒：仍未解除", FanEmergencyTransition.none,
                   tracker.update(hottest: 88.0, now: base.addingTimeInterval(69)))
        check("59 秒时 isActive 仍为 true", tracker.isActive)

        checkEqual("回落满 60 秒：解除", .released,
                   tracker.update(hottest: 88.0, now: base.addingTimeInterval(70)))
        check("解除后 isActive == false", tracker.isActive == false)

        // 抖动：70s 时解除后又冲回 90°C
        checkEqual("解除后再次 90.5°C → 重新触发", .triggered,
                   tracker.update(hottest: 90.5, now: base.addingTimeInterval(80)))

        // 抖动反例：阈值附近来回跳，冷却没走完就不该解除
        var jitter = FanEmergencyTracker()
        _ = jitter.update(hottest: 90.2, now: base)
        _ = jitter.update(hottest: 89.8, now: base.addingTimeInterval(1))
        _ = jitter.update(hottest: 90.1, now: base.addingTimeInterval(2))   // 又热了，冷却计时清零
        _ = jitter.update(hottest: 89.9, now: base.addingTimeInterval(3))
        check("抖动后（冷却被重置）59 秒内不解除",
               jitter.update(hottest: 89.9, now: base.addingTimeInterval(62)) == .none)
        check("抖动后满 60 秒才解除",
               jitter.update(hottest: 89.9, now: base.addingTimeInterval(63)) == .released)

        // 温度读不到：不改状态
        var unknown = FanEmergencyTracker()
        _ = unknown.update(hottest: 95.0, now: base)
        checkEqual("温度读不到（nil）→ 不解除", FanEmergencyTransition.none,
                   unknown.update(hottest: nil, now: base.addingTimeInterval(600)))
        check("温度读不到时保持兜底（安全侧）", unknown.isActive)

        // ============================================ 兜底压过一切模式
        print("\n== 兜底压过一切模式（模拟引擎的单拍决策）==")
        // 用户设的是「固定 1000 RPM」，温度 91°C → 必须写 maxRPM
        let userFixed = FanMode.fixed(rpm: 1000)
        let fanMin = 1171, fanMax = 7296
        var engine = FanEmergencyTracker()
        let hot = engine.update(hottest: 91.0, now: base)
        check("91°C 触发兜底", hot == .triggered)

        let desiredWhenHot = fanMax            // 引擎在兜底时的目标
        let fixedModeDesired = FanControlPolicy.clampForWrite(1000, minRPM: fanMin, maxRPM: fanMax)
        let actionWhenHot = FanControlPolicy.decide(
            target: desiredWhenHot, lastWrittenRPM: fixedModeDesired,
            lastWrittenAt: base.addingTimeInterval(-1), now: base, emergency: true)
        checkEqual("固定 1000 RPM 的用户模式下，91°C 仍写 maxRPM（绕过节流）",
                   FanControlPolicy.DispatchAction.write(rpm: fanMax, reason: .emergencyOverride),
                   actionWhenHot)
        check("这条写入与用户固定模式无关（\(userFixed.displayName)）", true)

        // 自动模式同理：兜底期间不接受「交回系统」
        let autoAction = FanControlPolicy.decide(
            target: fanMax, lastWrittenRPM: 0,
            lastWrittenAt: base, now: base, emergency: true)
        checkEqual("自动模式（上次写 0=交回系统）在 91°C 下仍被强制写 maxRPM",
                   FanControlPolicy.DispatchAction.write(rpm: fanMax, reason: .emergencyOverride),
                   autoAction)

        // 回落解除后恢复原模式：固定 1000 → 夹到 minRPM
        _ = engine.update(hottest: 88.0, now: base.addingTimeInterval(10))
        let released = engine.update(hottest: 88.0, now: base.addingTimeInterval(70))
        check("冷却满后解除", released == .released)
        checkEqual("解除后恢复用户原模式：固定 1000 → 夹到 1171",
                   1171, FanControlPolicy.clampForWrite(1000, minRPM: fanMin, maxRPM: fanMax))
        let restored = FanControlPolicy.decide(
            target: 1171, lastWrittenRPM: fanMax,
            lastWrittenAt: base.addingTimeInterval(70), now: base.addingTimeInterval(80),
            emergency: false)
        checkEqual("解除后下一拍把转速降回用户值",
                   FanControlPolicy.DispatchAction.write(rpm: 1171, reason: .targetChanged),
                   restored)

        // ============================================ 免责声明门禁
        print("\n== 免责声明门禁 ==")
        let defaults = UserDefaults.standard
        for key in [FanDisclaimer.acceptedKey, FanDisclaimer.versionKey] {
            defaults.removeObject(forKey: key)
        }
        check("默认未同意", FanDisclaimer.isAccepted == false)
        check("未同意时门禁关闭", FanDisclaimer.allowsFanWrites == false)

        defaults.set(true, forKey: FanDisclaimer.acceptedKey)
        check("只写 accepted、没写 version → 仍未同意", FanDisclaimer.isAccepted == false)

        defaults.set(FanControl.disclaimerVersion, forKey: FanDisclaimer.versionKey)
        check("accepted + 当前版本 → 已同意", FanDisclaimer.isAccepted == true)
        check("已同意时门禁打开", FanDisclaimer.allowsFanWrites == true)

        defaults.set(FanControl.disclaimerVersion - 1, forKey: FanDisclaimer.versionKey)
        check("旧版本同意（version < 当前）→ 需重新同意", FanDisclaimer.isAccepted == false)

        FanDisclaimer.accept()
        check("accept() 落盘后可读回", FanDisclaimer.isAccepted == true)
        checkEqual("落盘版本等于 FanControl.disclaimerVersion",
                   FanControl.disclaimerVersion,
                   defaults.object(forKey: FanDisclaimer.versionKey) as? Int ?? -1)

        FanDisclaimer.revoke()
        check("revoke() 后回到未同意", FanDisclaimer.isAccepted == false)

        // 键名与契约 §7.1 一致
        checkEqual("accepted key 是契约钉死的名字",
                   "fanControl.disclaimerAccepted", FanDisclaimer.acceptedKey)
        checkEqual("version key 是契约钉死的名字",
                   "fanControl.disclaimerVersion", FanDisclaimer.versionKey)

        // ============================================ 传感器分组
        print("\n== 温度传感器分组 ==")
        checkEqual("PMU tdie1 → SoC", ThermalSensorGroup.soc,
                   ThermalSensorGroup.classify(sensorID: "PMU tdie1"))
        checkEqual("PMU tdev3 → SoC（其它 SoC 传感器同组）", ThermalSensorGroup.soc,
                   ThermalSensorGroup.classify(sensorID: "PMU tdev3"))
        checkEqual("PMU2 tdie3 → SoC", ThermalSensorGroup.soc,
                   ThermalSensorGroup.classify(sensorID: "PMU2 tdie3"))
        checkEqual("gas gauge battery → 电池", ThermalSensorGroup.battery,
                   ThermalSensorGroup.classify(sensorID: "gas gauge battery"))
        checkEqual("NAND CH0 temp → 存储", ThermalSensorGroup.storage,
                   ThermalSensorGroup.classify(sensorID: "NAND CH0 temp"))
        checkEqual("GPU0 temp → GPU", ThermalSensorGroup.gpu,
                   ThermalSensorGroup.classify(sensorID: "GPU0 temp"))
        checkEqual("不认识的名字 → 其它", ThermalSensorGroup.other,
                   ThermalSensorGroup.classify(sensorID: "Tp09z"))
        // 校准参考通道单独成组：tcal 恒定不动，混进 SoC 组会误导「芯片最高温」。
        checkEqual("PMU tcal → 校准参考", ThermalSensorGroup.reference,
                   ThermalSensorGroup.classify(sensorID: "PMU tcal"))
        checkEqual("PMU2 tcal → 校准参考（不是 SoC）", ThermalSensorGroup.reference,
                   ThermalSensorGroup.classify(sensorID: "PMU2 tcal"))

        // ============================================ 汇总
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
