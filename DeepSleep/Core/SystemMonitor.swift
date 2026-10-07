//
//  SystemMonitor.swift
//  Deep Sleep
//
//  系统过载监控 + 内存泄漏检测的采样循环与阈值判定。
//
//  跑法：
//    - 每 sampleIntervalSeconds 秒从 ProcessStatsProvider.fetchStats() 拿一次快照
//    - 更新内部 RSS 环形缓冲，喂给 LeakDetector
//    - 检查 RAM 总使用率（用 host info）/ 累计 CPU% 是否持续超过阈值
//    - 触发时通过回调 onOverload / onLeak 把事件吐给 UI 与 Notifier
//
//  这个文件不出现在单个已知的 UI 路径，UI 与 Notifier 各自挂回调，
// 避免它去 import SwiftUI / UserNotifications。
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

/// 内存泄漏事件。
public typealias LeakEvent = LeakReport

/// SystemMonitor 把这些事件推给上层。
public enum MonitorEvent: Sendable {
    case overload(OverloadEvent)
    case leak(LeakEvent)
}

public final class SystemMonitor {

    public static let shared = SystemMonitor()

    // MARK: - 状态

    private let queue = DispatchQueue(label: "com.skyc8266.deepsleep.monitor")
    private var timer: DispatchSourceTimer?
    private var config: MonitorConfig
    private let bufferLimit = 64   // 64 个样本 × 3 秒 = 192 秒窗口
    /// PID → 历史 RSS 样本（环形缓冲）。
    private var ringBuffers: [pid_t: [RSSSample]] = [:]
    /// PID → 最近一次采样时的进程名（用于在 LeakReport 里展示）。
    private var names: [pid_t: String] = [:]
    /// 当前 RAM% 持续超过阈值的开始时间；为 nil 表示当前未在超阈。
    private var overloadStartedAt: Date?
    /// 已发出的过载事件 cooldown 起点；防止 4/24s 内连发两条同样的过载。
    private var lastOverloadReportAt: Date?
    /// 已发出的泄漏事件；同一 PID 上轮后 cooldown。
    private var leakCooldown: [pid_t: Date] = [:]

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
        let nowInterval = now.timeIntervalSince1970

        // 更新环形缓冲 & 进程名
        var newBuffer: [pid_t: [RSSSample]] = [:]
        var newNames: [pid_t: String] = [:]
        for record in records {
            newNames[record.pid] = record.name
            var ring = ringBuffers[record.pid] ?? []
            ring.append(RSSSample(pid: record.pid,
                                  rssBytes: record.rssBytes,
                                  timestamp: nowInterval))
            if ring.count > bufferLimit { ring.removeFirst(ring.count - bufferLimit) }
            newBuffer[record.pid] = ring
        }
        ringBuffers = newBuffer
        names = newNames

        // 判定泄漏
        let allHistory = Array(ringBuffers.values).flatMap { $0 }
        let leaks = LeakDetector.evaluateAll(history: allHistory, nameForPID: { [weak self] pid in
            self?.names[pid] ?? "pid \(pid)"
        })
        for leak in leaks {
            // 同一 PID 5 分钟内最多报一次。
            if let last = self.leakCooldown[leak.pid],
               now.timeIntervalSince(last) < 300 { continue }
            leakCooldown[leak.pid] = now
            onEvent?(.leak(leak))
        }

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