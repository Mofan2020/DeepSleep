//
//  NgAcceleratorReader.swift
//  Deep Sleep
//
//  GPU / NPU 使用率的本机读取（IOKit）。
//
//  为什么不用特权助手：GPU 使用率来自 IORegistry 里 `IOAccelerator` 服务的
//  `PerformanceStatistics` 属性，**普通用户进程就能读**（本机实测 uid 501
//  读得到）。走助手反而要求用户先装上新版助手才能看到这一格 —— 一个
//  不需要提权的数据，不该被提权通道卡住。
//
//  NPU：macOS 没有把 Apple Neural Engine 的使用率暴露出来。整棵 IORegistry
//  里没有 ANE 设备节点 → 读不到，界面上如实写「不可用」并说明原因。
//  （`powermetrics` 确实会报 ANE 的**功耗**，但那要 root，而且报的是功耗
//  不是使用率，所以不作为数据来源。）
//
//  解码与状态判定在 `Shared/NgAcceleratorMetrics.swift`（纯逻辑，可单测）。
//

import Foundation
import IOKit

/// GPU / NPU 使用率的本机采集。
enum NgAcceleratorReader {

    /// 读一次 GPU / NPU 使用率。任何一项读不到就是 nil，不填 0。
    static func read() -> NgAcceleratorSample {
        let npu = readNPU()
        return NgAcceleratorDecoder.decodeStatistics(
            readGPUStatistics(),
            npuPercent: npu.percent,
            npuUnavailableReason: npu.reason
        )
    }

    // MARK: - GPU

    /// `IOAccelerator` 服务的 `PerformanceStatistics` 属性，转成字符串键值对。
    ///
    /// 集显机器上这个服务只有一个；取到第一个带 `PerformanceStatistics`
    /// 的就够。有独立显卡的机器上可能有多个，这里仍只取第一个 ——
    /// 界面展示的是「GPU 使用率」一个数，不是每张卡一行。
    private static func readGPUStatistics() -> [String: String] {
        var result: [String: String] = [:]
        guard let matching = IOServiceMatching("IOAccelerator") else { return result }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iter) }

        while true {
            let entry = IOIteratorNext(iter)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }

            guard let stats = property(entry, "PerformanceStatistics") as? [String: Any] else {
                continue
            }
            for (key, value) in stats {
                result[key] = describe(value)
            }
            break
        }
        return result
    }

    // MARK: - NPU

    private struct NPUReading {
        let percent: Double?
        let reason: NgNPUUnavailableReason?
    }

    /// 找 ANE（Apple Neural Engine）设备节点。
    ///
    /// macOS 27.2 / Apple M2 上实测：这三个类名一个都没有命中，
    /// 整棵 IOService 树里也搜不到任何带 ANE / NEURAL 的节点。
    private static let aneClassNames = ["IOANEDevice", "AppleANE", "AppleANEDevice"]

    private static func readNPU() -> NPUReading {
        for className in aneClassNames {
            guard let entry = firstService(class: className) else { continue }
            defer { IOObjectRelease(entry) }

            // 有 ANE 节点：看看里面有没有使用率计数器。
            if let percent = utilizationPercent(in: allProperties(entry)) {
                return NPUReading(percent: percent, reason: nil)
            }
            return NPUReading(percent: nil, reason: .noUtilizationCounter)
        }
        return NPUReading(percent: nil, reason: .noANEDevice)
    }

    /// 在节点属性里找名字带「Utilization」/「Usage」的数字计数器。
    private static func utilizationPercent(in properties: [String: Any]) -> Double? {
        for (key, value) in properties {
            let upper = key.uppercased()
            guard upper.contains("UTILIZATION") || upper.contains("USAGE") else { continue }
            guard let number = value as? NSNumber else { continue }
            if let percent = NgAcceleratorDecoder.percent(from: number.stringValue) {
                return percent
            }
        }
        return nil
    }

    // MARK: - IOKit 小工具

    /// 读单个属性。读不到返回 nil。
    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard let raw = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return raw.takeUnretainedValue()
    }

    /// 读全部属性。读不到返回空字典。
    private static func allProperties(_ entry: io_registry_entry_t) -> [String: Any] {
        var props: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let props else { return [:] }
        return props.takeUnretainedValue() as? [String: Any] ?? [:]
    }

    /// 第一个匹配该类的服务。没有就返回 nil。
    private static func firstService(class className: String) -> io_registry_entry_t? {
        guard let matching = IOServiceMatching(className) else { return nil }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }
        let entry = IOIteratorNext(iter)
        return entry == 0 ? nil : entry
    }

    /// 把 IOKit 里的值转成文本。
    ///
    /// 数字走 `NSNumber.stringValue`（得到 "33" 这种干净写法），
    /// 其它类型原样描述 —— 解码那一层会自己判断能不能当百分比用。
    private static func describe(_ value: Any) -> String {
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }
}
