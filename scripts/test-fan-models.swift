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

        // MARK: - 校准参考通道（tcal）

        // 本机实测：`PMU tcal` / `PMU2 tcal` 恒定 51.85°C，长期不动。
        // 它们参与取最高会把「最高温度」钉死，界面看起来像不刷新。
        let withReference = TemperatureSnapshot(readings: [
            TemperatureSnapshot.Reading(sensorID: "PMU tcal", celsius: 51.85),
            TemperatureSnapshot.Reading(sensorID: "PMU2 tcal", celsius: 51.85),
            TemperatureSnapshot.Reading(sensorID: "PMU tdie1", celsius: 46.21)
        ])
        check("tcal 被识别为校准参考", TemperatureSnapshot.isReferenceSensor("PMU tcal"))
        check("PMU2 tcal 也被识别", TemperatureSnapshot.isReferenceSensor("PMU2 tcal"))
        check("普通传感器不是校准参考", !TemperatureSnapshot.isReferenceSensor("PMU tdie1"))
        checkEqual("最高温排除 tcal", withReference.maxCelsius ?? -1, 46.21)
        checkEqual("liveReadings 只留真实传感器", withReference.liveReadings.count, 1)

        let referenceOverThreshold = TemperatureSnapshot(readings: [
            TemperatureSnapshot.Reading(sensorID: "PMU tcal", celsius: 95.0),
            TemperatureSnapshot.Reading(sensorID: "PMU tdie1", celsius: 46.0)
        ])
        check("校准参考超阈不触发兜底", !referenceOverThreshold.triggersEmergency)

        let onlyReference = TemperatureSnapshot(readings: [
            TemperatureSnapshot.Reading(sensorID: "PMU tcal", celsius: 51.85)
        ])
        check("只有校准参考时没有最高温", onlyReference.maxCelsius == nil)

        // MARK: - 同名通道合并

        // 本机实测 `gas gauge battery` 一次来 6 条（31.0 ×4、29.6、29.0）。
        let duplicated = TemperatureSnapshot(readings: [
            TemperatureSnapshot.Reading(sensorID: "gas gauge battery", celsius: 31.0),
            TemperatureSnapshot.Reading(sensorID: "gas gauge battery", celsius: 29.6),
            TemperatureSnapshot.Reading(sensorID: "gas gauge battery", celsius: 29.0),
            TemperatureSnapshot.Reading(sensorID: "gas gauge battery", celsius: 30.4),
            TemperatureSnapshot.Reading(sensorID: "PMU tdie1", celsius: 46.2)
        ], timestamp: 1_700_000_002)
        let merged = duplicated.mergingDuplicates()
        checkEqual("合并后只剩两路", merged.readings.count, 2)
        checkEqual("同名取最大值", merged.readings[0].celsius, 31.0)
        checkEqual("合并保留原顺序", merged.readings[0].sensorID, "gas gauge battery")
        checkEqual("合并保留时间戳", merged.timestamp, 1_700_000_002)
        checkEqual("没有重复名的快照合并不变", withReference.mergingDuplicates().readings.count, 3)

        // 带通道数的版本：界面要标「N 通道」。
        let withCounts = duplicated.mergingDuplicatesWithCounts()
        checkEqual("合并后读数条数", withCounts.readings.count, 2)
        checkEqual("电池通道数是 4", withCounts.channelCounts["gas gauge battery"] ?? -1, 4)
        checkEqual("单路传感器通道数是 1", withCounts.channelCounts["PMU tdie1"] ?? -1, 1)
        checkEqual("没有重复名时通道数不变", withReference.mergingDuplicatesWithCounts().channelCounts["PMU tcal"], 1)

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
