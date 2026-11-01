//
//  MonitoringView.swift
//  Deep Sleep
//
//  系统监控页：实时总览 + 60 秒趋势 + 每核心 CPU + 内存明细 + 磁盘卷 +
//  进程排行，下面才是阈值与告警设置。
//
//  数据来源分两条，节奏不同：
//   - 每秒一次：SystemMetricsCollector（本机内核读，1 秒）。
//     CPU 曲线 / 内存曲线 / 每核占用 / 内存明细 / 卷 / 网络速率 / 负载 / 开机时长。
//   - 三秒一次：SystemMonitor.liveSnapshot()（走特权助手拿进程快照）。
//     进程排行与整机累计口径来自这里；助手不可用时这些项显示「不可用」。
//
//  为什么曲线用本机采样而不是助手：助手一次快照要 3~5 秒，拿来喂
//  每秒一个点的曲线会变成台阶。曲线的目的是看趋势，1 秒粒度才有意义；
//  进程排行仍然只认助手的数据（那需要 root 才能读别人的进程）。
//

import SwiftUI
import Charts

struct MonitoringView: View {

    @EnvironmentObject private var sleep: SleepController
    @State private var config: MonitorConfig = .default
    /// 面板自己的显示阈值（独立 UserDefaults 键，不进 MonitorConfig）。
    @State private var metricThresholds: SystemMetrics.MetricThresholds = .default
    @State private var helperStatus: String = "未探测"
    @State private var lastEventDescription: String = "无"
    @State private var lastEventAt: Date?

    /// 每秒 Tick 会刷新这张快照。
    @State private var snapshot: SystemMonitor.LiveSnapshot = .init(
        ramPercent: 0, cpuPercent: 0, cpuTempC: nil, topThree: [], updatedAt: .distantPast
    )
    /// 最近 60 秒的采样点，每秒追加一个，满了丢最旧的。
    @State private var history = SystemMetrics.MetricHistory(capacity: 60)
    @State private var refreshTick: Int = 0

    /// 进程排行的排序口径。
    @State private var processSort: ProcessSort = .cpu
    /// 监控总开关关着时，面板自己向助手要一份进程排行（5 秒一次）。
    @State private var fetchedTopByCPU: [ProcessStats.Record] = []
    @State private var fetchedTopByMemory: [ProcessStats.Record] = []
    @State private var lastProcessFetchAt: Date = .distantPast
    @State private var isFetchingProcesses = false

    private enum ProcessSort: String, CaseIterable, Identifiable {
        case cpu = "按 CPU"
        case memory = "按内存"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            liveStatusCard

            trendCard

            if !snapshot.perCoreCPUPercent.isEmpty {
                coreUsageCard
            }

            memoryCard

            diskCard

            processCard

            monitoringControlCard

            thresholdCard

            statusCard

            Spacer(minLength: 0)
        }
        .onAppear {
            config = MonitorConfig.load()
            metricThresholds = .load()
            SystemMonitor.shared.updateConfig(config)
            // 面板的实时数据不依赖「系统监控」总开关 —— 打开页面就开始采。
            SystemMetricsCollector.shared.start()
            refreshLastEvent()
            Task {
                await refreshLiveSnapshot()
                appendHistoryPoint()
                await probeAndMaybeShowHint()
                await refreshProcessListIfNeeded(force: true)
            }
        }
        .onDisappear {
            // 离开页面就停采，不给后台留每秒一次的定时器。
            SystemMetricsCollector.shared.stop()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refreshTick += 1
            refreshLastEvent()
            Task {
                await refreshLiveSnapshot()
                appendHistoryPoint()
                await refreshProcessListIfNeeded()
            }
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
                HStack(alignment: .top, spacing: 18) {
                    metricBlock(
                        title: "CPU",
                        value: cpuPercentText,
                        caption: "整机 0–100%（全核合计）",
                        tint: cpuColor
                    )
                    Divider().frame(height: 36)
                    metricBlock(
                        title: "内存",
                        value: memoryPercentText,
                        caption: "已用 / 物理内存",
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
                        value: rootVolumePercentText,
                        caption: rootVolumeCaption,
                        tint: rootVolumeColor
                    )
                }

                Divider()

                HStack(alignment: .top, spacing: 18) {
                    readoutBlock(
                        title: "负载均值",
                        value: loadAverageText,
                        caption: "1 / 5 / 15 分钟"
                    )
                    Divider().frame(height: 28)
                    readoutBlock(
                        title: "已开机",
                        value: snapshot.uptimeSeconds.map { SystemMetrics.formatDuration($0) } ?? "不可用",
                        caption: uptimeCaption
                    )
                    Divider().frame(height: 28)
                    readoutBlock(
                        title: "热压力",
                        value: snapshot.thermalState?.displayName ?? "不可用",
                        caption: "系统热压力等级"
                    )
                    Divider().frame(height: 28)
                    readoutBlock(
                        title: "网络",
                        value: networkText,
                        caption: "所有物理网卡合计"
                    )
                }

                if snapshot.isStale {
                    Label("进程与整机累计读数还没有新采样（监控未启用或助手未就绪）；"
                          + "上面的 CPU / 内存 / 磁盘来自本机实时采样。",
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

    private func readoutBlock(title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveStatusSubtitle: String {
        if !config.enabled {
            return "监控未启用：CPU / 内存 / 磁盘等本机读数照常刷新，进程排行与告警不采样。"
        }
        if snapshot.updatedAt == .distantPast {
            return "已启用，等待第一次采样。"
        }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "已启用，每 \(Int(config.sampleIntervalSeconds)) 秒采样一次；"
            + "当前显示 \(f.string(from: snapshot.updatedAt)) 的进程快照。"
    }

    // MARK: - 趋势曲线

    private var trendCard: some View {
        SectionCard(
            title: "最近 60 秒",
            subtitle: "每秒一个采样点，从左上往右下走的是时间——越靠右越新。曲线只画趋势，不参与告警判定。",
            symbol: "chart.xyaxis.line",
            accent: .blue
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Tag(text: "CPU", color: .accentColor)
                    Tag(text: "内存（已用）", color: .purple)
                    Spacer()
                    Text("0–100%")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if history.samples.count >= 2 {
                    Chart {
                        // X 轴必须用采集时刻，不能用数组下标。
                        //
                        // 缓冲满了之后每采一个新点就会丢掉最旧的那个，整个数组
                        // 左移一格 —— 下标当 X 轴的话，整条曲线会跟着重新编号，
                        // 看上去就是在往回缩、在乱画。
                        //
                        // 两条线必须各自带 series：同一次循环里画两条 LineMark
                        // 而不区分 series，Charts 会把它们当成同一条线的点，
                        // CPU 的点与内存的点交替相连，画出来的是一条来回折返的
                        // 锯齿 —— 内存那条自然也就"看不见"了。
                        ForEach(history.samples, id: \.timestamp) { point in
                            LineMark(
                                x: .value("时刻", point.timestamp),
                                y: .value("占用率", point.cpuPercent),
                                series: .value("指标", "CPU")
                            )
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.monotone)

                            LineMark(
                                x: .value("时刻", point.timestamp),
                                y: .value("占用率", point.memoryPercent),
                                series: .value("指标", "内存")
                            )
                            .foregroundStyle(Color.purple)
                            .interpolationMethod(.monotone)
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis(.hidden)
                    // 图例是上面手写的那两个 Tag，别再来一份系统图例。
                    .chartLegend(.hidden)
                    .chartYAxis {
                        AxisMarks(values: [0, 50, 100])
                    }
                    .frame(height: 150)
                } else {
                    Text("正在采集，两秒后出曲线。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: 60)
                }
            }
        }
    }

    // MARK: - 每核心 CPU

    private var coreUsageCard: some View {
        SectionCard(
            title: "每核心 CPU",
            subtitle: "每秒一次 tick 差分；颜色随占用率变化。",
            symbol: "cpu",
            accent: .teal
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(snapshot.perCoreCPUPercent.enumerated()), id: \.offset) { index, value in
                        VStack(spacing: 4) {
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.secondary.opacity(0.12))
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(coreColor(for: value))
                                    // 至少 2pt：0% 也留一条底线，别让核「消失」。
                                    .frame(height: max(2, 56 * min(max(value, 0), 100) / 100))
                            }
                            .frame(height: 56)

                            Text("\(index)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                HStack(spacing: 6) {
                    Tag(text: "峰值 \(String(format: "%.0f%%", corePeak))", color: coreColor(for: corePeak))
                    Tag(text: "均值 \(String(format: "%.0f%%", coreAverage))", color: .secondary)
                    Tag(text: "\(snapshot.perCoreCPUPercent.count) 核", color: .secondary)
                    Spacer()
                }
            }
        }
    }

    private var corePeak: Double {
        snapshot.perCoreCPUPercent.max() ?? 0
    }

    private var coreAverage: Double {
        guard !snapshot.perCoreCPUPercent.isEmpty else { return 0 }
        return snapshot.perCoreCPUPercent.reduce(0, +) / Double(snapshot.perCoreCPUPercent.count)
    }

    // MARK: - 内存明细

    private var memoryCard: some View {
        SectionCard(
            title: "内存明细",
            subtitle: "口径与活动监视器一致：已用 = 应用 + 联动 + 压缩。",
            symbol: "memorychip",
            accent: .purple
        ) {
            if let memory = snapshot.memoryDetail {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("已用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f%%", memory.usedPercent))
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .foregroundStyle(memory.usedPercent >= config.ramHighPercent ? .orange : .primary)
                        Spacer()
                        Text("\(SystemMetrics.formatMemoryBytes(memory.usedBytes))"
                             + " / \(SystemMetrics.formatMemoryBytes(memory.totalBytes))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    memoryStackedBar(memory)

                    VStack(spacing: 6) {
                        memoryRow("应用占用", bytes: memory.appBytes, percent: memory.appPercent, color: .blue)
                        memoryRow("联动（wired）", bytes: memory.wiredBytes, percent: memory.wiredPercent, color: .orange)
                        memoryRow("压缩", bytes: memory.compressedBytes, percent: memory.compressedPercent, color: .purple)
                        memoryRow("缓存", bytes: memory.cachedBytes, percent: memory.cachedPercent, color: .teal)
                        memoryRow("空闲", bytes: memory.freeBytes, percent: memory.freePercent, color: .secondary)
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Text("物理内存合计")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(SystemMetrics.formatMemoryBytes(memory.totalBytes))
                            .font(.system(.caption, design: .monospaced))
                    }
                    HStack(spacing: 8) {
                        Text("交换空间")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if memory.swapTotalBytes > 0 {
                            Text("\(SystemMetrics.formatMemoryBytes(memory.swapUsedBytes))"
                                 + " / \(SystemMetrics.formatMemoryBytes(memory.swapTotalBytes))"
                                 + "（\(String(format: "%.0f%%", memory.swapPercent))）")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(memory.swapPercent >= 90 ? Color.orange : Color.secondary)
                        } else {
                            Text("未启用")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("不可用：读不到 vm_statistics64。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 一条堆叠条：宽度按占物理内存的比例算，没被归类的那部分留成空槽。
    private func memoryStackedBar(_ memory: SystemMetrics.MemoryBreakdown) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                segment(memory.appPercent, total: geo.size.width, color: .blue)
                segment(memory.wiredPercent, total: geo.size.width, color: .orange)
                segment(memory.compressedPercent, total: geo.size.width, color: .purple)
                segment(memory.cachedPercent, total: geo.size.width, color: .teal)
                segment(memory.freePercent, total: geo.size.width, color: .secondary.opacity(0.3))
            }
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(height: 14)
    }

    private func segment(_ percent: Double, total: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(0, total * min(max(percent, 0), 100) / 100))
    }

    private func memoryRow(_ title: String, bytes: UInt64, percent: Double, color: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(SystemMetrics.formatMemoryBytes(bytes))
                .font(.system(.caption, design: .monospaced))
            Text(String(format: "%.1f%%", percent))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    // MARK: - 磁盘卷

    private var diskCard: some View {
        SectionCard(
            title: "磁盘",
            subtitle: snapshot.volumes.isEmpty ? nil : "只列用户可见的卷与根卷，系统内部卷不展开。",
            symbol: "internaldrive",
            accent: .orange
        ) {
            if snapshot.volumes.isEmpty {
                Text("不可用：读不到已挂载卷。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(snapshot.volumes.enumerated()), id: \.offset) { _, volume in
                        volumeRow(volume)
                    }
                }
            }
        }
    }

    private func volumeRow(_ volume: SystemMetrics.DiskVolume) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: volume.isRemovable ? "sdcard" : "internaldrive")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(volume.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if volume.isRemovable {
                    Tag(text: "可移除", color: .orange)
                }
                Text(volume.mountPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(volumeDetailText(volume))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(volumeColor(volume))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                    if let fraction = volume.usedFraction {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(volumeColor(volume))
                            .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
                    }
                }
            }
            .frame(height: 7)
        }
    }

    private func volumeDetailText(_ volume: SystemMetrics.DiskVolume) -> String {
        guard let used = volume.usedBytes, let fraction = volume.usedFraction else {
            return "\(SystemMetrics.formatBytes(volume.totalBytes)) · 可用量不可用"
        }
        return "\(SystemMetrics.formatBytes(used)) / \(SystemMetrics.formatBytes(volume.totalBytes))"
            + "（\(String(format: "%.0f%%", fraction * 100))）"
    }

    private func volumeColor(_ volume: SystemMetrics.DiskVolume) -> Color {
        guard let fraction = volume.usedFraction else { return .secondary }
        let percent = fraction * 100
        if percent >= metricThresholds.diskUsagePercent { return .orange }
        if percent >= 75 { return .yellow }
        return .primary
    }

    // MARK: - 进程排行

    private var processCard: some View {
        SectionCard(
            title: "进程排行",
            subtitle: "数据来自特权助手的进程快照；面板不另起扫描。",
            symbol: "list.number",
            accent: .green
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $processSort) {
                    ForEach(ProcessSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)

                let rows = currentProcessRows
                if rows.isEmpty {
                    Text(config.enabled
                         ? "暂不可用：需要助手返回进程快照（未安装 / 版本过旧 / 刚启动）。"
                         : "未启用系统监控时不主动抓进程快照；打开上面的「启用系统监控」后这里会出数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 5) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, record in
                            processRow(index: index, record: record)
                        }
                    }
                }
            }
        }
    }

    private var currentProcessRows: [ProcessStats.Record] {
        if config.enabled {
            return processSort == .cpu ? snapshot.topByCPU : snapshot.topByMemory
        }
        return processSort == .cpu ? fetchedTopByCPU : fetchedTopByMemory
    }

    private func processRow(index: Int, record: ProcessStats.Record) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .trailing)
            Text(record.name)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("pid \(record.pid)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if processSort == .cpu {
                Text(String(format: "%.1f%%", record.cpuPercent))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(record.cpuPercent >= config.cpuHighPercent ? Color.orange : Color.secondary)
            } else {
                Text(SystemMetrics.formatMemoryBytes(record.rssBytes))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Int(record.rssBytes) >= config.singleProcessRAMBytes
                                     ? Color.orange : Color.secondary)
            }
        }
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

                Divider()

                panelThresholdSection
            }
            .onChange(of: config) { _, newConfig in
                newConfig.saveIfNotDefault()
            }
        }
    }

    /// 面板高亮阈值。只改颜色，不触发告警 —— 告警阈值在上面那一组。
    private var panelThresholdSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("面板高亮线")
                .font(.callout.weight(.medium))
            Text("只决定面板上的颜色，不参与告警判定；改动立刻保存。")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack {
                Text("磁盘用量")
                Spacer()
                Text("\(Int(metricThresholds.diskUsagePercent))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $metricThresholds.diskUsagePercent, in: 50...99, step: 1)

            HStack {
                Text("单核 CPU 占用")
                Spacer()
                Text("\(Int(metricThresholds.coreCPUPercent))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $metricThresholds.coreCPUPercent, in: 50...100, step: 1)

            HStack {
                Text("网络速率")
                Spacer()
                Text(String(format: "%.0f MB/s", metricThresholds.networkBytesPerSecond / 1_048_576))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { metricThresholds.networkBytesPerSecond / 1_048_576 },
                set: { metricThresholds.networkBytesPerSecond = $0 * 1_048_576 }
            ), in: 1...100, step: 1)
        }
        .onChange(of: metricThresholds) { _, newValue in
            newValue.saveIfNotDefault()
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

    // MARK: - 取值与配色

    private var cpuPercentText: String {
        if let local = snapshot.localCPUPercent {
            return String(format: "%.0f%%", local)
        }
        if !snapshot.isStale { return String(format: "%.0f%%", snapshot.cpuPercent) }
        return "—"
    }

    private var cpuColor: Color {
        let value = snapshot.localCPUPercent ?? (snapshot.isStale ? 0 : snapshot.cpuPercent)
        if value >= config.cpuHighPercent { return .orange }
        if value > 0 { return .primary }
        return .secondary
    }

    private var memoryPercentText: String {
        if let memory = snapshot.memoryDetail {
            return String(format: "%.0f%%", memory.usedPercent)
        }
        if !snapshot.isStale { return String(format: "%.0f%%", snapshot.ramPercent) }
        return "—"
    }

    private var ramColor: Color {
        let value = snapshot.memoryDetail?.usedPercent ?? (snapshot.isStale ? 0 : snapshot.ramPercent)
        if value >= config.ramHighPercent { return .orange }
        if value > 0 { return .primary }
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

    private var rootVolume: SystemMetrics.DiskVolume? {
        snapshot.volumes.first { $0.mountPath == "/" }
    }

    private var rootVolumePercentText: String {
        guard let fraction = rootVolume?.usedFraction else { return "—" }
        return String(format: "%.0f%%", fraction * 100)
    }

    private var rootVolumeCaption: String {
        guard let volume = rootVolume else { return "读取失败" }
        guard let used = volume.usedBytes else {
            return "\(SystemMetrics.formatBytes(volume.totalBytes)) · 可用量不可用"
        }
        return "\(SystemMetrics.formatBytes(used)) / \(SystemMetrics.formatBytes(volume.totalBytes))"
    }

    private var rootVolumeColor: Color {
        guard let fraction = rootVolume?.usedFraction else { return .secondary }
        let percent = fraction * 100
        if percent >= metricThresholds.diskUsagePercent { return .orange }
        if percent >= 75 { return .yellow }
        return .primary
    }

    private var loadAverageText: String {
        guard !snapshot.loadAverage.isEmpty else { return "不可用" }
        return snapshot.loadAverage
            .map { String(format: "%.2f", $0) }
            .joined(separator: " / ")
    }

    private var uptimeCaption: String {
        snapshot.uptimeSeconds == nil ? "读不到 kern.boottime" : "自上次开机"
    }

    private var networkText: String {
        guard let network = snapshot.networkRate else { return "正在采样" }
        return "↓ \(SystemMetrics.formatRate(network.downloadBytesPerSecond))"
            + "  ↑ \(SystemMetrics.formatRate(network.uploadBytesPerSecond))"
    }

    private func coreColor(for value: Double) -> Color {
        if value >= metricThresholds.coreCPUPercent { return .orange }
        if value >= 70 { return .yellow }
        if value >= 30 { return .teal }
        return .green
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

    /// 把当前值追加进 60 点环形缓冲。没有真实读数就不追加 ——
    /// 否则曲线里会出现一段假的 0%。
    @MainActor
    private func appendHistoryPoint() {
        // 同一秒内只留一个点。
        //
        // onAppear 里的第一次追加与定时器的第一拍常常挤在同一帧，
        // 两个点的时间戳会一模一样 —— 曲线的 X 轴与 id 都取时间戳，
        // 重复的键会让这一帧的点被当成同一个，曲线就会抖一下。
        if let last = history.samples.last,
           Date().timeIntervalSince(last.timestamp) < 0.5 {
            return
        }

        let cpu: Double?
        if let local = snapshot.localCPUPercent {
            cpu = local
        } else if !snapshot.isStale {
            cpu = snapshot.cpuPercent
        } else {
            cpu = nil
        }

        let memory: Double?
        if let detail = snapshot.memoryDetail {
            memory = detail.usedPercent
        } else if !snapshot.isStale {
            memory = snapshot.ramPercent
        } else {
            memory = nil
        }

        guard let cpuValue = cpu, let memoryValue = memory else { return }
        history.append(SystemMetrics.HistorySample(
            timestamp: Date(),
            cpuPercent: cpuValue,
            memoryPercent: memoryValue,
            cpuTempCelsius: snapshot.cpuTempC))
    }

    /// 监控总开关关着时，面板自己向助手要一份进程排行（5 秒一次）。
    ///
    /// 开关打开时不走这里 —— SystemMonitor 的 tick 已经在采，
    /// 再采一次等于两倍助手负载，而助手一次快照本身就要 3~5 秒。
    @MainActor
    private func refreshProcessListIfNeeded(force: Bool = false) async {
        guard !config.enabled else { return }
        guard !isFetchingProcesses else { return }
        guard force || Date().timeIntervalSince(lastProcessFetchAt) >= 5 else { return }

        isFetchingProcesses = true
        lastProcessFetchAt = Date()
        defer { isFetchingProcesses = false }

        guard let stats = try? await ProcessStatsProvider.shared.fetchStats(),
              !stats.records.isEmpty else {
            // 失败不清空上一次的结果：助手偶尔一次超时不该让列表整块消失。
            return
        }
        fetchedTopByCPU = Array(stats.records.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(10))
        fetchedTopByMemory = Array(stats.records.sorted { $0.rssBytes > $1.rssBytes }.prefix(10))
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
