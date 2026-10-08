//
//  CPUTemperatureSample.swift
//  Deep Sleep
//
//  CPU 温度读数的数据模型与编解码。**应用与特权助手编译同一份。**
//
// 数据来源:helper 通过 Apple SMC IOKit 读以下 key(算法借鉴自 iSMC,
// 本文件是纯数据层,无 IOKit 依赖):
//   - TCMz  CPU Die Max       (Platform: "Apple",M1+/M2/M3/M4 都标)
//   - TCMb  CPU Die Average   (同上)
//   - TCDX  CPU Die Aggregate (同上)
//
// 在 Apple Silicon 上这三个键由 macOS 直接报告 CPU Die 温度,
// 数值已经按 fp88 / sp78 等格式归一化到 °C。M2 上具体走哪种类型由
// firmware 决定 —— helper 端统一处理,本文件只负责把 helper 给的浮点数
// 走编码通道送到应用侧。
//
// 设计取舍:不走 JSON / 不嵌套对象 —— 与 ProcessStats 的「百分号编码 +
// 字段间 `|`,记录间 `,`」同一通道,理由相同:helper 与应用各自只依赖
// Foundation,不需要 JSON 解析器参与关键路径。
//
// 任一字段缺失 = helper 读不到(键不存在 / 类型不认识 / 数值出合理性窗口)。
// 应用侧不要把缺失当作 0,要当作「这次没数据」。
//

import Foundation

public struct CPUTemperatureSample: Sendable, Equatable {

    /// CPU Die Max(°C);读不到为 nil。
    public let maxC: Double?
    /// CPU Die Average(°C);读不到为 nil。
    public let averageC: Double?
    /// CPU Die Aggregate(°C);读不到为 nil。
    public let aggregateC: Double?
    /// 读取时刻(unix epoch seconds)。
    public let timestamp: TimeInterval

    public init(maxC: Double?, averageC: Double?, aggregateC: Double?,
                timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.maxC = maxC
        self.averageC = averageC
        self.aggregateC = aggregateC
        self.timestamp = timestamp
    }

    /// 三个里任意一个有效读数都算「这次采样有效」。
    public var hasAnyReading: Bool {
        maxC != nil || averageC != nil || aggregateC != nil
    }

    // MARK: - 编解码

    public func encode() -> [String: String] {
        var payload: [String: String] = [
            "timestamp": String(timestamp),
        ]
        if let maxC { payload["max"] = String(format: "%.2f", maxC) }
        if let averageC { payload["average"] = String(format: "%.2f", averageC) }
        if let aggregateC { payload["aggregate"] = String(format: "%.2f", aggregateC) }
        return payload
    }

    public static func decode(_ payload: [String: String]) -> CPUTemperatureSample {
        let maxC = payload["max"].flatMap { Double($0) }
        let averageC = payload["average"].flatMap { Double($0) }
        let aggregateC = payload["aggregate"].flatMap { Double($0) }
        let timestamp = payload["timestamp"].flatMap { TimeInterval($0) }
            ?? Date().timeIntervalSince1970
        return CPUTemperatureSample(
            maxC: maxC,
            averageC: averageC,
            aggregateC: aggregateC,
            timestamp: timestamp
        )
    }
}
