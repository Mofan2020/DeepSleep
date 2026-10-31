//
//  MonitoringView.swift
//  Deep Sleep
//
//  系统监控设置页：顶部实时状态（CPU / RAM / 磁盘 / 温度），下面才是阈值与告警。
//
//  v1.7.3 起：
//   - 顶部新增「系统状态」卡：CPU%、RAM%、根卷用量、CPU 温度、Top 3 占用进程。
//     数据源：
//       - CPU / RAM / Top 3 / CPU 温度 → SystemMonitor.liveSnapshot()
//         （SystemMonitor 内部已经 3 秒一次 tick + 5 tick 一次 SMC）
//       - 磁盘 → DiskUsage.current()（独立读取，与监控是否启用无关）
//     UI 每秒 Tick 重新拉，1 秒粒度足够人眼看。
//   - 「过载时自动冻结 Top 3」toggle 在服务器模式下强制为 false + 灰：
//     服务器模式期间不主动冻结进程（这条已有约束现在也在 UI 上明确）。
//
//  v1.4.1 修：config 之前是 @State 默认值，切页或重启都丢，
// 「保存设置」按钮没用。改用 MonitorConfig.load() 在 onAppear 读，
// onChange 写。任何字段变化立即落盘，不再依赖「保存设置」按钮。
//

import SwiftUI

struct MonitoringView: View {

    @EnvironmentObject private var sleep: SleepController
    @State private var config: MonitorConfig = .default
    @State private var helperStatus: String = "未探测"
    @State private var lastEventDescription: String = "无"
    @State private var lastEventAt: Date?

    /// 顶部状态卡用的实时快照。`refreshTick` 每秒自增触发重读。
    @State private var snapshot: SystemMonitor.LiveSnapshot = .init(
        ramPercent: 0, cpuPercent: 0, cpuTempC: nil, topThree: [], updatedAt: .distantPast
    )
    @State private var diskSample: DiskUsage.Sample = .empty
    @State private var refreshTick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            liveStatusCard

            monitoringControlCard

            thresholdCard

            statusCard

            Spacer(minLength: 0)
        }
        .onAppear {
            config = MonitorConfig.load()
            SystemMonitor.shared.updateConfig(config)
            refreshLastEvent()
            Task {
                await refreshLiveSnapshot()
                diskSample = DiskUsage.current()
                await probeAndMaybeShowHint()
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refreshTick += 1
            refreshLastEvent()
            // 监控已启用时，SystemMonitor 已经在 3 秒一次拉数据；
            // UI 每秒 Tick 直接读 liveSnapshot() 即可，不会反向触发网络/IO。
            Task { await refreshLiveSnapshot() }
            // 磁盘读 1 次/秒 OK，URL.resourceValues 是纯内核 syscall。
            diskSample = DiskUsage.current()
        }
    }

    // MARK: - 顶部「系统状态」

    private var liveStatusCard: some View {
        SectionCard(
            title: "系统状态",
            subtitle: liveStatusSubtitle,
            symbol: "gauge.with.dots.needle.50percent",
            accent: .accentColor
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 18) {
                    metricBlock(
                        title: "CPU",
                        value: snapshot.cpuPercent > 0
                            ? String(format: "%.0f%%", snapshot.cpuPercent)
                            : "—",
                        caption: "全机累计（whole-CPU）",
                        tint: cpuColor
                    )
                    Divider().frame(height: 36)
                    metricBlock(
                        title: "内存",
                        value: snapshot.ramPercent > 0
                            ? String(format: "%.0f%%", snapshot.ramPercent)
                            : "—",
                        caption: "RSS 累计 / 物理内存",
                        tint: ramColor
                    )
                    Divider().frame(height: 36)
                    metricBlock(
                        title: "CPU 温度",
                        value: snapshot.cpuTempC.map { String(format: "%.1f°C", $0) } ?? "—",
                        caption: temperatureCaption,
                        tint: cpuTempColor
                    )
                    Divider().frame(height: 36)
                    metricBlock(
                        title: "磁盘（根卷）",
                        value: diskSample.isEmpty
                            ? "—"
                            : String(format: "%.0f%%", diskSample.usedFraction * 100),
                        caption: diskCaption,
                        tint: diskColor
                    )
                }

                if !snapshot.topThree.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top 3 CPU 占用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(snapshot.topThree.enumerated()), id: \.offset) { idx, record in
                            HStack(spacing: 6) {
                                Text("\(idx + 1).")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 18, alignment: .trailing)
                                Text(record.name)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                Text(String(format: "%.0f%%", record.cpuPercent))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if snapshot.isStale {
                    Label("数据未刷新（监控尚未启用或尚未跑过一次 tick）",
                          systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func metricBlock(title: String, value: String, caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(tint)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveStatusSubtitle: String {
        if !config.enabled { return "监控未启用。下面是最近一次采样的快照，不再刷新。" }
        if snapshot.updatedAt == .distantPast {
            return "已启用，等待第一次采样。"
        }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "已启用，每 3 秒采样一次；当前显示 \(f.string(from: snapshot.updatedAt)) 的数据。"
    }

    private var cpuColor: Color {
        let v = snapshot.cpuPercent
        if v >= config.cpuHighPercent { return .orange }
        if v > 0 { return .primary }
        return .secondary
    }

    private var ramColor: Color {
        let v = snapshot.ramPercent
        if v >= config.ramHighPercent { return .orange }
        if v > 0 { return .primary }
        return .secondary
    }

    private var cpuTempColor: Color {
        guard let t = snapshot.cpuTempC, config.cpuTempHighCelsius > 0 else {
            return .secondary
        }
        return t >= config.cpuTempHighCelsius ? .orange : .primary
    }

    /// 温度那一格的副标题。
    ///
    /// 读不到数时要说清是「没读到」还是「功能关着」—— 两者的处置完全不同：
    /// 前者要去查助手，后者在界面上改开关就行。
    private var temperatureCaption: String {
        if !config.cpuTempEnabled { return "已关闭" }
        guard snapshot.cpuTempC != nil else { return "助手未就绪时读不到" }
        return "最高传感器读数"
    }

    private var diskColor: Color {
        guard !diskSample.isEmpty else { return .secondary }
        let f = diskSample.usedFraction
        if f >= 0.9 { return .orange }
        if f >= 0.75 { return .yellow }
        return .primary
    }

    private var diskCaption: String {
        guard !diskSample.isEmpty else { return "读取失败" }
        let used = ByteCountFormatter.string(fromByteCount: Int64(diskSample.usedBytes), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(diskSample.totalBytes), countStyle: .file)
        return "\(used) / \(total)"
    }

    // MARK: - 「系统监控」开关

    private var monitoringControlCard: some View {
        SectionCard(
            title: "系统监控",
            subtitle: "总开关。关闭后下面所有阈值都不生效，也不会触发任何告警。",
            symbol: "gauge.with.dots.needle.bottom.50percent",
            accent: .accentColor
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("启用系统监控", isOn: $config.enabled)
                    .onChange(of: config) { _, newConfig in
                        newConfig.saveIfNotDefault()
                        SystemMonitor.shared.updateConfig(newConfig)
                        if newConfig.enabled {
                            SystemMonitor.shared.start()
                            Task { await probeAndMaybeShowHint() }
                        }
                    }
                Text("监控每 \(Int(config.sampleIntervalSeconds)) 秒抓一次进程快照；"
                     + "对整体 RAM / CPU 持续超阈则提示冻结或终结 Top 3 占用者；"
                     + "对单进程 RAM 超过阈值则立刻提示；"
                     + "CPU 温度超阈时只告警，不冻结进程。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 阈值（含 autoSuspend 服务模式禁用）

    private var thresholdCard: some View {
        SectionCard(
            title: "阈值",
            subtitle: nil,
            symbol: "slider.horizontal.below.rectangle",
            accent: .orange
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("RAM 使用率阈值")
                    Spacer()
                    Text("\(Int(config.ramHighPercent))%")
                        .monospacedDigit()
                }
                Slider(value: $config.ramHighPercent, in: 50...99)
                HStack {
                    Text("累计 CPU 阈值")
                    Spacer()
                    Text("\(Int(config.cpuHighPercent))%")
                        .monospacedDigit()
                }
                Slider(value: $config.cpuHighPercent, in: 0...100)
                Stepper("持续超过 \(config.highDurationSeconds) 秒才告警",
                        value: $config.highDurationSeconds,
                        in: 10...600, step: 10)
                HStack {
                    Text("采样间隔")
                    Spacer()
                    Text("\(config.sampleIntervalSeconds, specifier: "%.0f") 秒")
                }
                Slider(value: $config.sampleIntervalSeconds, in: 1...10, step: 1)
                Stepper(value: Binding(
                    get: { Double(config.singleProcessRAMBytes) / 1_073_741_824 },
                    set: { config.singleProcessRAMBytes = Int($0 * 1_073_741_824) }
                ), in: 0.5...32, step: 0.5) {
                    Text(String(format: "单进程 RAM 上限 %.2f GB（任一进程达到即立刻告警）",
                                  Double(config.singleProcessRAMBytes) / 1_073_741_824))
                }

                Divider()

                autoSuspendToggle

                if sleep.isServerModeActive {
                    Label(
                        "服务器模式期间不冻结进程 —— 冻结后台服务可能造成任务失败。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }

                Divider()

                Toggle("CPU 温度告警", isOn: $config.cpuTempEnabled)
                    .help("任一传感器达到阈值就告警。温度读数来自 IOHID 私有温度事件通道，"
                          + "与 90°C 风扇兜底同一份数据。\n"
                          + "这一档只告警，不冻结进程 —— 温度问题不是杀进程能解决的。")
                HStack {
                    Text("CPU 温度阈值")
                    Spacer()
                    Text(String(format: "%.0f°C", config.cpuTempHighCelsius))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $config.cpuTempHighCelsius, in: 40...105, step: 1)
                Text("温度达到 \(Int(config.cpuTempHighCelsius))°C 就告警。"
                     + "告警时只发通知与邮件，不会冻结进程。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: config) { _, newConfig in
                newConfig.saveIfNotDefault()
            }
        }
    }

    /// 「过载时自动冻结 Top 3」toggle。
    ///
    /// v1.7.3 起：服务器模式开启时强制为 false + 灰。
    /// 用户原话：「服务器模式开启时，那个自动处理top3按钮的复选框直接变为未勾选且变灰」。
    /// 与 MonitoringCoordinator.handle 里的 server-mode 跳过冻结逻辑保持一致
    /// （MonitoringCoordinator 是「不弹按钮」，UI 是「不让勾选」—— 双保险）。
    private var autoSuspendToggle: some View {
        let binding = Binding<Bool>(
            get: {
                // 服务器模式期间永远返回 false；存储值还在（关闭服务器模式会恢复）
                if sleep.isServerModeActive { return false }
                return config.autoSuspend
            },
            set: { newValue in
                guard !sleep.isServerModeActive else { return }
                config.autoSuspend = newValue
                config.saveIfNotDefault()
            }
        )

        return Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 1) {
                Text("过载时自动冻结 Top 3")
                    .font(.body)
                Text(sleep.isServerModeActive
                     ? "服务器模式已开启：冻结禁用（关闭服务器模式后可恢复）"
                     : "必须显式开启；否则只会弹对话框让用户决定")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(sleep.isServerModeActive)
    }

    // MARK: - 状态卡（助手 / 最近事件）

    private var statusCard: some View {
        SectionCard(
            title: "状态",
            subtitle: nil,
            symbol: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("助手协议", value: helperStatus)
                LabeledContent("最近事件", value: lastEventDescription)
            }
            .font(.system(.body, design: .monospaced))
        }
    }

    // MARK: - 内部

    private func refreshLastEvent() {
        if let pair = SystemMonitor.shared.lastEventDescription() {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            lastEventDescription = "\(pair.description) @ \(formatter.string(from: pair.date))"
        } else {
            lastEventDescription = "无"
        }
    }

    /// 拉 SystemMonitor 的实时快照。SystemMonitor 内部已 tick，
    /// 这里只同步读它的内部状态；不会反向触发起停。
    @MainActor
    private func refreshLiveSnapshot() async {
        snapshot = SystemMonitor.shared.liveSnapshot()
    }

    private func probeAndMaybeShowHint() async {
        let probe = await HelperClient.shared.probe()
        if !probe.reachable {
            helperStatus = "未安装 / 不可用"
        } else if let v = probe.protocolVersion, v >= 2 {
            helperStatus = "v\(v)（已就绪）"
            ProcessStatsProvider.shared.resetVersionCache()
        } else {
            helperStatus = "v\(probe.protocolVersion ?? 0)（需要更新）"
        }
    }
}
