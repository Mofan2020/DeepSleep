//
//  LeakDetector.swift
//  Deep Sleep
//
//  内存泄漏检测 —— **纯函数 + 配置常量**，便于单测。
//
//  判定启发式（保守）：
//    1. 连续 ≥ 3 次 RSS 单调递增（rss[i+1] > rss[i]）；
//    2. 窗口内累计增长 ≥ 50 MB；
//    3. 当前 RSS ≥ 100 MB（防止对小进程的噪声敏感）；
//    4. 进程存活时间（最新时间 - 起始时间）≥ 60s（防止刚启动的进程误报）。
//
//  全部满足即视为疑似泄漏，返回 LeakReport；否则返回 nil。
//
//  这份实现故意与 ProcessStats / ProcessSnapshot 解耦：
//  它的输入是 RSSSample 数组，输出是 LeakReport / nil；调用方负责把
//  ProcessStats.Record 转成 RSSSample、把窗口塞给 evaluate。
//  解耦之后算法可以纯函数单测，SystemMonitor 只需把时序装好喂进来。
//

import Foundation

/// 一次采样的内存样本（来自某个 PID）。
public struct RSSSample: Sendable, Equatable {
    public let pid: pid_t
    public let rssBytes: UInt64
    public let timestamp: TimeInterval

    public init(pid: pid_t, rssBytes: UInt64, timestamp: TimeInterval) {
        self.pid = pid
        self.rssBytes = rssBytes
        self.timestamp = timestamp
    }
}

/// 一次疑似泄漏的判定结果。命中算法只是填充结构体，不做执行。
public struct LeakReport: Sendable, Equatable {
    public let pid: pid_t
    public let name: String
    /// 当前 RSS（MB）。
    public let rssMB: Int
    /// 窗口内累计增长（MB）。
    public let cumulativeMB: Int
    /// 触发判定的样本数（用于 UI 显示「监测了多久」）。
    public let sampleCount: Int

    public init(pid: pid_t, name: String, rssMB: Int, cumulativeMB: Int, sampleCount: Int) {
        self.pid = pid
        self.name = name
        self.rssMB = rssMB
        self.cumulativeMB = cumulativeMB
        self.sampleCount = sampleCount
    }
}

public enum LeakDetector {

    // MARK: - 阈值

    /// 最少需要的单调递增次数。
    public static let minimumMonotonicSteps: Int = 3

    /// 累计增长下限（MB）。
    public static let minimumCumulativeMB: Int = 50

    /// 当前 RSS 下限（MB）。低于此值即便单调增长也不报（噪声）。
    public static let minimumCurrentRSSMB: Int = 100

    /// 进程存活时间下限（秒）。低于此值即便单调增长也不报（刚启动）。
    public static let minimumLifetimeSeconds: TimeInterval = 60

    // MARK: - 判定

    /// 判定单个 PID 的历史样本是否构成泄漏。返回 nil 表示不是。
    ///
    /// `nameForPID` 用于把 pid 还原成可读名字（由调用方提供，
    /// 算法不持有进程名表）。
    public static func evaluate(history: [RSSSample],
                                nameForPID: ((pid_t) -> String)? = nil) -> LeakReport? {
        guard history.count >= minimumMonotonicSteps + 1 else { return nil }

        let pid = history[0].pid
        let name = nameForPID?(pid) ?? "pid \(pid)"

        let sorted = history.sorted { $0.timestamp < $1.timestamp }
        guard sorted.last!.timestamp - sorted.first!.timestamp >= minimumLifetimeSeconds else {
            return nil
        }

        let rssNow = sorted.last!.rssBytes
        let rssStart = sorted.first!.rssBytes
        let cumulative = rssNow >= rssStart ? rssNow - rssStart : 0

        guard cumulative >= UInt64(minimumCumulativeMB) * 1_000_000 else { return nil }
        guard rssNow >= UInt64(minimumCurrentRSSMB) * 1_000_000 else { return nil }

        // 检查窗口尾段连续单调递增（最后 N+1 个样本）。
        let window = Array(sorted.suffix(minimumMonotonicSteps + 1))
        var monotonic = true
        for i in 0..<(window.count - 1) {
            if window[i + 1].rssBytes <= window[i].rssBytes {
                monotonic = false
                break
            }
        }
        guard monotonic else { return nil }

        return LeakReport(
            pid: pid,
            name: name,
            rssMB: Int(rssNow / 1_000_000),
            cumulativeMB: Int(cumulative / 1_000_000),
            sampleCount: sorted.count
        )
    }

    /// 给定一个由多个 PID 拼接而成的样本数组，按 PID 分组然后逐组判定。
    public static func evaluateAll(history: [RSSSample],
                                   nameForPID: ((pid_t) -> String)? = nil) -> [LeakReport] {
        let grouped = Dictionary(grouping: history, by: { $0.pid })
        var reports: [LeakReport] = []
        for (_, samples) in grouped {
            let sorted = samples.sorted { $0.timestamp < $1.timestamp }
            if let report = evaluate(history: sorted, nameForPID: nameForPID) {
                reports.append(report)
            }
        }
        return reports
    }
}