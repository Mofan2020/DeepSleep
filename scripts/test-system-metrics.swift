//
//  test-system-metrics.swift
//  Deep Sleep 回归测试
//
//  验证 Shared/SystemMetrics.swift 的纯换算与格式化：
//   - CPU 百分比换算（ticks 差分，含 idle 参与分母、计数器回绕、核数不匹配）
//   - 内存占比换算（页 → 字节、各项占比、已用口径、零分母）
//   - 字节格式化（十进制 1000 进制）
//   - 时长格式化（天/小时/分/秒）
//   - 历史环形缓冲（满了丢最旧的）
//   - 阈值持久化（与默认值一致 → 删 key）
//
//  运行：
//  swiftc -parse-as-library \
//    Shared/SystemMetrics.swift \
//    scripts/test-system-metrics.swift -o /tmp/t_sysmetrics && /tmp/t_sysmetrics
//

import Foundation

@main
struct SystemMetricsTests {

    static func main() {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ actual: String = "") {
            if condition {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)" + (actual.isEmpty ? "" : " —— 实际: \(actual)"))
                failures += 1
            }
        }

        func checkEqualBytes(_ name: String, _ expected: UInt64, _ actual: UInt64) {
            check(name, expected == actual, "期望 \(expected)，实际 \(actual)")
        }

        func checkEqualString(_ name: String, _ expected: String, _ actual: String) {
            check(name, expected == actual, "期望「\(expected)」，实际「\(actual)」")
        }

        func checkClose(_ name: String, _ expected: Double, _ actual: Double,
                        tolerance: Double = 0.001) {
            let ok = abs(expected - actual) <= tolerance
            check(name, ok, String(format: "期望 %.4f，实际 %.4f", expected, actual))
        }

        // --------------------------------------------------- CPU 百分比换算
        print("== CPU 百分比换算（ticks 差分） ==")

        // 空闲占 80%：两次采样之间总 tick 涨 1000，其中 idle 涨 800 → busy 20%。
        let before = SystemMetrics.CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let after = SystemMetrics.CPUTicks(user: 200, system: 0, idle: 800, nice: 0)
        checkClose("idle 计入分母时 busy 比例正确", 20.0,
                  SystemMetrics.percent(before: before, after: after))

        // 全忙：idle 一个 tick 都没涨 → 100%。
        let busyBefore = SystemMetrics.CPUTicks(user: 0, system: 0, idle: 100, nice: 0)
        let busyAfter = SystemMetrics.CPUTicks(user: 500, system: 300, idle: 100, nice: 0)
        checkClose("完全跑满时是 100%", 100.0,
                  SystemMetrics.percent(before: busyBefore, after: busyAfter))

        // 全闲：idle 涨了 1000，其它没动 → 0%。
        let idleBefore = SystemMetrics.CPUTicks(user: 10, system: 0, idle: 0, nice: 0)
        let idleAfter = SystemMetrics.CPUTicks(user: 10, system: 0, idle: 1_000, nice: 0)
        checkClose("完全空闲时是 0%", 0.0,
                   SystemMetrics.percent(before: idleBefore, after: idleAfter))

        // nice 算进 busy（与本仓整机口径一致）。
        let niceBefore = SystemMetrics.CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let niceAfter = SystemMetrics.CPUTicks(user: 0, system: 0, idle: 0, nice: 400)
        checkClose("nice tick 计入 busy", 100.0,
                   SystemMetrics.percent(before: niceBefore, after: niceAfter))

        // 计数器回绕（内核重置）→ 0，不是垃圾数。
        let resetBefore = SystemMetrics.CPUTicks(user: 5_000, system: 0, idle: 0, nice: 0)
        let resetAfter = SystemMetrics.CPUTicks(user: 10, system: 0, idle: 0, nice: 0)
        checkClose("计数器回绕时返回 0", 0.0,
                   SystemMetrics.percent(before: resetBefore, after: resetAfter))

        // 分母为 0（两次采样完全相同）→ 0。
        checkClose("两次采样无变化时返回 0", 0.0,
                   SystemMetrics.percent(before: before, after: before))

        // 逐核：一核满、一核闲（两次采样各涨 400 tick）。
        let coresBefore = [
            SystemMetrics.CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
            SystemMetrics.CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        ]
        let coresAfter = [
            SystemMetrics.CPUTicks(user: 400, system: 0, idle: 0, nice: 0),
            SystemMetrics.CPUTicks(user: 0, system: 0, idle: 400, nice: 0)
        ]
        let perCore = SystemMetrics.perCorePercentages(before: coresBefore, after: coresAfter)
        check("逐核返回的个数与核数一致", perCore.count == 2, "实际 \(perCore.count)")
        if perCore.count == 2 {
            checkClose("第 0 核满负荷", 100.0, perCore[0])
            checkClose("第 1 核空闲", 0.0, perCore[1])
        }

        // 核数对不上 → 空数组（调用方据此整块隐藏）。
        check("核数不匹配时返回空数组",
              SystemMetrics.perCorePercentages(before: coresBefore, after: [coresAfter[0]]).isEmpty)

        // 整机口径：一核满、一核闲 → 50%。
        checkClose("整机百分比按各核汇总", 50.0,
                   SystemMetrics.overallPercent(before: coresBefore, after: coresAfter))

        // 整机口径是按 tick 加权的，不是逐核百分比的算术平均：
        // 一核只跑 100 tick 且全忙、另一核跑 900 tick 全闲 → 整机 10%。
        let weightedBefore = [
            SystemMetrics.CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
            SystemMetrics.CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        ]
        let weightedAfter = [
            SystemMetrics.CPUTicks(user: 100, system: 0, idle: 0, nice: 0),
            SystemMetrics.CPUTicks(user: 0, system: 0, idle: 900, nice: 0)
        ]
        checkClose("整机百分比按 tick 加权而非简单平均", 10.0,
                   SystemMetrics.overallPercent(before: weightedBefore, after: weightedAfter))

        // 整机：核数不匹配 → 0。
        checkClose("核数不匹配时整机百分比为 0", 0.0,
                   SystemMetrics.overallPercent(before: coresBefore, after: [coresAfter[0]]))

        // --------------------------------------------------- 内存占比换算
        print("\n== 内存占比换算 ==")

        let pages = SystemMetrics.MemoryPages(app: 100, wired: 50, compressed: 25,
                                              cached: 200, free: 625)
        let breakdown = SystemMetrics.memoryBreakdown(
            pages: pages, pageSize: 16_384, totalBytes: 1_000 * 1_000 * 1_000,
            swapUsedBytes: 2_000_000_000, swapTotalBytes: 8_000_000_000)

        checkEqualBytes("应用占用字节数正确", 100 * 16_384, breakdown.appBytes)
        checkEqualBytes("联动字节数正确", 50 * 16_384, breakdown.wiredBytes)
        checkEqualBytes("压缩字节数正确", 25 * 16_384, breakdown.compressedBytes)
        checkEqualBytes("缓存字节数正确", 200 * 16_384, breakdown.cachedBytes)
        checkEqualBytes("空闲字节数正确", 625 * 16_384, breakdown.freeBytes)

        // 已用 = 应用 + 联动 + 压缩（活动监视器口径）。
        checkEqualBytes("已用 = 应用 + 联动 + 压缩",
                        (100 + 50 + 25) * 16_384, breakdown.usedBytes)

        // 页数总计 1000 页 × 16 KB = 16,384,000 字节；物理内存按 1 GB 算，
        // 所以占比按物理内存分母算，而不是按页数总和算。
        checkClose("应用占物理内存比例", 100 * 16_384 / 1_000_000_000 * 100,
                   breakdown.appPercent)
        checkClose("联动占物理内存比例", 50 * 16_384 / 1_000_000_000 * 100,
                   breakdown.wiredPercent)
        checkClose("压缩占物理内存比例", 25 * 16_384 / 1_000_000_000 * 100,
                   breakdown.compressedPercent)
        checkClose("缓存占物理内存比例", 200 * 16_384 / 1_000_000_000 * 100,
                   breakdown.cachedPercent)
        checkClose("空闲占物理内存比例", 625 * 16_384 / 1_000_000_000 * 100,
                   breakdown.freePercent)
        checkClose("已用占物理内存比例",
                   (100 + 50 + 25) * 16_384 / 1_000_000_000 * 100, breakdown.usedPercent)
        checkClose("交换空间占比", 25.0, breakdown.swapPercent)

        // 零分母 → 0，不能是 NaN。
        checkClose("分母为 0 时百分比为 0", 0.0,
                   SystemMetrics.percent(part: 100, of: 0))
        let zeroTotal = SystemMetrics.memoryBreakdown(
            pages: pages, pageSize: 16_384, totalBytes: 0,
            swapUsedBytes: 0, swapTotalBytes: 0)
        checkClose("总内存读不到时占比为 0", 0.0, zeroTotal.usedPercent)

        // 页大小为 0 时按 1 兜底，不能整块变 0 或溢出。
        let zeroPage = SystemMetrics.memoryBreakdown(
            pages: pages, pageSize: 0, totalBytes: 1_000,
            swapUsedBytes: 0, swapTotalBytes: 1_000)
        checkEqualBytes("页大小为 0 时按 1 兜底", 100, zeroPage.appBytes)

        // ------------------------------------------------------- 字节格式化
        print("\n== 字节格式化 ==")

        checkEqualString("0 字节", "0 B", SystemMetrics.formatBytes(0))
        checkEqualString("小于 1 KB 不进位", "999 B", SystemMetrics.formatBytes(999))
        checkEqualString("1024 字节 = 1.0 KB", "1.0 KB", SystemMetrics.formatBytes(1024))
        checkEqualString("1536 字节 = 1.5 KB", "1.5 KB", SystemMetrics.formatBytes(1536))
        checkEqualString("1 MB", "1.0 MB", SystemMetrics.formatBytes(1_000_000))
        checkEqualString("1 GB", "1.0 GB", SystemMetrics.formatBytes(1_000_000_000))
        checkEqualString("1.5 TB", "1.5 TB", SystemMetrics.formatBytes(1_500_000_000_000))
        checkEqualString("十进制而非二进制（900 字节仍是 B）", "900 B",
                         SystemMetrics.formatBytes(900))
        checkEqualString("十进制而非二进制（1 MiB 显示 1.0 MB）", "1.0 MB",
                         SystemMetrics.formatBytes(1_048_576))

        checkEqualString("速率 0", "0 B/s", SystemMetrics.formatRate(0))
        checkEqualString("速率 1.5 MB/s", "1.5 MB/s", SystemMetrics.formatRate(1_500_000))

        // 内存用二进制：8 GiB 要显示成 8.0 GB（macOS「关于本机」的口径），
        // 而不是十进制的 8.6 GB。
        checkEqualString("8 GiB 内存显示 8.0 GB", "8.0 GB",
                         SystemMetrics.formatMemoryBytes(8_589_934_592))
        checkEqualString("512 MiB 内存显示 512.0 MB", "512.0 MB",
                         SystemMetrics.formatMemoryBytes(536_870_912))

        // ------------------------------------------------------- 时长格式化
        print("\n== 时长格式化 ==")

        checkEqualString("0 秒", "0 秒", SystemMetrics.formatDuration(0))
        checkEqualString("45 秒", "45 秒", SystemMetrics.formatDuration(45))
        checkEqualString("90 秒", "1 分 30 秒", SystemMetrics.formatDuration(90))
        checkEqualString("1 小时", "1 小时 0 分", SystemMetrics.formatDuration(3_600))
        checkEqualString("1 天", "1 天 2 小时", SystemMetrics.formatDuration(93_600))
        checkEqualString("负数按 0 处理", "0 秒", SystemMetrics.formatDuration(-5))

        // ------------------------------------------------------- 历史环形缓冲
        print("\n== 历史环形缓冲 ==")

        var history = SystemMetrics.MetricHistory(capacity: 3)
        for i in 0..<5 {
            history.append(SystemMetrics.HistorySample(
                timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                cpuPercent: Double(i), memoryPercent: Double(i), cpuTempCelsius: nil))
        }
        check("缓冲长度不超过容量", history.samples.count == 3, "实际 \(history.samples.count)")
        checkEqualString("丢掉最旧的两个点", "2.0",
                         String(format: "%.1f", history.samples.first?.cpuPercent ?? -1))
        checkEqualString("保留最新的点", "4.0",
                         String(format: "%.1f", history.samples.last?.cpuPercent ?? -1))
        history.removeAll()
        check("清空后为空", history.samples.isEmpty)

        // ------------------------------------------------------- 阈值持久化
        print("\n== 阈值持久化 ==")

        let key = SystemMetrics.MetricThresholds.storageKey
        UserDefaults.standard.removeObject(forKey: key)
        check("键名带 .v1 后缀", key.hasSuffix(".v1"), key)
        check("没有记录时读回默认值",
              SystemMetrics.MetricThresholds.load() == SystemMetrics.MetricThresholds.default)

        var thresholds = SystemMetrics.MetricThresholds.default
        thresholds.diskUsagePercent = 95
        thresholds.coreCPUPercent = 80
        thresholds.saveIfNotDefault()
        check("非默认值会落盘", UserDefaults.standard.data(forKey: key) != nil)

        let loaded = SystemMetrics.MetricThresholds.load()
        checkClose("读回的磁盘阈值一致", 95, loaded.diskUsagePercent)
        checkClose("读回的每核阈值一致", 80, loaded.coreCPUPercent)

        SystemMetrics.MetricThresholds.default.saveIfNotDefault()
        check("写回默认值后 key 被删掉", UserDefaults.standard.data(forKey: key) == nil)

        // --------------------------------------------------------- 汇总
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
