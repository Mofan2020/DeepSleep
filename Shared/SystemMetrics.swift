//
//  SystemMetrics.swift
//  Deep Sleep
//
//  系统监控面板的「纯逻辑层」：采样值换算、格式化、阈值持久化。
//
//  **只 import Foundation** —— 这个文件同时编进主 App 与特权助手，
//  任何 Darwin / AppKit / SwiftUI 依赖都会把助手 target 拖下水。
//
//  采集动作（host_statistics64 / host_processor_info / getifaddrs …）
//  全在 DeepSleep/Core/SystemMonitor.swift 里；这里只做换算与格式化，
//  好让 scripts/test-system-metrics.swift 能脱离 App 单独跑。
//
//  口径说明（与 DeepSleep/Core/SystemMonitor.swift 里的采集器保持一致）：
//   - CPU%：busy = 总 tick - idle tick；100% = 该核一直满负荷。
//     nice tick 算进 busy —— 与本仓 CPUAccounting.swift 的整机口径一致。
//   - 字节：十进制 1000 进制（KB/MB/GB），与 macOS「关于本机 / 活动监视器」
//     显示的数字一致；用户拿系统设置里的容量对比时不会觉得口径不对。
//

import Foundation

public enum SystemMetrics {

    // MARK: - CPU

    /// 单个 CPU 核的一组 tick 计数（来自 PROCESSOR_CPU_LOAD_INFO）。
    public struct CPUTicks: Equatable, Sendable {
        public let user: UInt64
        public let system: UInt64
        public let idle: UInt64
        public let nice: UInt64

        public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
            self.user = user
            self.system = system
            self.idle = idle
            self.nice = nice
        }

        /// 四个计数之和。做差分时分母用它。
        public var total: UInt64 { user + system + idle + nice }
        /// 忙碌时间 = 总时间 - 空闲时间。
        public var busy: UInt64 { total >= idle ? total - idle : 0 }
    }

    // MARK: - CPU 换算

    /// 相邻两次采样之间的单核占用百分比（0–100）。
    ///
    /// 计数器回绕（内核重置计数）或分母为 0 时返回 0 —— 「算不出来」和
    /// 「真的是 0%」在 UI 上必须能区分，所以这里给 0 而不是猜一个数。
    public static func percent(before: CPUTicks, after: CPUTicks) -> Double {
        let totalDelta = after.total >= before.total ? after.total - before.total : 0
        guard totalDelta > 0 else { return 0 }
        let busyDelta = after.busy >= before.busy ? after.busy - before.busy : 0
        return clampedPercent(Double(busyDelta) / Double(totalDelta) * 100)
    }

    /// 逐核占用百分比（0–100），顺序与采样顺序一致。
    ///
    /// 两次采样的核数对不上（热插拔 / 内核重置）时返回空数组 ——
    /// 调用方据此把整块 UI 藏起来，而不是显示一半核的数据。
    public static func perCorePercentages(before: [CPUTicks], after: [CPUTicks]) -> [Double] {
        guard !before.isEmpty, before.count == after.count else { return [] }
        return zip(before, after).map { percent(before: $0, after: $1) }
    }

    /// 整机占用百分比（0–100，全机所有核都跑满 = 100）。
    ///
    /// 由各核 tick 汇总得出：所有核的 busy 增量之和 / 所有核的总增量之和。
    public static func overallPercent(before: [CPUTicks], after: [CPUTicks]) -> Double {
        guard !before.isEmpty, before.count == after.count else { return 0 }
        var totalDelta: UInt64 = 0
        var busyDelta: UInt64 = 0
        for (old, new) in zip(before, after) {
            totalDelta += new.total >= old.total ? new.total - old.total : 0
            busyDelta += new.busy >= old.busy ? new.busy - old.busy : 0
        }
        guard totalDelta > 0 else { return 0 }
        return clampedPercent(Double(busyDelta) / Double(totalDelta) * 100)
    }

    private static func clampedPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }

    // MARK: - 内存

    /// 内存页计数（单位：页）。由采集器从 vm_statistics64 读出来填。
    public struct MemoryPages: Equatable, Sendable {
        /// 应用占用：active + inactive + speculative（进程真正占着的页）。
        public let app: UInt64
        /// 联动内存。
        public let wired: UInt64
        /// 压缩器占用的物理页。
        public let compressed: UInt64
        /// 文件缓存（可回收）。
        public let cached: UInt64
        /// 空闲页。
        public let free: UInt64

        public init(app: UInt64, wired: UInt64, compressed: UInt64,
                    cached: UInt64, free: UInt64) {
            self.app = app
            self.wired = wired
            self.compressed = compressed
            self.cached = cached
            self.free = free
        }
    }

    /// 内存明细（字节）。
    public struct MemoryBreakdown: Equatable, Sendable {
        public let totalBytes: UInt64
        public let appBytes: UInt64
        public let wiredBytes: UInt64
        public let compressedBytes: UInt64
        public let cachedBytes: UInt64
        public let freeBytes: UInt64
        public let swapUsedBytes: UInt64
        public let swapTotalBytes: UInt64

        public init(totalBytes: UInt64, appBytes: UInt64, wiredBytes: UInt64,
                    compressedBytes: UInt64, cachedBytes: UInt64, freeBytes: UInt64,
                    swapUsedBytes: UInt64, swapTotalBytes: UInt64) {
            self.totalBytes = totalBytes
            self.appBytes = appBytes
            self.wiredBytes = wiredBytes
            self.compressedBytes = compressedBytes
            self.cachedBytes = cachedBytes
            self.freeBytes = freeBytes
            self.swapUsedBytes = swapUsedBytes
            self.swapTotalBytes = swapTotalBytes
        }

        /// 已用 = 应用 + 联动 + 压缩（与活动监视器「已用内存」同口径）。
        public var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }

        /// 已用占物理内存的百分比。
        public var usedPercent: Double {
            SystemMetrics.percent(part: usedBytes, of: totalBytes)
        }

        /// 各项占物理内存的百分比。
        public func percent(part: UInt64, of total: UInt64) -> Double {
            SystemMetrics.percent(part: part, of: total)
        }

        public var appPercent: Double { SystemMetrics.percent(part: appBytes, of: totalBytes) }
        public var wiredPercent: Double { SystemMetrics.percent(part: wiredBytes, of: totalBytes) }
        public var compressedPercent: Double { SystemMetrics.percent(part: compressedBytes, of: totalBytes) }
        public var cachedPercent: Double { SystemMetrics.percent(part: cachedBytes, of: totalBytes) }
        public var freePercent: Double { SystemMetrics.percent(part: freeBytes, of: totalBytes) }

        /// 交换空间占用百分比（0 表示读不到交换空间信息）。
        public var swapPercent: Double {
            SystemMetrics.percent(part: swapUsedBytes, of: swapTotalBytes)
        }
    }

    /// 百分比换算。分母为 0 时返回 0（不是 NaN，也不是无穷）。
    public static func percent(part: UInt64, of total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        let value = Double(part) / Double(total) * 100
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }

    /// 页计数 → 字节明细。
    public static func memoryBreakdown(pages: MemoryPages,
                                       pageSize: UInt64,
                                       totalBytes: UInt64,
                                       swapUsedBytes: UInt64,
                                       swapTotalBytes: UInt64) -> MemoryBreakdown {
        let size = max(pageSize, 1)
        return MemoryBreakdown(
            totalBytes: totalBytes,
            appBytes: pages.app * size,
            wiredBytes: pages.wired * size,
            compressedBytes: pages.compressed * size,
            cachedBytes: pages.cached * size,
            freeBytes: pages.free * size,
            swapUsedBytes: swapUsedBytes,
            swapTotalBytes: swapTotalBytes
        )
    }

    /// 内核页计数 → 各部分页数。
    ///
    /// 口径（与 `vm_stat` 对齐，已在本机核对）：
    ///   - `internal`（匿名页）→ 应用占用
    ///   - `external`（文件页） → 缓存
    ///   - `wire`              → 联动
    ///   - `compressor`         → 压缩
    ///   - `free`              → 空闲
    ///
    /// `internal + external` 恰好等于 `active + inactive + speculative`，
    /// 所以不把 speculative 单独算进应用占用 —— 否则会重复计数。
    /// （函数参数不能叫 `internal`，那是关键字，所以叫 `anonymous`。）
    public static func memoryPages(anonymous: UInt64,
                                   external: UInt64,
                                   wire: UInt64,
                                   compressor: UInt64,
                                   free: UInt64) -> MemoryPages {
        MemoryPages(app: anonymous,
                    wired: wire,
                    compressed: compressor,
                    cached: external,
                    free: free)
    }

    // MARK: - 格式化

    /// 字节数 → 人类可读。十进制 1000 进制，与 macOS 显示一致。
    public static func formatBytes(_ bytes: UInt64) -> String {
        format(bytes) { $0 / 1000 }
    }

    /// 字节数 → 人类可读，二进制 1024 进制。
    ///
    /// 内存总量用这个：macOS「关于本机」里的「内存 8 GB」是 8 GiB，
    /// 拿十进制显示成 8.6 GB 会让人以为读错了机器。
    /// 磁盘容量反过来用十进制（Finder / 关于本机里的磁盘就是 494.38 GB），
    /// 两套口径各按各自系统界面的习惯来。
    public static func formatMemoryBytes(_ bytes: UInt64) -> String {
        format(bytes) { $0 / 1024 }
    }

    private static func format(_ bytes: UInt64, _ divide: (Double) -> Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1000, unitIndex < units.count - 1 {
            value = divide(value)
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    /// 速率（字节/秒）→ 人类可读。
    public static func formatRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 B/s" }
        return formatBytes(UInt64(min(bytesPerSecond.rounded(), Double(UInt64.max)))) + "/s"
    }

    /// 时长（秒）→ 人类可读。用于开机时长。
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 秒" }
        let total = Int(seconds.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if days > 0 {
            return "\(days) 天 \(hours) 小时"
        }
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        }
        if minutes > 0 {
            return "\(minutes) 分 \(secs) 秒"
        }
        return "\(secs) 秒"
    }

    // MARK: - 磁盘卷

    /// 一个已挂载卷的容量信息。
    public struct DiskVolume: Sendable, Equatable {
        public let name: String
        public let mountPath: String
        public let totalBytes: UInt64
        /// 可用空间。读不到时为 nil —— 显示「不可用」，不显示 0。
        public let availableBytes: UInt64?
        public let isRemovable: Bool

        public init(name: String, mountPath: String, totalBytes: UInt64,
                    availableBytes: UInt64?, isRemovable: Bool) {
            self.name = name
            self.mountPath = mountPath
            self.totalBytes = totalBytes
            self.availableBytes = availableBytes
            self.isRemovable = isRemovable
        }

        /// 已用空间。总量或可用量读不到时为 nil。
        public var usedBytes: UInt64? {
            guard let available = availableBytes else { return nil }
            return totalBytes >= available ? totalBytes - available : 0
        }

        /// 已用占比（0–1）。读不到时为 nil。
        public var usedFraction: Double? {
            guard let used = usedBytes, totalBytes > 0 else { return nil }
            return Double(used) / Double(totalBytes)
        }
    }

    // MARK: - 网络速率

    /// 网络速率（字节/秒）。
    public struct NetworkRate: Sendable, Equatable {
        public let downloadBytesPerSecond: Double
        public let uploadBytesPerSecond: Double

        public init(downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) {
            self.downloadBytesPerSecond = downloadBytesPerSecond
            self.uploadBytesPerSecond = uploadBytesPerSecond
        }

        public static let zero = NetworkRate(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
    }

    // MARK: - 热压力

    /// 热压力等级。对应 `ProcessInfo.ThermalState`。
    public enum ThermalState: String, Sendable, CaseIterable {
        case nominal
        case fair
        case serious
        case critical

        public var displayName: String {
            switch self {
            case .nominal:  return "正常"
            case .fair:     return "偏高"
            case .serious:  return "严重"
            case .critical: return "危急"
            }
        }
    }

    // MARK: - 历史环形缓冲

    /// 历史曲线的一个采样点。
    public struct HistorySample: Equatable, Sendable {
        public let timestamp: Date
        public let cpuPercent: Double
        public let memoryPercent: Double
        public let cpuTempCelsius: Double?

        public init(timestamp: Date, cpuPercent: Double, memoryPercent: Double,
                    cpuTempCelsius: Double?) {
            self.timestamp = timestamp
            self.cpuPercent = cpuPercent
            self.memoryPercent = memoryPercent
            self.cpuTempCelsius = cpuTempCelsius
        }
    }

    /// 定长环形缓冲。超过容量就丢最旧的。
    public struct MetricHistory: Sendable {
        public let capacity: Int
        private var storage: [HistorySample] = []

        public init(capacity: Int) {
            self.capacity = max(1, capacity)
            storage.reserveCapacity(self.capacity)
        }

        public var samples: [HistorySample] { storage }

        public mutating func append(_ sample: HistorySample) {
            storage.append(sample)
            if storage.count > capacity {
                storage.removeFirst(storage.count - capacity)
            }
        }

        public mutating func removeAll() {
            storage.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - 面板阈值（独立于 MonitorConfig）

    /// 面板自己的显示阈值。
    ///
    /// **不进 MonitorConfig** —— 那是告警链路（会发通知 / 邮件）的配置，
    /// 归监控协调器管。这里这三项只决定面板上什么颜色算「高」，
    /// 改动立刻落盘，键名带 `.v1` 后缀。
    public struct MetricThresholds: Codable, Sendable, Equatable {
        /// 卷用量高亮线（%）。
        public var diskUsagePercent: Double
        /// 单核 CPU 高亮线（%）。
        public var coreCPUPercent: Double
        /// 网络速率高亮线（字节/秒）。
        public var networkBytesPerSecond: Double

        public init(diskUsagePercent: Double = 90,
                    coreCPUPercent: Double = 90,
                    networkBytesPerSecond: Double = 10 * 1024 * 1024) {
            self.diskUsagePercent = diskUsagePercent
            self.coreCPUPercent = coreCPUPercent
            self.networkBytesPerSecond = networkBytesPerSecond
        }

        public static let `default` = MetricThresholds()

        // MARK: - 持久化

        /// 存档键。带 `.v1` 后缀，将来加字段时另起版本号，老存档照常读。
        public static let storageKey = "systemMetricsThresholds.v1"

        /// 从 UserDefaults 读。读不到或损坏时返回默认值。
        public static func load() -> MetricThresholds {
            guard let data = UserDefaults.standard.data(forKey: storageKey) else {
                return .default
            }
            guard let decoded = try? JSONDecoder().decode(MetricThresholds.self, from: data) else {
                return .default
            }
            return decoded
        }

        /// 写回 UserDefaults。和默认值一样时删掉 key —— 不留默认值副本。
        public func saveIfNotDefault() {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let mine = try? encoder.encode(self) else { return }
            guard let defaults = try? encoder.encode(MetricThresholds.default) else { return }
            if mine == defaults {
                UserDefaults.standard.removeObject(forKey: MetricThresholds.storageKey)
                return
            }
            UserDefaults.standard.set(mine, forKey: MetricThresholds.storageKey)
        }
    }
}
