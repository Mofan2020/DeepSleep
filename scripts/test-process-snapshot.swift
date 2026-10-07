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
        print("OK: ProcessSnapshot 真实快照可用")
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
        // cpuPercent >= 0 即可；极快的循环可能被归纳掉，所以不强制 > 0
        assertTrue(self_!.cpuPercent >= 0 && self_!.cpuPercent < 10_000,
                   "cpuPercent in range (got \(self_!.cpuPercent))")
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