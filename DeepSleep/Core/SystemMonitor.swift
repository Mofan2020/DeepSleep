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
//  v1.9.4 起：本文件还多了「轻量系统指标采集器」
//  （SystemMetricsCollector）—— 每秒采一次本机内核接口，给监控面板出数：
//   - 每核心 CPU 占用（host_processor_info）
//   - 内存明细（host_statistics64 + vm.swapusage）
//   - 所有挂载卷容量（FileManager）
//   - 网络上下行速率（getifaddrs 差分）
//   - 负载均值 / 开机时长 / 热压力
//  这些全是本机读，不需要特权助手 —— 面板在助手不可用时照样有数。
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
    /// 最近一次快照里按 CPU 排的 Top 10。
    private var _latestTopByCPU: [ProcessStats.Record] = []
    /// 最近一次快照里按内存（RSS）排的 Top 10。
    private var _latestTopByMemory: [ProcessStats.Record] = []

    /// UI 用的「实时状态快照」。
    ///
    /// 末尾这些字段是 v1.9.4 加的，**全部带默认值** —— 老调用点
    /// `LiveSnapshot(ramPercent:...)` 不用改。前五个字段的名字与语义没动，
    /// `MonitoringCoordinator.currentAlertMetrics()` 依赖它们判定告警。
    public struct LiveSnapshot: Sendable {
        public let ramPercent: Double
        public let cpuPercent: Double
        public let cpuTempC: Double?
        public let topThree: [ProcessStats.Record]
        public let updatedAt: Date

        /// 每核心占用百分比（0–100，顺序即核序号）。读不到时为空数组。
        public var perCoreCPUPercent: [Double] = []
        /// 内存明细（应用 / 联动 / 压缩 / 缓存 / 空闲 / 交换）。
        public var memoryDetail: SystemMetrics.MemoryBreakdown?
        /// 所有用户可见的已挂载卷。
        public var volumes: [SystemMetrics.DiskVolume] = []
        /// 网络上下行速率（字节/秒），由相邻两次计数器差值算出。
        public var networkRate: SystemMetrics.NetworkRate?
        /// 1 / 5 / 15 分钟负载均值。
        public var loadAverage: [Double] = []
        /// 开机时长（秒）。
        public var uptimeSeconds: Double?
        /// 热压力等级。
        public var thermalState: SystemMetrics.ThermalState?
        /// 按 CPU 排的 Top 10 进程（数据来自特权助手，不另起扫描）。
        public var topByCPU: [ProcessStats.Record] = []
        /// 按内存排的 Top 10 进程。
        public var topByMemory: [ProcessStats.Record] = []
        /// 本地 1 秒采样的整机 CPU%（不依赖助手，助手不可用时也有数）。
        public var localCPUPercent: Double?
        /// 最近一次本地采样的时间戳。
        public var localSampledAt: Date?

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
    ///
    /// v1.9.4 起还合并了 `SystemMetricsCollector` 的本地采样（每核心 CPU、
    /// 内存明细、卷、网络速率、负载、开机时长、热压力）—— 这些不依赖助手，
    /// 面板在助手不可用时也照样有数。
    public func liveSnapshot() -> LiveSnapshot {
        let local = SystemMetricsCollector.shared.sample
        return queue.sync {
            var snapshot = LiveSnapshot(
                ramPercent: _latestRamPercent,
                cpuPercent: _latestCpuPercent,
                cpuTempC: _latestCPUTempC,
                topThree: _latestTopThree,
                updatedAt: _latestUpdateAt ?? .distantPast
            )
            snapshot.perCoreCPUPercent = local.perCoreCPUPercent
            snapshot.memoryDetail = local.memory
            snapshot.volumes = local.volumes
            snapshot.networkRate = local.network
            snapshot.loadAverage = local.loadAverage
            snapshot.uptimeSeconds = local.uptimeSeconds
            snapshot.thermalState = local.thermalState
            snapshot.topByCPU = _latestTopByCPU
            snapshot.topByMemory = _latestTopByMemory
            snapshot.localCPUPercent = local.overallCPUPercent
            snapshot.localSampledAt = local.sampledAt == .distantPast ? nil : local.sampledAt
            return snapshot
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
        let byCPU = records.sorted { $0.cpuPercent > $1.cpuPercent }
        _latestTopThree = Array(byCPU.prefix(3))
        // 面板的 Top 10 两种排法都缓存一份：UI 切排序只换数组，不再重排，
        // 也不额外向助手要一次进程快照。
        _latestTopByCPU = Array(byCPU.prefix(10))
        _latestTopByMemory = Array(records.sorted { $0.rssBytes > $1.rssBytes }.prefix(10))
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

// MARK: - 轻量系统指标采集器

/// 每秒一次的本机指标采样。
///
/// 为什么单独一条队列、单独一个类：
///   - `SystemMonitor.tick()` 走特权助手拿进程快照，一次要 3~5 秒，还可能失败；
///     而面板每核心 CPU / 内存明细 / 网络速率这些都是本机内核读，1 秒就够，
///     也能在助手没装时照样出数。两件事的节奏与失败域都不一样，硬塞进 tick 会
///     让面板跟着助手的节奏一起卡。
///   - 采样全部在自己的串行队列上跑，UI 只做 `sample` 的同步读（拷贝一个
///     小 struct），主线程不会被卷枚举 / getifaddrs 这类调用卡住。
///
/// 网络速率是**相邻两次 `sample()` 的差分**，不是累计值：
///   - 第一次调用没有上一轮，速率字段为 nil（UI 显示「正在采样」）；
///   - 计数器回绕（网卡重启）时该轮速率记 0，不给出负数或天文数字。
public final class SystemMetricsCollector: @unchecked Sendable {

    public static let shared = SystemMetricsCollector()

    /// 一次采样的结果。字段缺失一律是 nil / 空数组 —— UI 据此显示「不可用」。
    public struct Sample: Sendable {
        public var perCoreCPUPercent: [Double] = []
        /// 整机 CPU%（各核 tick 加权汇总，口径同 `top` 的 0–100）。
        public var overallCPUPercent: Double?
        public var memory: SystemMetrics.MemoryBreakdown?
        public var volumes: [SystemMetrics.DiskVolume] = []
        public var network: SystemMetrics.NetworkRate?
        public var loadAverage: [Double] = []
        public var uptimeSeconds: Double?
        public var thermalState: SystemMetrics.ThermalState?
        public var sampledAt: Date = .distantPast
    }

    private let queue = DispatchQueue(label: "com.skyc8266.deepsleep.metrics")
    /// 采样结果的读写锁。UI 侧 `sample` 走它，锁持有时间是一次结构体拷贝。
    private let lock = NSLock()
    private var latest = Sample()

    /// 上一轮的每核 tick，用于差分。
    private var previousCoreTicks: [SystemMetrics.CPUTicks] = []
    /// 上一轮的网络累计字节数 + 采样时刻。
    private var previousNetworkTotals: (down: UInt64, up: UInt64, at: Date)?

    private var timer: DispatchSourceTimer?
    private var cachedPageSize: UInt64 = 0
    private var cachedTotalMemory: UInt64 = 0

    public init() {}

    /// 最近一次采样结果。同步读，不触发采集。
    public var sample: Sample {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// 启动每秒采样。重复调用无副作用。
    ///
    /// 与 `SystemMonitor.start()` 解耦：面板要不要实时数据由 UI 决定，
    /// 不取决于「系统监控」总开关是否打开。
    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            // 立刻采一次，别让面板空着等第一秒。
            self.collect()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in
                self?.collect()
            }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            // 清掉差分基准。否则离开页面几分钟再回来，第一次采样会把
            // 这几分钟的总量摊成「一秒的占用」，曲线会突然跳一下。
            self?.previousCoreTicks = []
            self?.previousNetworkTotals = nil
        }
    }

    // MARK: - 采样

    private func collect() {
        let now = Date()
        var snapshot = Sample()
        snapshot.sampledAt = now

        // CPU：每核 tick 差分。
        if let ticks = Self.readCoreTicks() {
            if !previousCoreTicks.isEmpty {
                snapshot.perCoreCPUPercent = SystemMetrics.perCorePercentages(
                    before: previousCoreTicks, after: ticks)
                snapshot.overallCPUPercent = SystemMetrics.overallPercent(
                    before: previousCoreTicks, after: ticks)
            }
            previousCoreTicks = ticks
        }

        snapshot.memory = Self.readMemory(pageSize: pageSize(), totalMemory: totalMemory())
        snapshot.volumes = Self.readVolumes()
        snapshot.loadAverage = Self.readLoadAverage()
        snapshot.uptimeSeconds = Self.readUptime()

        // 热压力：ProcessInfo 在 macOS 上有这个属性，取值正常/偏高/严重/危急。
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  snapshot.thermalState = .nominal
        case .fair:     snapshot.thermalState = .fair
        case .serious:  snapshot.thermalState = .serious
        case .critical: snapshot.thermalState = .critical
        @unknown default: snapshot.thermalState = nil
        }

        // 网络：累计字节数的差分 / 实际间隔。
        if let totals = Self.readNetworkTotals() {
            if let last = previousNetworkTotals {
                let elapsed = now.timeIntervalSince(last.at)
                if elapsed > 0 {
                    let downDelta = totals.down >= last.down ? totals.down - last.down : 0
                    let upDelta = totals.up >= last.up ? totals.up - last.up : 0
                    snapshot.network = SystemMetrics.NetworkRate(
                        downloadBytesPerSecond: Double(downDelta) / elapsed,
                        uploadBytesPerSecond: Double(upDelta) / elapsed)
                }
            }
            previousNetworkTotals = (totals.down, totals.up, now)
        }

        lock.lock()
        latest = snapshot
        lock.unlock()
    }

    private func pageSize() -> UInt64 {
        if cachedPageSize > 0 { return cachedPageSize }
        var value: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.pagesize", &value, &len, nil, 0) == 0 else { return 16_384 }
        cachedPageSize = value
        return value
    }

    private func totalMemory() -> UInt64 {
        if cachedTotalMemory > 0 { return cachedTotalMemory }
        var value: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &value, &len, nil, 0) == 0 else { return 0 }
        cachedTotalMemory = value
        return value
    }

    // MARK: - 内核读数

    /// 每核 tick。`PROCESSOR_CPU_LOAD_INFO` 的 cpu_ticks 顺序是
    /// user / system / idle / nice。
    private static func readCoreTicks() -> [SystemMetrics.CPUTicks]? {
        var processorCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &processorCount, &infoArray, &infoCount)
        guard kr == KERN_SUCCESS, let array = infoArray, processorCount > 0 else { return nil }
        defer {
            // 内核为这块数组分配了内存，必须还回去 —— 每秒一次，
            // 漏掉就是每秒泄漏几百字节。
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: array)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        let count = Int(processorCount)
        return array.withMemoryRebound(to: processor_cpu_load_info.self, capacity: count) { buffer in
            (0..<count).map { index in
                let ticks = buffer[index].cpu_ticks
                return SystemMetrics.CPUTicks(user: UInt64(ticks.0),
                                              system: UInt64(ticks.1),
                                              idle: UInt64(ticks.2),
                                              nice: UInt64(ticks.3))
            }
        }
    }

    /// 内存明细。`vm_statistics64` 的页计数 × 页大小。
    ///
    /// 字段名注意是 `compressor_page_count`（压缩器占用的物理页），
    /// 不是 `compressed_page_count` —— 后者不存在，写错了编译不过。
    private static func readMemory(pageSize: UInt64, totalMemory: UInt64) -> SystemMetrics.MemoryBreakdown? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        var swap = xsw_usage()
        var swapLen = MemoryLayout<xsw_usage>.size
        let swapKr = sysctlbyname("vm.swapusage", &swap, &swapLen, nil, 0)
        let swapUsed = swapKr == 0 ? UInt64(swap.xsu_used) : 0
        let swapTotal = swapKr == 0 ? UInt64(swap.xsu_total) : 0

        let pages = SystemMetrics.memoryPages(
            anonymous: UInt64(stats.internal_page_count),
            external: UInt64(stats.external_page_count),
            wire: UInt64(stats.wire_count),
            compressor: UInt64(stats.compressor_page_count),
            free: UInt64(stats.free_count))

        return SystemMetrics.memoryBreakdown(pages: pages,
                                             pageSize: pageSize,
                                             totalBytes: totalMemory,
                                             swapUsedBytes: swapUsed,
                                             swapTotalBytes: swapTotal)
    }

    /// 已挂载卷。
    ///
    /// 只保留「用户能看见」的卷（browsable）与根卷 ——
    /// `mountedVolumeURLs` 还会返回 /System/Volumes/VM、Preboot、xarts 这些
    /// 系统内部卷，把它们也列出来只会让面板全是噪音。
    private static func readVolumes() -> [SystemMetrics.DiskVolume] {
        let keys: [URLResourceKey] = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeNameKey,
            .volumeIsBrowsableKey,
            .volumeIsRootFileSystemKey,
            .volumeIsRemovableKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys) else {
            return []
        }
        var volumes: [SystemMetrics.DiskVolume] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isRoot = values.volumeIsRootFileSystem ?? false
            let isBrowsable = values.volumeIsBrowsable ?? false
            guard isRoot || isBrowsable else { continue }
            guard let total = values.volumeTotalCapacity, total > 0 else { continue }

            // 优先用「重要用途可用量」（macOS 11+ 的口径，比裸 available 更贴近
            // 用户在「关于本机」里看到的数字）；读不到再退回普通可用量。
            var available: UInt64?
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                available = UInt64(important)
            } else if let plain = values.volumeAvailableCapacity, plain > 0 {
                available = UInt64(plain)
            }

            let name = values.volumeName ?? url.lastPathComponent
            volumes.append(SystemMetrics.DiskVolume(
                name: name,
                mountPath: url.path,
                totalBytes: UInt64(total),
                availableBytes: available,
                isRemovable: values.volumeIsRemovable ?? false))
        }
        // 根卷排最前，其余按路径排序 —— 顺序稳定，不会每次刷新跳来跳去。
        return volumes.sorted { lhs, rhs in
            if lhs.mountPath == "/" { return true }
            if rhs.mountPath == "/" { return false }
            return lhs.mountPath < rhs.mountPath
        }
    }

    /// 1 / 5 / 15 分钟负载均值。`getloadavg` 返回实际填入的样本数，失败为 -1。
    private static func readLoadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        let filled = getloadavg(&loads, 3)
        guard filled > 0 else { return [] }
        return Array(loads.prefix(Int(filled)))
    }

    /// 开机时长：`kern.boottime` 是开机时刻的 timeval，用当前时间减。
    private static func readUptime() -> Double? {
        var bootTime = timeval()
        var len = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &len, nil, 0) == 0,
              bootTime.tv_sec > 0 else { return nil }
        let elapsed = Date().timeIntervalSince1970 - Double(bootTime.tv_sec)
        return elapsed >= 0 ? elapsed : nil
    }

    /// 所有物理网卡的累计收/发字节数。
    ///
    /// 跳过回环（lo0）与虚拟隧道（utun/gif/stf/bridge）：它们的字节数要么是
    /// 本机自己的流量，要么是物理网卡的同一次拷贝的重复计数，算进「网络速率」
    /// 会让数字虚高。
    private static func readNetworkTotals() -> (down: UInt64, up: UInt64)? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(first) }

        var down: UInt64 = 0
        var up: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let entry = current.pointee
            if let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) {
                let name = String(cString: entry.ifa_name)
                if !name.hasPrefix("lo"), !name.hasPrefix("utun"),
                   !name.hasPrefix("gif"), !name.hasPrefix("stf"),
                   !name.hasPrefix("bridge") {
                    down += UInt64(data.pointee.ifi_ibytes)
                    up += UInt64(data.pointee.ifi_obytes)
                }
            }
            pointer = entry.ifa_next
        }
        return (down, up)
    }
}
