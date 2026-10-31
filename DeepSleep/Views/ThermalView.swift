//
//  ThermalView.swift
//  Deep Sleep
//
//  温度监控页：各传感器实时读数 + 90°C 安全兜底状态。
//
//  读数走特权助手：IOHID 私有温度事件通道（PrimaryUsagePage 0xFF00 /
//  PrimaryUsage 5）虽然普通进程也能读，但应用侧与助手侧需要**同一份数据源**
//  —— 助手要在应用退出后独立做 90°C 兜底，两边读数不一致会出现「应用说没超、
//  助手说超了」或反过来。所以统一走助手的 getTemperatureSnapshot。
//
//  读数已经在 ThermalMonitor 里按 ThermalSensorGroup 分好组、同名通道
//  合并取最高值、负值与零值过滤过了。这里只负责呈现，不重复做过滤 ——
//  两处各写一份过滤逻辑迟早会漂。
//

import SwiftUI

struct ThermalView: View {

    @ObservedObject var monitor: ThermalMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryCard
            safetyCard
            sensorCard
            notesCard
            Spacer(minLength: 0)
        }
        .pageLayout()
        .onAppear { monitor.start() }
    }

    // MARK: - 概览

    private var summaryCard: some View {
        SectionCard(
            title: "温度概览",
            subtitle: "读数来自 IOHID 私有温度事件通道，与 90°C 兜底判定同源。",
            symbol: "thermometer.medium",
            accent: summaryTint
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 28) {
                    metricBlock(
                        title: "最高温度",
                        value: monitor.hottestCelsius.map { String(format: "%.1f", $0) } ?? "—",
                        unit: "°C",
                        tint: summaryTint
                    )
                    metricBlock(
                        title: "传感器",
                        value: "\(totalSensors)",
                        unit: "个",
                        tint: .secondary
                    )
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        StatusPill(
                            text: statusText,
                            isActive: !monitor.isOverEmergencyThreshold,
                            color: statusColor
                        )
                        // 「N 秒前更新」必须自己走。它是按当前时间算的，但视图
                        // 只在 @Published 变化时重算 —— 10 秒才动一次，平时就
                        // 一直停在「刚刚更新」，反而容易被判成「没在刷新」。
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(updatedText(now: context.date))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }

                if monitor.isOverEmergencyThreshold {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("最高温度 \(String(format: "%.1f", monitor.hottestCelsius ?? 0))°C，"
                             + "已达 \(Int(FanControl.emergencyTemperatureCelsius))°C 安全阈值。"
                             + "所有风扇已被强制拉到最大转速。")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if isCoolingDown {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.orange)
                        Text("温度已回落，兜底解除冷却中（还剩 \(Int(cooldownRemaining.rounded())) 秒）。"
                             + "冷却结束前风扇保持最大转速。")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !monitor.isAvailable {
                    Label("温度读取当前不可用", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - 安全兜底（永久渲染，不随状态隐藏）

    private var safetyCard: some View {
        SectionCard(
            title: "安全兜底 · \(Int(FanControl.emergencyTemperatureCelsius))°C 强制最大转速",
            subtitle: nil,
            symbol: "shield.lefthalf.filled",
            accent: .orange
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("任一传感器达到 \(Int(FanControl.emergencyTemperatureCelsius))°C 时，"
                     + "所有风扇立即拉到各自最大转速，并压过你设置的任何模式与规则。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("温度回落到阈值以下后仍需冷却 \(Int(FanControl.emergencyCooldownSeconds)) 秒才恢复原模式，"
                     + "避免在阈值附近抖动导致风扇反复启停。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if !monitor.isAvailable {
                    Label("兜底判定依赖温度读取，读不到温度时无法生效",
                          systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 传感器

    private var sensorCard: some View {
        SectionCard(
            title: "传感器",
            subtitle: "同名通道已合并，显示其中的最高值。",
            symbol: "list.bullet.rectangle",
            accent: .blue
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if totalSensors == 0 {
                    Text(monitor.isAvailable ? "暂无有效温度读数" : "温度读取不可用")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(ThermalSensorGroup.allCases) { group in
                        if let readings = monitor.groupedReadings[group], !readings.isEmpty {
                            groupSection(group, readings)
                        }
                    }
                }
            }
        }
    }

    private func groupSection(_ group: ThermalSensorGroup,
                              _ readings: [GroupedTemperatureReading]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(group.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(readings.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.top, 8)

            ForEach(readings.sorted { $0.celsius > $1.celsius }) { reading in
                sensorRow(reading)
            }
        }
    }

    private func sensorRow(_ reading: GroupedTemperatureReading) -> some View {
        HStack(spacing: 10) {
            ThresholdDot(celsius: reading.celsius)
            Text(reading.sensorID)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if reading.channelCount > 1 {
                // 合并过的通道标一下数量：用户看到一行电池温度，
                // 得知道背后是几路通道，而不是以为只有一路。
                Text("\(reading.channelCount) 通道")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Text(String(format: "%.1f", reading.celsius))
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint(for: reading.celsius))
            Text("°C")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(bandText(for: reading.celsius))
                .font(.caption2)
                .foregroundStyle(tint(for: reading.celsius))
                .frame(width: 28, alignment: .leading)
        }
        .padding(.vertical, 5)
    }

    private var notesCard: some View {
        SectionCard(
            title: "说明",
            symbol: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: 7) {
                BulletLine("温度由特权助手读取，助手未就绪时这一页读不到数。")
                BulletLine("负读数与零读数代表该通道不是温度传感器，已在采集层过滤。")
                BulletLine("「校准参考」组的读数长期恒定，是 PMU 的校准基准，不参与最高温与 \(Int(FanControl.emergencyTemperatureCelsius))°C 兜底判定。")
                BulletLine("\(Int(FanControl.emergencyTemperatureCelsius))°C 兜底由应用与特权助手两侧独立判定，应用退出后助手仍会保命。")
                BulletLine("本页显示传感器原始读数，不做平滑，因此会有小幅跳动。")
            }
        }
    }

    // MARK: - 派生数据

    private var totalSensors: Int {
        monitor.groupedReadings.values.reduce(0) { $0 + $1.count }
    }

    /// 兜底解除后的冷却剩余秒数。
    ///
    /// 从兜底事件历史推导：最近一次已解除的事件若还在冷却窗口内，
    /// 说明风扇仍被按在最大转速上，界面要如实显示，不能装作已经恢复。
    private var cooldownRemaining: TimeInterval {
        guard let last = FanController.shared.emergencyEvents.first,
              let released = last.releasedAt else { return 0 }
        let elapsed = Date().timeIntervalSince(released)
        return max(0, FanControl.emergencyCooldownSeconds - elapsed)
    }

    private var isCoolingDown: Bool {
        !monitor.isOverEmergencyThreshold && cooldownRemaining > 0
    }

    private var summaryTint: Color {
        tint(for: monitor.hottestCelsius)
    }

    private var statusText: String {
        if monitor.isOverEmergencyThreshold { return "紧急降速中" }
        if isCoolingDown { return "冷却中" }
        return "正常"
    }

    private var statusColor: Color {
        if monitor.isOverEmergencyThreshold { return .red }
        if isCoolingDown { return .orange }
        return .green
    }

    private func updatedText(now: Date) -> String {
        guard let updated = monitor.lastUpdatedAt else { return "尚未采样" }
        let seconds = Int(now.timeIntervalSince(updated))
        if seconds < 2 { return "刚刚更新" }
        if seconds < 60 { return "\(seconds) 秒前更新" }
        return updated.formatted(date: .omitted, time: .standard)
    }

    private func tint(for celsius: Double?) -> Color {
        guard let celsius else { return .secondary }
        if celsius >= FanControl.emergencyTemperatureCelsius { return .red }
        if celsius >= 85 { return .orange }
        if celsius >= 75 { return .yellow }
        return .primary
    }

    private func tint(for celsius: Double) -> Color {
        tint(for: Optional(celsius))
    }

    private func bandText(for celsius: Double) -> String {
        if celsius >= FanControl.emergencyTemperatureCelsius { return "紧急" }
        if celsius >= 85 { return "过高" }
        if celsius >= 75 { return "偏高" }
        return "正常"
    }

    private func metricBlock(title: String, value: String, unit: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 组件

/// 温度分档小圆点。颜色只是辅助，状态词才是判定依据。
struct ThresholdDot: View {
    let celsius: Double

    private var color: Color {
        if celsius >= FanControl.emergencyTemperatureCelsius { return .red }
        if celsius >= 85 { return .orange }
        if celsius >= 75 { return .yellow }
        return .green.opacity(0.65)
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}
