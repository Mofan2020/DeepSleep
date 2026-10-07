//
//  SystemMonitor.swift
//  Deep Sleep
//
//  系统过载监控的采样循环与阈值判定（CPU / RAM 持续超阈 → Top 3 占用者）。
//
//  跑法：
//    - 每 sampleIntervalSeconds 从 ProcessStatsProvider.fetchStats() 拿一次快照
//    - 计算总 RAM 使用率与累计 CPU%
//    - 持续超过阈值 N 秒 → 触发过载事件
//
//  v1.4.0 早期版本里还有「内存泄漏检测」分支；v1.4.1 起砍掉，
//  只保留过载监控。原因：内存泄漏没有靠「绝对阈值」能用的好判定，
//  应用启动涨几百 MB、游戏加载涨几 GB 都正常；继续做误报远多于真报。
//  算法注释与剩余字段都只服务过载判定。
//

import Foundation
import Darwin

/// 监控配置（持久化到 UserDefaults）。
public struct MonitorConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// RAM 总使用率阈值（0–100）。
    public var ramHighPercent: Double
    /// 累计非保护用户进程 CPU% 阈值（0+）。多核可超过 100。
    public var cpuHighPercent: Double
    /// 持续超过阈值多少秒才报警。
    public var highDurationSeconds: Int
    /// 采样间隔（秒）。
    public var sampleIntervalSeconds: Double
    /// 是否允许自动冻结进程（必须在 UI 中显式打开；默认 false）。
    public var autoSuspend: Bool

    public init(enabled: Bool = false,
                ramHighPercent: Double = 90,
                cpuHighPercent: Double = 400,
                highDurationSeconds: Int = 60,
                sampleIntervalSeconds: Double = 3,
                autoSuspend: Bool = false) {
        self.enabled = enabled
        self.ramHighPercent = ramHighPercent
        self.cpuHighPercent = cpuHighPercent
        self.highDurationSeconds = highDurationSeconds
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.autoSuspend = autoSuspend
    }

    public static let `default` = MonitorConfig()
}

/// 系统过载事件：含当前 RAM% / 累计 CPU% / Top 3 占用者。
public struct OverloadEvent: Sendable {
    public let ramPercent: Double
    public let totalCpuPercent: Double
    public let topThree: [ProcessStats.Record]
    public let timestamp: Date
}

/// SystemMonitor 把这些事件推给上层。
public enum MonitorEvent: Sendable {
    case overload(OverloadEvent)
}

public final class SystemMonitor {

    public static let shared = SystemMonitor()

    // MARK: - 状态

    private let queue = DispatchQueue(label: "com.skyc8266.deepsleep.monitor")
    private var timer: DispatchSourceTimer?
    private var config: MonitorConfig
    /// 当前 RAM% 持续超过阈值的开始时间；为 nil 表示当前未在超阈。
    private var overloadStartedAt: Date?
    /// 已发出的过载事件 cooldown 起点；防止 4/24s 内连发两条同样的过载。
    private var lastOverloadReportAt: Date?

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

    public func start() {
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

        // 判定过载
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