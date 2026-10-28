//
//  ThermalMonitor.swift
//  Deep Sleep
//
//  温度采集：周期性向助手要一份 IOHID 温度快照，按类别分组后提供给界面与风扇引擎。
//
//  为什么温度也走助手（任务简报的决定，与契约 §3 的表述不同，见报告 assumptions）：
//  温度本身不需要 root，但为了和助手侧的 90°C 紧急兜底保持**同一数据源**，
//  也避免应用侧再实现一遍 IOHID 私有事件通道，统一走 `getTemperatureSnapshot`。
//  助手不可用或版本过旧时静默降级成「温度不可用」，不弹错、不刷日志。
//
//  这一层只负责「读温度 + 分组 + 判阈值」，**不维护**紧急状态的冷却计时 ——
//  兜底状态机只有一处（FanController 的 FanEmergencyTracker），两处各算一遍
//  迟早会算出两个不一样的结论。
//

import Foundation
import Combine

// MARK: - 传感器分组

/// 温度传感器的分组。
///
/// 分组依据是对本机实测 Product 名的模式匹配（"PMU tdie1"、"PMU tdev3"、
/// "gas gauge battery"、"NAND CH0 temp" 这些）。SMC/IOHID 没有类别字段，
/// 只能按名字归类 —— 归类错顶多是显示位置不对，不影响判定。
enum ThermalSensorGroup: String, CaseIterable, Identifiable {
    /// SoC / 芯片（tdie、tdev、PMU2 都算这里）
    case soc
    case gpu
    case battery
    case storage
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .soc:     return "SoC"
        case .gpu:     return "GPU"
        case .battery: return "电池"
        case .storage: return "存储"
        case .other:   return "其它"
        }
    }

    /// 按传感器名归类。
    ///
    /// 判定顺序有讲究：先看最具体的（gas gauge / NAND / GPU），再看芯片类，
    /// 最后落到其它。否则 "gas gauge battery" 之类会被更宽的模式吸走。
    static func classify(sensorID: String) -> ThermalSensorGroup {
        let name = sensorID.lowercased()
        if name.contains("gas gauge") { return .battery }
        if name.contains("nand") { return .storage }
        if name.contains("gpu") { return .gpu }
        // PMU2 是电源管理单元，温度本质还是 SoC 侧硅片温度，归 SoC 组。
        if name.contains("pmu2") { return .soc }
        if name.contains("tdie") { return .soc }
        if name.contains("tdev") { return .soc }
        return .other
    }
}

/// 一条带分组的温度读数（界面直接用）。
struct GroupedTemperatureReading: Identifiable, Equatable {
    let sensorID: String
    let celsius: Double
    let group: ThermalSensorGroup

    var id: String { sensorID }

    /// 是否达到 90°C 兜底线（界面高亮用）。
    var isOverEmergencyThreshold: Bool {
        celsius >= FanControl.emergencyTemperatureCelsius
    }
}

// MARK: - 温度监控

/// 温度监控。默认 10 秒一拍（温度是秒级缓变），单例。
@MainActor
final class ThermalMonitor: ObservableObject {

    static let shared = ThermalMonitor()

    /// 采集周期（秒）。10 秒足够：温度是秒级缓变，而写 SMC 的风扇控制循环
    /// 有自己更密的 5 秒心跳，不需要温度也 5 秒读一次。
    static let refreshInterval: TimeInterval = 10

    // MARK: 对外状态

    /// 最近一次快照。读不到时为 nil。
    @Published private(set) var currentSnapshot: TemperatureSnapshot?
    /// 按类别分好组的读数（每组按温度从高到低）。
    @Published private(set) var groupedReadings: [ThermalSensorGroup: [GroupedTemperatureReading]] = [:]
    /// 最高温读数。没有任何读数时为 nil。
    @Published private(set) var hottestCelsius: Double?
    /// 是否任意一个传感器达到 90°C 兜底线（原始判定，不含冷却）。
    @Published private(set) var isOverEmergencyThreshold = false
    /// 温度是否可用。false 时界面显示「温度不可用」，不显示 0°C。
    @Published private(set) var isAvailable = false
    /// 最近一次成功读取的时刻。
    @Published private(set) var lastUpdatedAt: Date?

    // MARK: 内部状态

    private let queue = DispatchQueue(label: "com.skyc8266.deepsleep.thermal")
    private var timer: DispatchSourceTimer?
    /// 助手不认识温度命令（旧版本）。置位后停止轮询，不再打助手。
    private var helperLacksCommand = false
    /// 助手不可用只记一次日志，不刷屏。
    private var didLogUnavailable = false

    private init() {}

    /// 最近一次快照的便捷别名（FanController 用）。
    var latestSnapshot: TemperatureSnapshot? { currentSnapshot }

    // MARK: - 生命周期

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: Self.refreshInterval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - 采集

    /// 立刻读一次。失败时保持上一次快照（不清空 —— 界面没必要因为一次抖动闪成「不可用」）。
    func refresh() async {
        guard !helperLacksCommand else { return }
        do {
            let response = try await HelperClient.shared.send(
                .init(command: .getTemperatureSnapshot), timeout: 6)
            guard response.success else {
                if response.message.localizedCaseInsensitiveContains("unknown command") {
                    helperLacksCommand = true
                    isAvailable = false
                    NSLog("[DeepSleep] 助手不支持温度命令（旧版本），温度监控已降级")
                    stop()
                } else {
                    NSLog("[DeepSleep] 读取温度失败：%@", response.message)
                }
                return
            }
            apply(TemperatureSnapshot.decode(response.payload))
        } catch {
            if !didLogUnavailable {
                didLogUnavailable = true
                NSLog("[DeepSleep] 温度监控暂不可用（助手不可达）：%@", error.localizedDescription)
            }
            isAvailable = false
        }
    }

    /// 把一份快照灌进对外状态。
    private func apply(_ snapshot: TemperatureSnapshot) {
        // 空快照 = 这一拍没读到，按「不可用」处理，但保留上一次的数据供界面显示。
        guard !snapshot.readings.isEmpty else {
            isAvailable = false
            return
        }

        didLogUnavailable = false
        currentSnapshot = snapshot
        isAvailable = true
        lastUpdatedAt = Date()

        var grouped: [ThermalSensorGroup: [GroupedTemperatureReading]] = [:]
        for reading in snapshot.readings {
            let group = ThermalSensorGroup.classify(sensorID: reading.sensorID)
            grouped[group, default: []].append(GroupedTemperatureReading(
                sensorID: reading.sensorID,
                celsius: reading.celsius,
                group: group))
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.celsius > $1.celsius }
        }
        groupedReadings = grouped

        let hottest = snapshot.maxCelsius
        hottestCelsius = hottest
        isOverEmergencyThreshold = snapshot.triggersEmergency
    }
}
