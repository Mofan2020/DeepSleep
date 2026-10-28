//
//  test-fan-models.swift
//  DeepSleep
//
//  FanState / TemperatureSnapshot 的编解码往返自测。
//  测的是真实源码 Shared/FanModels.swift。
//
//  为什么这层要单独测：编解码是「应用 ↔ 助手」之间的契约。
//  一旦编码格式变了而解码没跟上，表现是**静默错误** ——
//  风扇状态解析出来全是 0，看起来像「硬件没风扇」而不是「协议漂了」。
//
//  运行： bash scripts/test-fan-models.sh
//

import Foundation

@main
struct FanModelsTests {

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

        // MARK: - FanState 往返

        print("\n== FanState 往返 ==")

        let fans = [
            FanState.Fan(index: 0, name: "Left side", currentRPM: 2400,
                         minRPM: 1171, maxRPM: 7296, isManual: false),
            FanState.Fan(index: 1, name: "右侧风扇", currentRPM: 1800,
                         minRPM: 1000, maxRPM: 5000, isManual: true)
        ]
        let original = FanState(fans: fans, timestamp: 1_700_000_000)
        let decoded = FanState.decode(original.encode())

        checkEqual("风扇数量", decoded.fans.count, 2)
        checkEqual("第 0 个风扇的序号", decoded.fans[0].index, 0)
        checkEqual("第 0 个风扇的转速", decoded.fans[0].currentRPM, 2400)
        checkEqual("第 0 个风扇的最低转速", decoded.fans[0].minRPM, 1171)
        checkEqual("第 0 个风扇的最高转速", decoded.fans[0].maxRPM, 7296)
        checkEqual("第 0 个风扇不是手动模式", decoded.fans[0].isManual, false)
        checkEqual("第 1 个风扇是手动模式", decoded.fans[1].isManual, true)
        checkEqual("中文名往返", decoded.fans[1].name, "右侧风扇")
        checkEqual("时间戳往返", decoded.timestamp, 1_700_000_000.0)

        // MARK: - 特殊字符

        print("\n== 特殊字符 ==")

        let tricky = FanState(fans: [
            FanState.Fan(index: 0, name: "风扇 | 号,含%百分号", currentRPM: 1,
                         minRPM: 2, maxRPM: 3, isManual: false)
        ], timestamp: 1)
        let trickyDecoded = FanState.decode(tricky.encode())
        checkEqual("分隔符与百分号往返", trickyDecoded.fans.first?.name ?? "", "风扇 | 号,含%百分号")

        let empty = FanState(fans: [], timestamp: 42)
        checkEqual("空风扇列表往返", FanState.decode(empty.encode()).fans.count, 0)

        // MARK: - writableFan

        print("\n== 可写风扇判定 ==")

        let good = FanState(fans: [
            FanState.Fan(index: 0, name: "F", currentRPM: 0, minRPM: 1000, maxRPM: 5000, isManual: false)
        ])
        check("区间正常的风扇可写", good.writableFan(at: 0) != nil)

        let badRange = FanState(fans: [
            FanState.Fan(index: 0, name: "F", currentRPM: 0, minRPM: 5000, maxRPM: 1000, isManual: false)
        ])
        check("min > max 的风扇不可写", badRange.writableFan(at: 0) == nil)

        let zeroRange = FanState(fans: [
            FanState.Fan(index: 0, name: "F", currentRPM: 0, minRPM: 0, maxRPM: 0, isManual: false)
        ])
        check("区间全 0 的风扇不可写", zeroRange.writableFan(at: 0) == nil)

        check("不存在的序号不可写", good.writableFan(at: 5) == nil)

        // MARK: - TemperatureSnapshot 往返

        print("\n== TemperatureSnapshot 往返 ==")

        let snapshot = TemperatureSnapshot(readings: [
            TemperatureSnapshot.Reading(sensorID: "PMU tdie1", celsius: 46.87),
            TemperatureSnapshot.Reading(sensorID: "gas gauge battery", celsius: 31.0),
            TemperatureSnapshot.Reading(sensorID: "NAND CH0 temp", celsius: -1.59),
            TemperatureSnapshot.Reading(sensorID: "中文 传感器", celsius: 0.0)
        ], timestamp: 1_700_000_001)

        let snapDecoded = TemperatureSnapshot.decode(snapshot.encode())
        checkEqual("读数条数", snapDecoded.readings.count, 4)
        checkEqual("第一个传感器名", snapDecoded.readings[0].sensorID, "PMU tdie1")
        checkEqual("第一个读数", snapDecoded.readings[0].celsius, 46.87)
        checkEqual("负温度往返", snapDecoded.readings[2].celsius, -1.59)
        checkEqual("0 度不是缺失", snapDecoded.readings[3].celsius, 0.0)
        checkEqual("中文传感器名往返", snapDecoded.readings[3].sensorID, "中文 传感器")
        checkEqual("最高温", snapDecoded.maxCelsius ?? -999, 46.87)

        let emptySnapshot = TemperatureSnapshot(readings: [], timestamp: 1)
        checkEqual("空读数列表往返", TemperatureSnapshot.decode(emptySnapshot.encode()).readings.count, 0)
        check("空快照没有最高温", emptySnapshot.maxCelsius == nil)

        // MARK: - 紧急兜底判定

        print("\n== 90°C 紧急兜底判定 ==")

        checkEqual("阈值就是 90", FanControl.emergencyTemperatureCelsius, 90.0)

        let below = TemperatureSnapshot(readings: [
            TemperatureSnapshot.Reading(sensorID: "A", celsius: 89.99)
        ])
        check("89.99 度不触发", !below.triggersEmergency)

        let at = TemperatureSnapshot(readings: [
            TemperatureSnapshot.Reading(sensorID: "A", celsius: 90.0)
        ])
        check("正好 90 度触发", at.triggersEmergency)

        let above = TemperatureSnapshot(readings: [
            TemperatureSnapshot.Reading(sensorID: "A", celsius: 40.0),
            TemperatureSnapshot.Reading(sensorID: "B", celsius: 95.5)
        ])
        check("任意一个传感器超阈就触发（不必是第一个）", above.triggersEmergency)

        let noReading = TemperatureSnapshot(readings: [])
        check("没有读数不触发", !noReading.triggersEmergency)

        // MARK: - 租约常量

        print("\n== 租约常量 ==")

        check("租约 15 秒", FanControl.leaseSeconds == 15)
        check("心跳 5 秒", FanControl.heartbeatSeconds == 5)
        check("心跳周期短于租约", FanControl.heartbeatSeconds < FanControl.leaseSeconds)
        checkEqual("最低转速安全系数", FanControl.minRpmSafetyRatio, 0.95)
        checkEqual("紧急冷却 60 秒", FanControl.emergencyCooldownSeconds, 60.0)
        checkEqual("免责声明版本", FanControl.disclaimerVersion, 1)

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
