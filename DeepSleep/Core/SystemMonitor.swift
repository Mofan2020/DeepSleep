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
import Darwin

/// 监控配置（持久化到 UserDefaults）。
public struct MonitorConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// RAM 总使用率阈值（0–100）。
    public var ramHighPercent: Double
    /// 累计 CPU% 阈值（0–100，whole-CPU 口径）。
    public var cpuHighPercent: Double
    /// 持续超过阈值多少秒才报警。
    public var highDurationSeconds: Int
    /// 采样间隔（秒）。
    public var sampleIntervalSeconds: Double
    /// 是否允许自动冻结进程（必须在 UI 中显式打开；默认 false）。
    public var autoSuspend: Bool
    /// 单进程 RSS 阈值（字节）。任一进程当前占用 ≥ 此值，立刻报警，不走持续时间。
    public var singleProcessRAMBytes: Int

    public init(enabled: Bool = false,
                ramHighPercent: Double = 90,
                cpuHighPercent: Double = 85,
                highDurationSeconds: Int = 60,
                sampleIntervalSeconds: Double = 3,
                autoSuspend: Bool = false,
                singleProcessRAMBytes: Int = 4 * 1024 * 1024 * 1024) {
        self.enabled = enabled
        self.ramHighPercent = ramHighPercent
        self.cpuHighPercent = cpuHighPercent
        self.highDurationSeconds = highDurationSeconds
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.autoSuspend = autoSuspend
        self.singleProcessRAMBytes = singleProcessRAMBytes
    }

    public static let `default` = MonitorConfig()
}

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

/// SystemMonitor 把这些事件推给上层。
public enum MonitorEvent: Sendable {
    case overload(OverloadEvent)
    case singleProcessRAM(SingleProcessRAMEvent)
}

public final class SystemMonitor {

    public static let shared = SystemMonitor()

    // MARK: - 状态

    private let queue = DispatchQueue(label: "com.skyc8266.deepsleep.monitor")
    private var timer: DispatchSourceTimer?
    private var config: MonitorConfig
    /// 当前 RAM%/CPU% 持续超过阈值的开始时间；为 nil 表示当前未在超阈。
    private var overloadStartedAt: Date?
    /// 已发出的过载事件 cooldown 起点；防止 4/24s 内连发两条同样的过载。
    private var lastOverloadReportAt: Date?
    /// 单进程 RSS 报警 cooldown：同一个 PID 5 分钟内最多报一次。
    private var singleRAMCooldown: [pid_t: Date] = [:]
    /// 最近一次发出的事件（含时间戳）。UI 用它展示「最近事件」。
    /// 改了 MainActor 访问 + 串行队列写锁，UI 读不会卡。
    private var _lastEvent: MonitorEvent?
    private var _lastEventAt: Date?

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

    private static func describe(_ event: MonitorEvent) -> String {
        switch event {
        case .overload(let o):
            return "系统过载：RAM \(Int(o.ramPercent))% / CPU \(Int(o.totalCpuPercent))%"
        case .singleProcessRAM(let r):
            let gb = Double(r.record.rssBytes) / 1_073_741_824
            return String(format: "单进程过高：%@ (%.2f GB)", r.record.name, gb)
        }
    }

    public func start() {
        // 启动时从 UserDefaults 读持久化的 config（之前版本在这里丢：
        // UI 改了 enable 但 SystemMonitor 永远是 .default。）
        self.config = MonitorConfig.load()
        queue.async { [weak self] in
            guard let self else { return }
            guard self.config.enabled else { return }
            guard self.timer == nil else { return }
            self.startTimerLocked()
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
        let records: [ProcessStats.Record]
        do {
            records = try await ProcessStatsProvider.shared.fetchStats()
        } catch {
            // 监控拿不到数据不算「过载」，下次再试。
            return
        }

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
        let totalCPU: Double = records.reduce(0) { $0 + $1.cpuPercent }
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