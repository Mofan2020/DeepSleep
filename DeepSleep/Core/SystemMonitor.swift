//
//  SystemMonitor.swift
//  Deep Sleep
//
//  系统过载监控的采样循环与阈值判定：
//   - CPU% 持续超阈（whole-CPU 口径：100% = 全机所有核都跑满）
//   - RAM 总使用率持续超阈
//   - 单进程 RSS 一次性超阈值（不等持续时间，立刻报）
//
//  v1.4.0 早期还有「内存泄漏检测」分支；v1.4.1 起砍掉。
//

import Foundation
import Combine
import Darwin


/// 系统过载事件：累计 CPU / RAM 持续超阈。
public struct OverloadEvent: Sendable {
    public let ramPercent: Double
    public let totalCpuPercent: Double
    public let topThree: [ProcessStats.Record]
    public let timestamp: Date
}

/// 单进程占用超阈事件：RSS ≥ 用户设定的字节数。
public struct SingleProcessRAMEvent: Sendable {
    public let record: ProcessStats.Record
    public let thresholdBytes: Int
    public let timestamp: Date
}

/// CPU 温度超阈事件：Apple SMC 报的 Die Max / Average / Aggregate 三个读数中的
/// 最大值 ≥ 用户设定的 °C 阈值。
///
/// 实际取值逻辑：
///   - 三个读数都拿不到 → 不发事件(SMC 不可用)
///   - 三个里有任一 → 用「最大值」作判定基准,与 macOS 上「CPU 过热告警」
///     的口径一致（系统只看最热的那一项,不看平均）
public struct CPUTemperatureEvent: Sendable {
    public let maxC: Double?
    public let averageC: Double?
    public let aggregateC: Double?
    public let observedMaxC: Double
    public let thresholdC: Double
    public let timestamp: Date
}

/// SystemMonitor 把这些事件推给上层。
public enum MonitorEvent: Sendable {
    case overload(OverloadEvent)
    case singleProcessRAM(SingleProcessRAMEvent)
    case cpuTemp(CPUTemperatureEvent)
}

public final class SystemMonitor {

    public static let shared = SystemMonitor()

    // MARK: - 状态

    private let queue = DispatchQueue(label: "com.skyc8266.deepsleep.monitor")
    private var timer: DispatchSourceTimer?
    private var config: MonitorConfig
    /// 订阅 `ThermalMonitor` 的温度读数。
    ///
    /// **温度不再自己读** —— v1.7.2 那版走 SMC，在 Apple Silicon 上
    /// firmware 根本不回 key（实测 `dataSize = 0`），所以整条路是死的，
    /// 功能被下架。现在改用 IOHID 私有温度事件通道（助手侧
    /// `getTemperatureSnapshot`），`ThermalMonitor` 已经在那儿按 10 秒
    /// 一拍读着，这里订阅它的 `@Published` 就行。
    ///
    /// 用 Combine 订阅而不是直接读 `ThermalMonitor.shared.hottestCelsius`：
    /// `ThermalMonitor` 是 MainActor 上的单例，本类的 `tick()` 跑在自己的
    /// 串行队列上 —— 跨队列同步读 MainActor 状态有死锁风险。
    /// 订阅拿到的是「值变了」的回调，天然在 MainActor 上，不需要跨线程读。
    private var thermalSubscription: AnyCancellable?
    /// 当前 RAM%/CPU% 持续超过阈值的开始时间；为 nil 表示当前未在超阈。
    private var overloadStartedAt: Date?
    /// 已发出的过载事件 cooldown 起点；防止 4/24s 内连发两条同样的过载。
    private var lastOverloadReportAt: Date?
    /// 单进程 RSS 报警 cooldown：同一个 PID 5 分钟内最多报一次。
    private var singleRAMCooldown: [pid_t: Date] = [:]
    /// CPU 温度告警 cooldown：一次告警后 5 分钟内不再重复发。
    private var lastCPUTempReportAt: Date?
    /// 最近一次发出的事件（含时间戳）。UI 用它展示「最近事件」。
    /// 改了 MainActor 访问 + 串行队列写锁，UI 读不会卡。
    private var _lastEvent: MonitorEvent?
    private var _lastEventAt: Date?

    // MARK: - 实时快照（给 UI「系统状态」卡用）
    // 每次 tick 末尾更新。读端走 main-actor snapshot 函数。

    /// 内存累计使用百分比（0–100）。
    private var _latestRamPercent: Double = 0
    /// 全机 CPU 累计使用百分比（0–100，whole-CPU）。
    private var _latestCpuPercent: Double = 0
    /// 最近一次 SMC 读到的 CPU 温度（°C）。SMC 失败时为 nil。
    private var _latestCPUTempC: Double?
    /// 最近一次更新的时间戳。
    private var _latestUpdateAt: Date?
    /// 最近一次过载事件里 Top 3 进程名（CPU 占用）。
    private var _latestTopThree: [ProcessStats.Record] = []

    /// UI 用的「实时状态快照」。
    public struct LiveSnapshot: Sendable {
        public let ramPercent: Double
        public let cpuPercent: Double
        public let cpuTempC: Double?
        public let topThree: [ProcessStats.Record]
        public let updatedAt: Date

        public var isStale: Bool {
            Date().timeIntervalSince(updatedAt) > 30
        }
    }

    public var onEvent: ((MonitorEvent) -> Void)?

    public init(config: MonitorConfig = .default) {
        self.config = config
    }

    public func updateConfig(_ newConfig: MonitorConfig) {
        queue.async { [weak self] in
            guard let self else { return }
            self.config = newConfig
            if self.timer != nil, !newConfig.enabled {
                self.timer?.cancel()
                self.timer = nil
            } else if self.timer == nil, newConfig.enabled {
                self.startTimerLocked()
            }
        }
    }

    /// 最近一次事件的描述（UI 显示用）。空字符串表示「无」。
    public func lastEventDescription() -> (description: String, date: Date)? {
        queue.sync {
            guard let event = self._lastEvent, let at = self._lastEventAt else { return nil }
            return (Self.describe(event), at)
        }
    }

    /// 实时系统状态快照。UI 「系统状态」卡读这个，每秒 Tick。
    /// 内部走串行 queue 同步读，不会卡 UI。
    /// 监控未启用 / 还来不及采样的 → updatedAt 为 nil → isStale=true。
    public func liveSnapshot() -> LiveSnapshot {
        queue.sync {
            LiveSnapshot(
                ramPercent: _latestRamPercent,
                cpuPercent: _latestCpuPercent,
                cpuTempC: _latestCPUTempC,
                topThree: _latestTopThree,
                updatedAt: _latestUpdateAt ?? .distantPast
            )
        }
    }

    private static func describe(_ event: MonitorEvent) -> String {
        switch event {
        case .overload(let o):
            return "系统过载：RAM \(Int(o.ramPercent))% / CPU \(Int(o.totalCpuPercent))%"
        case .singleProcessRAM(let r):
            let gb = Double(r.record.rssBytes) / 1_073_741_824
            return String(format: "单进程过高：%@ (%.2f GB)", r.record.name, gb)
        case .cpuTemp(let t):
            return String(format: "CPU 温度过高：%.1f°C（阈值 %.0f°C）",
                          t.observedMaxC, t.thresholdC)
        }
    }

    public func start() {
        // 启动时从 UserDefaults 读持久化的 config（之前版本在这里丢：
        // UI 改了 enable 但 SystemMonitor 永远是 .default。）
        self.config = MonitorConfig.load()
        subscribeToThermal()
        queue.async { [weak self] in
            guard let self else { return }
            guard self.config.enabled else { return }
            guard self.timer == nil else { return }
            self.startTimerLocked()
        }
    }

    /// 订阅 `ThermalMonitor` 的读数变化，驱动 CPU 温度告警判定。
    ///
    /// `ThermalMonitor` 是 `@MainActor` 单例 —— 连**建立订阅**这一步都得在
    /// MainActor 上做（`$hottestCelsius` 是 MainActor 隔离的属性，
    /// 在非隔离上下文里读它编译不过）。
    ///
    /// 订阅回调本身也在 MainActor 上（`@Published` 的变化在主线程发出），
    /// 回调里把判定丢到自己的串行队列 —— `tick()` 也在那个队列上跑，
    /// 两边不会并发。
    ///
    /// `start()` 是从界面层调的（MainActor），但它本身不是 MainActor 隔离的
    /// （`SystemMonitor` 是个普通 final class，队列在后台）。所以这里用
    /// `Task { @MainActor in }` 把订阅的建立挪到主线程。
    private func subscribeToThermal() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.thermalSubscription = ThermalMonitor.shared.$hottestCelsius
                .sink { [weak self] celsius in
                    guard let self else { return }
                    self.queue.async { [weak self] in
                        self?.handleTemperature(celsius)
                    }
                }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
        }
    }

    // MARK: - 内部

    private func startTimerLocked() {
        let interval = max(1.0, config.sampleIntervalSeconds)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.tick()
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() async {
        let stats: ProcessStats
        do {
            stats = try await ProcessStatsProvider.shared.fetchStats()
        } catch {
            // 监控拿不到数据不算「过载」，下次再试。
            return
        }
        let records = stats.records

        let now = Date()

        // 单进程 RSS 一次性超阈（不等持续时间）
        let threshold = config.singleProcessRAMBytes
        if threshold > 0 {
            for record in records where Int(record.rssBytes) >= threshold {
                if let last = singleRAMCooldown[record.pid],
                   now.timeIntervalSince(last) < 300 { continue }
                singleRAMCooldown[record.pid] = now
                let event = SingleProcessRAMEvent(
                    record: record,
                    thresholdBytes: threshold,
                    timestamp: now)
                _lastEvent = .singleProcessRAM(event)
                _lastEventAt = now
                onEvent?(.singleProcessRAM(event))
            }
        }

        // 累计 CPU% 与 RAM% 持续超阈
        let totalRSS: UInt64 = records.reduce(0) { $0 + $1.rssBytes }
        // 整机 CPU 占用由助手用 host_statistics 单独给 —— 不能用各进程求和：
        // 内核时间不属于任何用户进程，求和会漏掉。
        let totalCPU: Double = stats.systemCpuPercent
        let physicalMemoryBytes = Self.physicalMemory()
        let ramPercent = physicalMemoryBytes > 0
            ? Double(totalRSS) / Double(physicalMemoryBytes) * 100
            : 0
        let isOverloaded = ramPercent >= config.ramHighPercent
            || totalCPU >= config.cpuHighPercent

        if isOverloaded {
            if overloadStartedAt == nil {
                overloadStartedAt = now
            }
            if let started = overloadStartedAt,
               now.timeIntervalSince(started) >= Double(config.highDurationSeconds),
               lastOverloadReportAt.map({ now.timeIntervalSince($0) >= 300 }) ?? true {
                let topThree = Array(records.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3))
                let event = OverloadEvent(ramPercent: ramPercent,
                                          totalCpuPercent: totalCPU,
                                          topThree: topThree,
                                          timestamp: now)
                lastOverloadReportAt = now
                overloadStartedAt = nil
                _lastEvent = .overload(event)
                _lastEventAt = now
                onEvent?(.overload(event))
            }
        } else {
            overloadStartedAt = nil
        }

        // CPU 温度超阈判定走 `handleTemperature` —— 由 `ThermalMonitor`
        // 的读数变化驱动，不在本 tick 里读温度。这里不再做节流计数。

        // 实时快照：CPU 温度在温度处理路径里更新；这里只填 RAM/CPU/Top3。
        _latestRamPercent = ramPercent
        _latestCpuPercent = totalCPU
        _latestTopThree = Array(records.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3))
        _latestUpdateAt = now
    }

    /// 处理一次温度读数：填缓存 + 超阈告警。
    ///
    /// 温度来源是 `ThermalMonitor`（助手侧 IOHID 私有温度事件通道）。
    /// **不再是 SMC** —— Apple Silicon 的 firmware 不回 SMC 温度 key
    /// （实测 `dataSize = 0`），那条路读出来永远是空的，v1.7.2 因此把
    /// 整个 CPU 温度功能下架了。
    ///
    /// 跑在自己的串行队列上（订阅回调投递过来的），与 `tick()` 互斥。
    private func handleTemperature(_ celsius: Double?) {
        guard config.cpuTempEnabled, config.cpuTempHighCelsius > 0 else {
            // 功能关着就把缓存也清掉 —— 界面上的温度不该继续跳。
            _latestCPUTempC = nil
            return
        }
        guard let observedMax = celsius else { return }

        // 阈值与冷却的判定放在 `CPUTemperatureAlert`（Shared/，可单独测）。
        let now = Date()
        var alert = CPUTemperatureAlert(
            thresholdCelsius: config.cpuTempHighCelsius,
            lastReportedAt: lastCPUTempReportAt)
        switch alert.decide(observedCelsius: observedMax,
                            now: now,
                            isEnabled: config.cpuTempEnabled) {
        case .belowThreshold:
            // 不超阈也填缓存：UI 实时显示温度就算不告警也要刷新。
            _latestCPUTempC = observedMax
            return
        case .suppressedByCooldown:
            // 冷却期内不重复报，但温度照样刷到界面上。
            _latestCPUTempC = observedMax
            return
        case .report:
            break
        }

        alert.markReported(at: now)
        lastCPUTempReportAt = alert.lastReportedAt
        _latestCPUTempC = observedMax
        let threshold = config.cpuTempHighCelsius
        let event = CPUTemperatureEvent(
            maxC: observedMax,
            averageC: nil,
            aggregateC: nil,
            observedMaxC: observedMax,
            thresholdC: threshold,
            timestamp: now
        )
        _lastEvent = .cpuTemp(event)
        _lastEventAt = now
        onEvent?(.cpuTemp(event))
    }

    /// 物理内存（字节）。读不到时返回 0（表示「跳过 RAM 判定」）。
    private static func physicalMemory() -> UInt64 {
        var size: UInt64 = 0
        var sizeLen = MemoryLayout<UInt64>.size
        let name = "hw.memsize"
        let ret = sysctlbyname(name, nil, &sizeLen, nil, 0)
        guard ret == 0 else { return 0 }
        let ret2 = sysctlbyname(name, &size, &sizeLen, nil, 0)
        guard ret2 == 0 else { return 0 }
        return size
    }
}