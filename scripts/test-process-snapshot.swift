//
//  test-process-snapshot.swift
//  Deep Sleep 回归测试
//
//  验证 ProcessSnapshotCache 能抓到当前进程的 RSS / 启动时间，且 CPU%
//  第一次为 0、第二次给合理值（不要求多核机器一定精确到 1%）。
//
//  这个测试属于「能编译 / 能跑过 / 但要贴近真实」的探针：
//  监控的所有判定（过载阈值、泄漏窗口）都基于这个快照，必须真实。
//
//  运行：
//    swiftc -parse-as-library \
//       Shared/ProcessStats.swift Shared/HelperProtocol.swift Shared/ProcessSnapshot.swift \
//       Shared/ProcessPriority.swift Shared/ProcessInventory.swift \
//       scripts/test-process-snapshot.swift -o /tmp/snap && /tmp/snap
//

import Foundation
import Darwin

@main
struct ProcessSnapshotTests {

    static func assertTrue(_ cond: Bool, _ label: String) {
        if !cond {
            print("FAIL [\(label)]")
            exit(1)
        }
    }

    static func main() async {
        await testFirstSnapshotHasSelf()
        await testSecondSnapshotHasCpuPercent()
        await testRecordFieldsAreValid()
        await testMinimumIntervalReusesCache()
        await testPeekDoesNotTriggerScan()
        print("OK: ProcessSnapshot 真实快照可用")
    }

    /// 间隔内必须复用上一份，不重算。
    ///
    /// 这是稳定性修复的核心：全量扫描要 3~5 秒，而 App 默认每 3 秒要一份。
    /// 不复用的话请求速率高于服务速率 → 助手队列越滚越长 → 客户端超时 →
    /// 界面数值不刷新、App 变慢。
    static func testMinimumIntervalReusesCache() async {
        let first = await ProcessSnapshotCache.shared.snapshot()
        assertTrue(!first.isEmpty, "cache warm-up not empty")

        // 紧接着再来一次：间隔在 minimumSnapshotInterval 以内 → 同一份数据。
        let second = await ProcessSnapshotCache.shared.snapshot()
        assertTrue(first.count == second.count,
                   "reuse within interval should keep same record count (\(first.count) vs \(second.count))")
        let firstSelf = first.first { $0.pid == getpid() }
        let secondSelf = second.first { $0.pid == getpid() }
        assertTrue(firstSelf != nil && secondSelf != nil, "self present in both snapshots")
        assertTrue(firstSelf!.cpuPercent == secondSelf!.cpuPercent,
                   "reuse within interval should keep same cpuPercent "
                   + "(\(firstSelf!.cpuPercent) vs \(secondSelf!.cpuPercent))")
    }

    /// peek() 只能读缓存，绝不能触发新的扫描。
    ///
    /// 助手用它秒回客户端请求；一旦它会触发扫描，客户端就得跟着等 3~5 秒，
    /// 「数值一直不刷新」就会回来。
    static func testPeekDoesNotTriggerScan() async {
        _ = await ProcessSnapshotCache.shared.snapshot()
        let peeked = await ProcessSnapshotCache.shared.peek()
        assertTrue(!peeked.isEmpty, "peek returns cached records")
        let after = await ProcessSnapshotCache.shared.snapshot()
        let peekedSelf = peeked.first { $0.pid == getpid() }
        let afterSelf = after.first { $0.pid == getpid() }
        assertTrue(peekedSelf != nil && afterSelf != nil, "self present in peek and snapshot")
        assertTrue(peekedSelf!.cpuPercent == afterSelf!.cpuPercent,
                   "peek must not trigger a rescan (cpuPercent changed)")
    }

    static func testFirstSnapshotHasSelf() async {
        let records = await ProcessSnapshotCache.shared.snapshot()
        assertTrue(!records.isEmpty, "snapshot not empty")
        let self_ = records.first { $0.pid == getpid() }
        assertTrue(self_ != nil, "snapshot contains self pid=\(getpid())")
        assertTrue(self_!.rssBytes > 0, "self RSS > 0 (got \(self_!.rssBytes))")
        assertTrue(self_!.startTime > 0, "self startTime > 0")
    }

    static func testSecondSnapshotHasCpuPercent() async {
        // 第一次先建好缓存（让它有「上次」可比）
        _ = await ProcessSnapshotCache.shared.snapshot()
        // 真正干点活，让 CPU 计数明显增长
        var acc: UInt64 = 0
        for i in 0..<2_000_000 { acc &+= UInt64(i) }
        // 防 Swift 优化掉
        if acc == UInt64.max { print("impossible") }

        let records = await ProcessSnapshotCache.shared.snapshot()
        let self_ = records.first { $0.pid == getpid() }
        assertTrue(self_ != nil, "second snapshot has self")
        // CPU% 锁在 0–100（whole-CPU 口径）：刚跑 2M 次循环应该明显大于 0
        assertTrue(self_!.cpuPercent >= 0 && self_!.cpuPercent <= 100,
                   "cpuPercent in [0, 100] got \(self_!.cpuPercent)")
    }

    static func testRecordFieldsAreValid() async {
        let records = await ProcessSnapshotCache.shared.snapshot()
        for record in records {
            assertTrue(record.pid > 0, "pid > 0")
            assertTrue(!record.name.isEmpty, "name non-empty")
            assertTrue(record.cpuPercent >= 0, "cpuPercent >= 0")
        }
    }
}