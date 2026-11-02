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
//  界面约定（2026 换新）：
//  - 颜色只表达语义，状态永远是「颜色 + 文字」双编码（正常 / 偏高 / 过高 / 紧急）。
//  - 卡片只走 SectionCard / insetPanel / MetricTile，不自己造第二种背景。
//  - 分档阈值（提示 / 过热）只影响本页的颜色与状态词，不参与任何判定；
//    紧急阈值固定为安全兜底的 90°C，不在此处调整。
//

import SwiftUI

// MARK: - 分档默认值

/// 提示 / 过热分档的默认值。
///
/// 与 `@AppStorage` 的默认值必须一致 —— 一个是「首次进入的样子」，
/// 一个是「用户没改过时读到的值」，两边不一样会出现第一次进页面档位跳动。
private enum ThThermalBandDefaults {
    /// 达到这个温度记「偏高」。
    static let warn: Double = 75
    /// 达到这个温度记「过高」。
    static let hot: Double = 85
    /// 提示阈值的可调区间下限。
    static let warnLowerBound: Double = 50
    /// 提示阈值的可调区间上限。留 88 是为了给「过热阈值」腾出 89 这一档。
    static let warnUpperBound: Double = 88
    /// 过热阈值的可调区间下限。
    static let hotLowerBound: Double = 60
    /// 过热阈值的可调区间上限。90°C 归安全兜底，不归这里。
    static let hotUpperBound: Double = 89
}

struct ThermalView: View {

    @ObservedObject var monitor: ThermalMonitor

    /// 传感器分组的展开状态。
    ///
    /// SoC / 电池 / 存储 是常看且量小的，默认展开；GPU / 其它 / 校准参考
    /// 量大的或次要的，默认折叠。展开状态不持久化 —— 每次进页回到默认。
    @State private var expandedGroups: Set<ThermalSensorGroup> = [.soc, .battery, .storage]

    /// 提示阈值（°C）。只决定本页什么时候开始写「偏高」。
    ///
    /// 存 UserDefaults 是因为它是**显示偏好**，不是判定参数：安全兜底与
    /// 告警都不看它。改它不会影响风扇与告警的任何行为。
    @AppStorage("thermal.band.warnCelsius") private var warnThreshold: Double = ThThermalBandDefaults.warn
    /// 过热阈值（°C）。只决定本页什么时候开始写「过高」。
    @AppStorage("thermal.band.hotCelsius") private var hotThreshold: Double = ThThermalBandDefaults.hot

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            summaryCard
            safetyCard
            sensorCard
            bandCard
            Spacer(minLength: 0)
        }
        .pageLayout()
        .onAppear { monitor.start() }
        .onChange(of: warnThreshold) { _, newValue in
            // 过热阈值必须高于提示阈值，否则两档会挤在一起。
            // 直接夹住，不弹窗、不报错 —— 用户拖滑杆时最烦的就是弹窗。
            if newValue >= hotThreshold {
                hotThreshold = min(newValue + 1, ThThermalBandDefaults.hotUpperBound)
            }
        }
        .onChange(of: hotThreshold) { _, newValue in
            if newValue <= warnThreshold {
                warnThreshold = max(newValue - 1, ThThermalBandDefaults.warnLowerBound)
            }
        }
    }

    // MARK: - 概览

    private var summaryCard: some View {
        SectionCard(
            title: "温度概览",
            subtitle: nil,
            symbol: "thermometer.medium",
            accent: summaryTint
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                metricRow

                HStack(spacing: DS.Space.sm) {
                    Text("共 \(totalSensors) 个传感器读数")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: DS.Space.sm)
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

                if !monitor.isAvailable {
                    Label("温度读取当前不可用", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(DS.Tone.caution)
                }
            }
        }
    }

    /// 一行指标格。没传感器的类别整格不渲染，不留空位。
    private var metricRow: some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            metricTile(title: "最高温", celsius: monitor.hottestCelsius, symbol: "thermometer.high")
            if let soc = groupMax(.soc) {
                metricTile(title: "SoC 最高", celsius: soc, symbol: "cpu")
            }
            if let gpu = groupMax(.gpu) {
                metricTile(title: "GPU 最高", celsius: gpu, symbol: "display")
            }
            if let battery = groupMax(.battery) {
                metricTile(title: "电池", celsius: battery, symbol: "battery.100")
            }
            if let storage = groupMax(.storage) {
                metricTile(title: "存储", celsius: storage, symbol: "internaldrive")
            }
        }
    }

    private func metricTile(title: String, celsius: Double?, symbol: String) -> some View {
        // 这里**不能**写 `celsius.map { band(for: $0) }`。
        //
        // `band(for:)` 原本有 Double? 与 Double 两个重载，闭包的返回类型推不出来，
        // 编译器就会在 `Optional.map` 的两个候选之间挑错：SwiftUI 给
        // `Optional` 加了一个 `map`（`where Wrapped: Gesture`），Xcode 26 会
        // 挑中它并报「referencing instance method 'map' on 'Optional' requires
        // that 'Double' conform to 'Gesture'」。Xcode 27 修好了这个重载解析，
        // 所以本机编译得过、CI 上编不过。
        //
        // 现在两处都堵上了：`band(for:)` 只留 Double? 一个重载，这里也用
        // 显式 if let —— 哪个编译器都不会有歧义。
        var band: Band?
        if let celsius {
            band = self.band(for: celsius)
        } else {
            band = nil
        }
        return MetricTile(
            title: title,
            value: celsius.map { String(format: "%.1f", $0) } ?? "—",
            unit: celsius == nil ? nil : "°C",
            status: band?.text ?? "无读数",
            tint: band?.tint,
            symbol: symbol
        )
    }

    // MARK: - 安全兜底（永久渲染，不随状态隐藏）

    private var safetyCard: some View {
        SectionCard(
            title: "安全兜底 · \(Int(emergencyThreshold))°C 强制最大转速",
            subtitle: nil,
            symbol: "shield.lefthalf.filled",
            accent: DS.Tone.caution
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                // 状态与倒计时放在同一个 TimelineView 里：冷却期一结束，
                // 状态词要当场从「注意」翻回「正常」，不能等下一次温度
                // 采样（10 秒后）才翻。
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = cooldownRemaining(at: context.date)
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        HStack(spacing: DS.Space.sm) {
                            StatusPill(
                                text: safetyStatus(remaining: remaining).text,
                                isActive: safetyStatus(remaining: remaining).isActive,
                                color: safetyStatus(remaining: remaining).color
                            )
                            if !hotSensors.isEmpty {
                                ForEach(hotSensors.prefix(3)) { reading in
                                    Tag(text: "\(reading.sensorID) \(String(format: "%.1f", reading.celsius))°C",
                                        color: DS.Tone.critical)
                                }
                                if hotSensors.count > 3 {
                                    Tag(text: "另有 \(hotSensors.count - 3) 个", color: DS.Tone.critical)
                                }
                            }
                            Spacer(minLength: DS.Space.sm)
                        }

                        // 触发时把「发生了什么」写出来：光一个红点不够，
                        // 用户要知道现在风扇是什么状态。
                        if monitor.isOverEmergencyThreshold {
                            Text("最高温 \(String(format: "%.1f", monitor.hottestCelsius ?? 0))°C，"
                                 + "已达 \(Int(emergencyThreshold))°C 安全阈值。"
                                 + "所有风扇已被强制拉到最大转速。")
                                .font(.callout)
                                .foregroundStyle(DS.Tone.critical)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // 冷却倒计时。冷却期结束前风扇保持最大转速 ——
                        // 这句必须写出来，否则用户会以为温度一降下来
                        // 风扇就回到原转速了。
                        if remaining > 0 {
                            Label("降温冷却中，还剩 \(Int(remaining.rounded())) 秒。"
                                  + "冷却结束前风扇保持最大转速。",
                                  systemImage: "clock.arrow.circlepath")
                                .font(.caption)
                                .foregroundStyle(DS.Tone.caution)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !monitor.isAvailable {
                    Label("兜底判定依赖温度读取，读不到温度时无法生效",
                          systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(DS.Tone.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 传感器

    private var sensorCard: some View {
        SectionCard(
            title: "传感器",
            subtitle: "同名通道显示最高值。",
            symbol: "list.bullet.rectangle",
            accent: DS.Tone.info
        ) {
            if totalSensors == 0 {
                EmptyStateView(
                    title: monitor.isAvailable ? "暂无有效温度读数" : "温度读取不可用",
                    message: monitor.isAvailable
                        ? "这台机器暂时没有读到有效的温度通道。"
                        : "可能是这台机器不提供 IOHID 温度通道，或特权助手尚未就绪。",
                    systemImage: "thermometer.slash"
                )
                .frame(minHeight: 120)
            } else {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    // 空组整组不渲染 —— 本机实测 GPU 与「其它」常常是 0 条，
                    // 显示「GPU (0)」只会让人以为读数丢了。
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
        DisclosureGroup(isExpanded: expansionBinding(for: group)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(readings.sorted { $0.celsius > $1.celsius }) { reading in
                    sensorRow(reading)
                }
            }
        } label: {
            HStack(spacing: DS.Space.sm) {
                Text(group.displayName)
                    .font(.subheadline.weight(.semibold))
                Text("\(readings.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                // 「校准参考」组的读数是校准基准，长期恒定 —— 看着比最高温还高，
                // 用户会以为机器真过热。写清楚它不算进最高温也不触发 90°C 兜底。
                if group == .reference {
                    Text("校准基准，数值固定，不算进最高温，也不触发 90°C 兜底")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func expansionBinding(for group: ThermalSensorGroup) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(group) },
            set: { isExpanded in
                if isExpanded {
                    expandedGroups.insert(group)
                } else {
                    expandedGroups.remove(group)
                }
            }
        )
    }

    private func sensorRow(_ reading: GroupedTemperatureReading) -> some View {
        let band = band(for: Optional(reading.celsius))
        return HStack(spacing: DS.Space.sm) {
            ThresholdDot(celsius: reading.celsius,
                         warnThreshold: warnThreshold,
                         hotThreshold: hotThreshold)
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
            Spacer(minLength: DS.Space.sm)
            Text(String(format: "%.1f", reading.celsius))
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(band.tint ?? Color.primary)
            Text("°C")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(band.text)
                .font(.caption2)
                .foregroundStyle(band.tint ?? Color.primary)
                .frame(width: 28, alignment: .leading)
        }
        .padding(.vertical, DS.Space.xs)
    }

    // MARK: - 分档阈值

    private var bandCard: some View {
        SectionCard(
            title: "温度分档",
            subtitle: nil,
            symbol: "slider.horizontal.below.rectangle",
            accent: DS.Tone.caution
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                thresholdRow(
                    title: "提示阈值",
                    value: "\(Int(warnThreshold)) °C"
                ) {
                    Slider(value: $warnThreshold,
                           in: ThThermalBandDefaults.warnLowerBound...ThThermalBandDefaults.warnUpperBound,
                           step: 1)
                }

                thresholdRow(
                    title: "过热阈值",
                    value: "\(Int(hotThreshold)) °C"
                ) {
                    Slider(value: $hotThreshold,
                           in: ThThermalBandDefaults.hotLowerBound...ThThermalBandDefaults.hotUpperBound,
                           step: 1)
                }

                LabeledContent("紧急阈值") {
                    HStack(spacing: DS.Space.sm) {
                        Text("\(Int(emergencyThreshold)) °C")
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .monospacedDigit()
                        Tag(text: "固定值", color: DS.Tone.idle)
                    }
                }
            }
        }
    }

    /// 一行阈值：标题 + 当前值 + 滑杆。
    private func thresholdRow(title: String,
                              value: String,
                              @ViewBuilder slider: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            LabeledContent(title) {
                Text(value)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
            }
            slider()
        }
    }

    // MARK: - 派生数据

    private var totalSensors: Int {
        monitor.groupedReadings.values.reduce(0) { $0 + $1.count }
    }

    private var emergencyThreshold: Double {
        FanControl.emergencyTemperatureCelsius
    }

    /// 某一组里的最高读数。没有读数的组返回 nil —— 那一格整格不渲染。
    private func groupMax(_ group: ThermalSensorGroup) -> Double? {
        monitor.groupedReadings[group]?.map(\.celsius).max()
    }

    /// 达到或超过紧急阈值的传感器（按温度从高到低）。
    private var hotSensors: [GroupedTemperatureReading] {
        monitor.groupedReadings.values
            .flatMap { $0 }
            .filter { $0.celsius >= emergencyThreshold }
            .sorted { $0.celsius > $1.celsius }
    }

    /// 兜底解除后的冷却剩余秒数。
    ///
    /// 从兜底事件历史推导：最近一次已解除的事件若还在冷却窗口内，
    /// 说明风扇仍被按在最大转速上，界面要如实显示，不能装作已经恢复。
    private func cooldownRemaining(at now: Date) -> TimeInterval {
        guard let last = FanController.shared.emergencyEvents.first,
              let released = last.releasedAt else { return 0 }
        let elapsed = now.timeIntervalSince(released)
        return max(0, FanControl.emergencyCooldownSeconds - elapsed)
    }

    /// 兜底卡的状态。颜色 + 文字双编码：只有「紧急 / 注意 / 正常」三档，
    /// 每一档都必须带一个字，光靠颜色区分不了「正在降速」和「正在冷却」。
    private func safetyStatus(remaining: TimeInterval) -> (text: String, isActive: Bool, color: Color) {
        if monitor.isOverEmergencyThreshold {
            return ("紧急 · 已触发", true, DS.Tone.critical)
        }
        if remaining > 0 {
            return ("注意 · 降温冷却中", true, DS.Tone.caution)
        }
        return ("正常 · 未触发", false, DS.Tone.good)
    }

    private var summaryTint: Color {
        band(for: monitor.hottestCelsius).tint ?? DS.Tone.idle
    }

    private func updatedText(now: Date) -> String {
        guard let updated = monitor.lastUpdatedAt else { return "尚未采样" }
        let seconds = Int(now.timeIntervalSince(updated))
        if seconds < 2 { return "刚刚更新" }
        if seconds < 60 { return "\(seconds) 秒前更新" }
        return updated.formatted(date: .omitted, time: .standard)
    }

    /// 温度分档 —— 颜色 + 状态词同时给出。
    ///
    /// 四档：正常 / 偏高 / 过高 / 紧急。阈值来自本页的提示与过热设定，
    /// 紧急档固定来自安全兜底的 90°C。
    ///
    /// 「正常」用主色（tint 为 nil）：一屏读数多半都正常，全绿反而吵。
    /// 偏高用黄色 —— DS.Tone 里没有这一档的语义色（只有好/注意/危险），
    /// 而四档必须彼此可分，黄色是「注意但还没到危险」这一档唯一的落点。
    /// 一档温度。
    ///
    /// **用具名结构体，不用具组**：(text, tint: Color?) 这种「元组里套可选」
    /// 的形状在 Release 的全模块优化下会让 Swift 编译器崩掉
    /// （SIL 所有权校验报错，fatal error encountered during compilation）。
    /// 换成就一个普通结构体，问题消失。
    struct Band {
        let text: String
        /// 正常档没有颜色 —— 一屏读数全绿反而看不出重点。
        let tint: Color?
    }

    private func band(for celsius: Double?) -> Band {
        guard let celsius else { return Band(text: "无读数", tint: DS.Tone.idle) }
        if celsius >= emergencyThreshold { return Band(text: "紧急", tint: DS.Tone.critical) }
        if celsius >= hotThreshold { return Band(text: "过高", tint: DS.Tone.caution) }
        if celsius >= warnThreshold { return Band(text: "偏高", tint: Color.yellow) }
        return Band(text: "正常", tint: nil)
    }
}

// MARK: - 组件

/// 温度分档小圆点。颜色只是辅助，状态词才是判定依据。
struct ThresholdDot: View {
    let celsius: Double
    /// 提示阈值。超过它这一档是「偏高」。
    var warnThreshold: Double = ThThermalBandDefaults.warn
    /// 过热阈值。超过它这一档是「过高」。
    var hotThreshold: Double = ThThermalBandDefaults.hot

    private var color: Color {
        if celsius >= FanControl.emergencyTemperatureCelsius { return DS.Tone.critical }
        if celsius >= hotThreshold { return DS.Tone.caution }
        if celsius >= warnThreshold { return Color.yellow }
        return DS.Tone.good.opacity(0.65)
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}
