//
//  test-process-stats.swift
//  Deep Sleep 回归测试
//
//  验证 ProcessStats 编解码 round-trip 与特殊字符名处理。
//
//  这一层错了的后果是「监控触发时传给助手的 pid 与名字对不上」 ——
//  监控会拿不到真实进程，UI 会显示假名。属于「无声错误」。
//
//  运行：
//    swiftc Shared/ProcessStats.swift scripts/test-process-stats.swift \
//           -o /tmp/pstats && /tmp/pstats
//

import Foundation

@main
struct ProcessStatsTests {

    // MARK: - 断言帮手

    static func assertEqual<T: Equatable>(_ a: T, _ b: T, _ label: String,
                                          file: String = #file, line: Int = #line) {
        if a != b {
            print("FAIL [\(label)]: \(a) != \(b)  (\(file):\(line))")
            exit(1)
        }
    }

    static func assertTrue(_ cond: Bool, _ label: String,
                          file: String = #file, line: Int = #line) {
        if !cond {
            print("FAIL [\(label)]  (\(file):\(line))")
            exit(1)
        }
    }

    // MARK: - 用例

    static func main() {
        testRoundTripBasic()
        testEmptyRoundTrip()
        testSpecialCharacterNames()
        testManyRecords()
        print("OK: ProcessStats round-trip + 特殊字符全部通过")
    }

    /// 普通样本 round-trip。
    static func testRoundTripBasic() {
        let records: [ProcessStats.Record] = [
            .init(pid: 1, name: "launchd", rssBytes: 12345, cpuPercent: 0.5, startTime: 0),
            .init(pid: 42, name: "Finder", rssBytes: 98_765_432, cpuPercent: 12.34, startTime: 1_700_000_000),
            .init(pid: 9999, name: "test", rssBytes: 0, cpuPercent: 0, startTime: -1)
        ]
        let stats = ProcessStats(records: records)
        let payload = stats.encode()
        let restored = ProcessStats.decode(payload)

        assertEqual(restored.records.count, records.count, "count")
        for (a, b) in zip(restored.records, records) {
            assertEqual(a.pid, b.pid, "pid")
            assertEqual(a.name, b.name, "name")
            assertEqual(a.rssBytes, b.rssBytes, "rss")
            assertEqual(a.cpuPercent, b.cpuPercent, "cpu")
            assertEqual(a.startTime, b.startTime, "startTime")
        }
    }

    /// 空列表 round-trip。
    static func testEmptyRoundTrip() {
        let stats = ProcessStats(records: [])
        let payload = stats.encode()
        let restored = ProcessStats.decode(payload)
        assertEqual(restored.records.count, 0, "empty count")
    }

    /// 进程名里可能出现中文、空格、百分号、竖线、逗号 —— 不能让它们在
    /// 编解码中被分隔符吞掉，也不能在 payload 中出现未编码控制字符。
    static func testSpecialCharacterNames() {
        let names = [
            "中文进程",
            "name with space",
            "100% CPU",
            "name|with|pipes",
            "name,comma,name",
            "name:with:colons",
            "name\nwith\nnewline",
            "name\"with\"quotes"
        ]
        let records = names.enumerated().map { idx, name in
            ProcessStats.Record(pid: pid_t(idx + 100), name: name,
                                rssBytes: UInt64(idx) * 1000, cpuPercent: Double(idx),
                                startTime: Int64(idx))
        }
        let stats = ProcessStats(records: records)
        let payload = stats.encode()
        let restored = ProcessStats.decode(payload)
        assertEqual(restored.records.count, records.count, "special count")
        for (i, expected) in names.enumerated() {
            assertEqual(restored.records[i].name, expected,
                        "special name #\(i) got=\(restored.records[i].name)")
        }
    }

    /// 多记录确保逗号分隔不把名字里的逗号当成记录分隔符。
    static func testManyRecords() {
        var records: [ProcessStats.Record] = []
        for i in 0..<100 {
            let name = (i % 2 == 0) ? "name,with,comma,\(i)" : "plain-\(i)"
            records.append(.init(pid: pid_t(i + 1000), name: name,
                                 rssBytes: UInt64(i) * 1000,
                                 cpuPercent: Double(i) * 0.1,
                                 startTime: Int64(i)))
        }
        let stats = ProcessStats(records: records)
        let payload = stats.encode()
        let restored = ProcessStats.decode(payload)
        assertEqual(restored.records.count, 100, "many count")
        for (a, b) in zip(restored.records, records) {
            assertEqual(a.name, b.name, "many name pid=\(b.pid)")
            assertEqual(a.pid, b.pid, "many pid")
            assertEqual(a.rssBytes, b.rssBytes, "many rss")
        }
    }
}