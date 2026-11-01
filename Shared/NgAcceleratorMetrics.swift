//
//  NgAcceleratorMetrics.swift
//  Deep Sleep
//
//  GPU / NPU 使用率的纯数据层：模型 + 解码 + 状态判定。
//
//  **只 import Foundation** —— 这个文件同时编进主 App 与特权助手，
//  任何 IOKit 依赖都会把助手 target 拖下水。真正读 IOKit 的代码在
//  `DeepSleep/Core/NgAcceleratorReader.swift`（只在 App target 里）。
//
//  数据来源（本机实测记录见 `docs/notes.md` 的 v1.11.1 一节）：
//   - GPU：IOKit 里 `IOAccelerator` 服务的 `PerformanceStatistics` 属性，
//     里面有 "Device Utilization %" / "Renderer Utilization %" /
//     "Tiler Utilization %" 三个计数器。普通用户进程就能读，不需要特权助手。
//   - NPU：macOS 没有把 Apple Neural Engine 的使用率暴露给应用。
//     整棵 IORegistry 里找不到 ANE 设备节点（`IOANEDevice` / `AppleANE`
//     都没有），也没有任何可用的使用率计数器 → 读不到。
//
//  规矩跟仓库其它地方一致：**读不到就是 nil**，界面上显示「不可用」并说明
//  原因，不拿 0 冒充。
//

import Foundation

// MARK: - NPU 读不到的原因

/// NPU 使用率读不到时的原因。
///
/// 界面上要按这个说人话：光写「不可用」用户没法判断是系统不支持、
/// 还是这台机器的读数出不来。
public enum NgNPUUnavailableReason: String, Sendable, Equatable {
    /// 系统的 IORegistry 里没有 ANE（Apple Neural Engine）设备节点。
    /// macOS 27.2 / Apple M2 上实测就是这样。
    case noANEDevice
    /// 有 ANE 节点，但节点里没有暴露使用率计数器。
    case noUtilizationCounter
}

// MARK: - 采样

/// 一次加速器（GPU / NPU）使用率采样。
///
/// 字段一律是可选的：**nil = 读不到**，不是 0。
public struct NgAcceleratorSample: Sendable, Equatable {

    /// GPU 设备占用百分比（0–100）。读不到为 nil。
    public let gpuDevicePercent: Double?
    /// GPU 渲染器占用百分比（0–100）。读不到为 nil。
    public let gpuRendererPercent: Double?
    /// GPU 分块（tiler）占用百分比（0–100）。读不到为 nil。
    public let gpuTilerPercent: Double?
    /// NPU 使用率（0–100）。macOS 没有公开这个计数器，恒为 nil。
    public let npuPercent: Double?
    /// NPU 读不到的原因。`npuPercent` 非 nil 时为 nil。
    public let npuUnavailableReason: NgNPUUnavailableReason?
    /// 采样时刻（unix epoch seconds）。
    public let timestamp: TimeInterval

    public init(gpuDevicePercent: Double? = nil,
                gpuRendererPercent: Double? = nil,
                gpuTilerPercent: Double? = nil,
                npuPercent: Double? = nil,
                npuUnavailableReason: NgNPUUnavailableReason? = nil,
                timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.gpuDevicePercent = gpuDevicePercent
        self.gpuRendererPercent = gpuRendererPercent
        self.gpuTilerPercent = gpuTilerPercent
        self.npuPercent = npuPercent
        self.npuUnavailableReason = npuPercent == nil ? npuUnavailableReason : nil
        self.timestamp = timestamp
    }

    /// GPU 三个计数器里任意一个有读数就算「这次采到了 GPU」。
    public var hasGPUReading: Bool {
        gpuDevicePercent != nil || gpuRendererPercent != nil || gpuTilerPercent != nil
    }

    /// NPU 有没有读到数。
    public var hasNPUReading: Bool { npuPercent != nil }
}

// MARK: - 解码

/// GPU 性能计数器的解码。
public enum NgAcceleratorDecoder {

    /// `PerformanceStatistics` 里的键名（本机实测，见 `docs/notes.md` v1.11.1）。
    public static let deviceUtilizationKey = "Device Utilization %"
    public static let rendererUtilizationKey = "Renderer Utilization %"
    public static let tilerUtilizationKey = "Tiler Utilization %"

    /// 从 `PerformanceStatistics` 的原始键值对解出一次采样。
    ///
    /// 传入的是原始字符串值（采集层把 IOKit 的数字转成文本再交过来），
    /// 这样解码这一层不依赖任何 IOKit 类型，可以脱离 App 单独测。
    public static func decodeStatistics(
        _ statistics: [String: String],
        npuPercent: Double? = nil,
        npuUnavailableReason: NgNPUUnavailableReason? = nil,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> NgAcceleratorSample {
        NgAcceleratorSample(
            gpuDevicePercent: percent(from: statistics[deviceUtilizationKey]),
            gpuRendererPercent: percent(from: statistics[rendererUtilizationKey]),
            gpuTilerPercent: percent(from: statistics[tilerUtilizationKey]),
            npuPercent: npuPercent,
            npuUnavailableReason: npuUnavailableReason,
            timestamp: timestamp
        )
    }

    /// 把原始值解析成 0–100 的百分比。
    ///
    /// 解析不出来一律返回 nil：不是数字、不是有限数、落在 0–100 之外，
    /// 都算「读不到」。**不能把解析失败当成 0** —— 「GPU 真的空着」和
    /// 「没读到 GPU 计数器」在界面上必须能区分。
    public static func percent(from raw: String?) -> Double? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed) else { return nil }
        guard value.isFinite, value >= 0, value <= 100 else { return nil }
        return value
    }
}
