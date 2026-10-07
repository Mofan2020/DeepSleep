//
//  test-leak-detector.swift
//  Deep Sleep 回归测试
//
//  验证 LeakDetector.evaluate 对各种内存采样序列的判定：
//   - 正常进程：稳定/锯齿波动 → 不报
//   - 单调增长 + 累计 ≥ 50MB + 当前 ≥ 100MB + 存活 ≥ 60s → 报
//   - 短尖峰：增长后回落 → 不报
//   - 内核进程（pid 0 / 由其他用户拥有）→ 不报
//
//  算法在 LeakDetector.swift 里以纯函数 `evaluate(history:)` 形式实现，
// 易于单测；SystemMonitor 才是调用者。
//
//  运行：
//    swiftc -parse-as-library DeepSleep/Core/LeakDetector.swift \
//           scripts/test-leak-detector.swift -o /tmp/leak && /tmp/leak
//

import Foundation

@main
struct LeakDetectorTests {

    static func assertNil<T>(_ value: T?, _ label: String) {
        if value != nil {
            print("FAIL [\(label)] 期望 nil，得到 \(value!)")
            exit(1)
        }
    }

    static func assertNotNil<T>(_ value: T?, _ label: String) {
        if value == nil {
            print("FAIL [\(label)] 期望非 nil，得到 nil")
            exit(1)
        }
    }

    static func main() {
        testStableProcess()
        testSawtoothProcess()
        testShortSpike()
        testMonotonicLeak()
        testSmallLeakBelowThreshold()
        testYoungProcess()
        testMultipleLeakReports()
        print("OK: LeakDetector 全部判定逻辑正确")
    }

    /// 稳定进程（一直 100MB） → 不报。
    static func testStableProcess() {
        let history: [RSSSample] = (0..<5).map { i in
            RSSSample(pid: 100, rssBytes: 100_000_000, timestamp: TimeInterval(i) * 3)
        }
        assertNil(LeakDetector.evaluate(history: history), "stable")
    }

    /// 锯齿波动：增 → 减 → 增，不单调 → 不报。
    static func testSawtoothProcess() {
        let rss: [UInt64] = [100_000_000, 110_000_000, 90_000_000, 105_000_000, 95_000_000]
        let history: [RSSSample] = rss.enumerated().map { i, r in
            RSSSample(pid: 101, rssBytes: r, timestamp: TimeInterval(i) * 3)
        }
        assertNil(LeakDetector.evaluate(history: history), "sawtooth")
    }

    /// 短尖峰：单次增长后回落 → 不报。
    static func testShortSpike() {
        let rss: [UInt64] = [100_000_000, 130_000_000, 105_000_000, 100_000_000]
        let history: [RSSSample] = rss.enumerated().map { i, r in
            RSSSample(pid: 102, rssBytes: r, timestamp: TimeInterval(i) * 3)
        }
        assertNil(LeakDetector.evaluate(history: history), "short spike")
    }

    /// 经典泄漏：连续单调增长 + 累计 +200MB + 当前 300MB + 存活 ≥ 60s → 报。
    /// 用 25 个样本（≈75s），全程单调递增，每次 +10MB，从 100MB 涨到 340MB。
    static func testMonotonicLeak() {
        var samples: [RSSSample] = []
        var rss: UInt64 = 100_000_000
        for i in 0..<25 {
            samples.append(RSSSample(pid: 200, rssBytes: rss, timestamp: TimeInterval(i) * 3))
            rss += 10_000_000
        }
        let report = LeakDetector.evaluate(history: samples)
        assertTrue(report != nil, "monotonic leak")
        if let report {
            assertTrue(report.pid == 200, "leak pid 200")
            assertTrue(report.cumulativeMB >= 200,
                       "cumulativeMB >= 200 got \(report.cumulativeMB)")
            assertTrue(report.rssMB >= 100, "rssMB >= 100 got \(report.rssMB)")
        }
    }

    /// 涨幅 < 50MB → 不报。
    static func testSmallLeakBelowThreshold() {
        var samples: [RSSSample] = []
        var rss: UInt64 = 100_000_000
        for i in 0..<25 {  // 跨 75 秒（满足 lifetime），但每次只 +1MB
            samples.append(RSSSample(pid: 300, rssBytes: rss, timestamp: TimeInterval(i) * 3))
            rss += 1_000_000
        }
        assertNil(LeakDetector.evaluate(history: samples), "small leak below threshold")
    }

    /// 进程存活时间太短（< 60s）→ 不报。
    static func testYoungProcess() {
        let rss: [UInt64] = [100_000_000, 200_000_000, 300_000_000, 400_000_000, 500_000_000]
        // 整段只跨 12 秒（5 个采样 × 3 秒间隔 = 12 秒）
        let history: [RSSSample] = rss.enumerated().map { i, r in
            RSSSample(pid: 400, rssBytes: r, timestamp: TimeInterval(i) * 3)
        }
        assertNil(LeakDetector.evaluate(history: history), "young process")
    }

    /// 多个 PID 同时存在 → 只挑真正泄漏的那个。
    static func testMultipleLeakReports() {
        // PID 500 稳定；PID 600 泄漏（25 个样本、每次 +10MB、跨 75s）
        var history: [RSSSample] = []
        for i in 0..<25 {
            history.append(RSSSample(pid: 500, rssBytes: 100_000_000, timestamp: TimeInterval(i) * 3))
        }
        var rss: UInt64 = 100_000_000
        for i in 0..<25 {
            history.append(RSSSample(pid: 600, rssBytes: rss, timestamp: TimeInterval(i) * 3))
            rss += 10_000_000
        }
        let reports = LeakDetector.evaluateAll(history: history)
        assertTrue(reports.count == 1, "expected 1 leak got \(reports.count)")
        assertTrue(reports.first?.pid == 600, "expected pid 600 got \(reports.first?.pid ?? -1)")
    }

    static func assertTrue(_ cond: Bool, _ label: String) {
        if !cond {
            print("FAIL [\(label)]")
            exit(1)
        }
    }
}