//
//  DashboardSystemCards.swift
//  Deep Sleep
//
//  总览页上的系统监控卡片：CPU / 内存 / 磁盘 / 网络 四项。
//
//  设计约束（跟 DesignSystem.swift 一致，改之前先读）：
//  - **容器只有一种**：外层用 SectionCard（它自带 glassCard()），
//    页面里不自己写 background。
//  - **指标块用现成的 MetricTile**，不另造一个组件。
//  - **状态永远「颜色 + 文字」双编码**：偏高 / 过高 光靠颜色读不出来。
//  - **间距与圆角只用 DS 令牌**，不写字面量。
//  - **读不到就写「不可用」，不写 0**：0 会被误读成「确实是 0」。
//
//  数据源：`SystemMonitor.shared.liveSnapshot()` —— 内部走串行 queue 同步读，
//  不卡 UI。本机采样的那部分（每核心 CPU / 内存明细 / 卷 / 网络速率）来自
//  SystemMetricsCollector，系统监控页开着的时候它才在跑，所以这里自己叫醒它。
//

import SwiftUI

struct DashboardSystemCards: View {

    // MARK: - 阈值

    /// 分档阈值。
    ///
    /// 口径跟 MonitoringView 的告警阈值接近，但这里只做**显示分档**，
    /// 不触发任何告警 —— 总览页只回答「现在怎么样」。
    private enum Threshold {
        /// CPU / 内存达到这个值（%）算「过高」。
        static let high = 80.0
        /// CPU / 内存达到这个值（%）算「偏高」。
        static let elevated = 50.0
        /// 磁盘已用占比达到这个值（%）算「过高」。
        static let diskHigh = 90.0
        /// 磁盘已用占比达到这个值（%）算「偏高」。
        static let diskElevated = 75.0
        /// 网络下行达到这个值（字节/秒）算「过高」。沿用面板自己的口径。
        static let networkHigh = SystemMetrics.MetricThresholds.default.networkBytesPerSecond
        /// 网络下行达到「过高」的一半算「偏高」。
        static let networkElevated = networkHigh / 2
    }

    // MARK: - 主体

    var body: some View {
        SectionCard(
            title: "系统监控",
            symbol: "gauge.with.dots.needle.50percent",
            accent: DS.Tone.info
        ) {
            // 每秒一拍。TimelineView 不需要自己管生命周期：
            // 视图不在屏幕上时它自己就停。
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                // 每拍叫醒一次采集器。系统监控页离开时会 stop 这个全局采集器，
                // 而它 stop 的时机跟本页的 onAppear 不一定对得上
                // （两个页面是同一个 switch 里换的，谁先谁后不保证）。
                // start 是幂等的（已经在跑就直接返回），所以这里每拍叫一次最省心。
                //
                // `let _ =` 是必须的：ViewBuilder 闭包里只有 View 表达式能成立，
                // 裸调用返回 Void 的 start() 会被当成 View 来编译，报
                // "type '()' cannot conform to 'View'"。用 `let _ =` 明确丢弃返回值。
                let _ = SystemMetricsCollector.shared.start()

                let snapshot = SystemMonitor.shared.liveSnapshot()
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: DS.Space.md),
                        GridItem(.flexible(), spacing: DS.Space.md)
                    ],
                    spacing: DS.Space.md
                ) {
                    cpuTile(snapshot)
                    memoryTile(snapshot)
                    diskTile(snapshot)
                    networkTile(snapshot)
                }
            }
        }
        .onAppear {
            // 叫醒本机采样器：不叫的话内存明细 / 卷 / 网络速率全是空的。
            //
            // **不在 onDisappear 里 stop** —— 这个采集器是全局单例，
            // 系统监控页离开页面时会自己 stop；这里再 stop 就会跟它抢同一个
            // 采集器，切页的瞬间可能把对方的数据源停掉。
            SystemMetricsCollector.shared.start()
        }
    }

    // MARK: - 指标块

    private func cpuTile(_ snapshot: SystemMonitor.LiveSnapshot) -> some View {
        let percent = cpuPercent(snapshot)
        let level = percent.map {
            classify($0, high: Threshold.high, elevated: Threshold.elevated)
        }
        return MetricTile(
            title: "CPU",
            value: percent.map { String(format: "%.0f", $0) } ?? "不可用",
            unit: percent == nil ? nil : "%",
            status: level?.text ?? "无数据",
            tint: level?.tone ?? DS.Tone.idle,
            progress: percent.map { $0 / 100 },
            symbol: "cpu"
        )
    }

    private func memoryTile(_ snapshot: SystemMonitor.LiveSnapshot) -> some View {
        let percent = memoryPercent(snapshot)
        let level = percent.map {
            classify($0, high: Threshold.high, elevated: Threshold.elevated)
        }
        return MetricTile(
            title: "内存",
            value: percent.map { String(format: "%.0f", $0) } ?? "不可用",
            unit: percent == nil ? nil : "%",
            status: level?.text ?? "无数据",
            tint: level?.tone ?? DS.Tone.idle,
            progress: percent.map { $0 / 100 },
            symbol: "memorychip"
        )
    }

    private func diskTile(_ snapshot: SystemMonitor.LiveSnapshot) -> some View {
        let fraction = systemVolume(snapshot)?.usedFraction
        let percent = fraction.map { $0 * 100 }
        let level = percent.map {
            classify($0, high: Threshold.diskHigh, elevated: Threshold.diskElevated)
        }
        return MetricTile(
            title: "磁盘",
            value: percent.map { String(format: "%.0f", $0) } ?? "不可用",
            unit: percent == nil ? nil : "%",
            status: level?.text ?? "无数据",
            tint: level?.tone ?? DS.Tone.idle,
            progress: fraction,
            symbol: "internaldrive"
        )
    }

    private func networkTile(_ snapshot: SystemMonitor.LiveSnapshot) -> some View {
        let rate = snapshot.networkRate?.downloadBytesPerSecond
        let parts = rate.map { rateParts($0) }
        let level = rate.map {
            classify($0, high: Threshold.networkHigh, elevated: Threshold.networkElevated)
        }
        return MetricTile(
            title: "网络（下行）",
            value: parts?.value ?? "不可用",
            unit: parts?.unit,
            status: level?.text ?? "无数据",
            tint: level?.tone ?? DS.Tone.idle,
            progress: nil,
            symbol: "arrow.down"
        )
    }

    // MARK: - 取值

    /// CPU 占用百分比（0–100）。
    ///
    /// 优先用本机采样的整机口径（不依赖特权助手，助手没装也有数）；
    /// 助手那条路的 cpuPercent 在监控没开时是 0 —— 那是「没采到」不是「确实是 0」，
    /// 所以只在快照不陈旧时才用它。
    private func cpuPercent(_ snapshot: SystemMonitor.LiveSnapshot) -> Double? {
        if let local = snapshot.localCPUPercent { return local }
        guard !snapshot.isStale else { return nil }
        return snapshot.cpuPercent
    }

    /// 内存占用百分比（0–100）。
    ///
    /// memoryDetail.usedPercent 与 ramPercent 单位一致（都是 0–100），
    /// 不是 0–1，不需要换算。
    private func memoryPercent(_ snapshot: SystemMonitor.LiveSnapshot) -> Double? {
        if let detail = snapshot.memoryDetail { return detail.usedPercent }
        guard !snapshot.isStale else { return nil }
        return snapshot.ramPercent
    }

    /// 系统盘：第一个不可移除的卷。
    private func systemVolume(_ snapshot: SystemMonitor.LiveSnapshot) -> SystemMetrics.DiskVolume? {
        snapshot.volumes.first { !$0.isRemovable }
    }

    // MARK: - 分档与格式化

    /// 一档状态：文字 + 颜色（规则 4，两者必须同时给）。
    private struct Level {
        let text: String
        let tone: Color
    }

    private func classify(_ value: Double, high: Double, elevated: Double) -> Level {
        if value >= high { return Level(text: "过高", tone: DS.Tone.critical) }
        if value >= elevated { return Level(text: "偏高", tone: DS.Tone.caution) }
        return Level(text: "正常", tone: DS.Tone.good)
    }

    /// 网络速率 → (数值, 单位)。
    ///
    /// 复用 SystemMetrics.formatBytes 的口径（十进制 1000 进制，与活动监视器一致），
    /// 只把「X MB」拆成数值与单位两截，好让 MetricTile 分开显示。
    private func rateParts(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let clamped = min(max(bytesPerSecond, 0), Double(UInt64.max))
        let formatted = SystemMetrics.formatBytes(UInt64(clamped.rounded()))
        let parts = formatted.split(separator: " ")
        guard parts.count == 2 else { return (formatted, "/s") }
        return (String(parts[0]), "\(parts[1])/s")
    }
}
