//
//  test-hosts-allowed-editors.swift
//  回归测试：HostsAllowedEditors 的解析、空白名单语义。
//
//  跑：swiftc Shared/HelperProtocol.swift Shared/HostsAllowedEditors.swift scripts/test-hosts-allowed-editors.swift -o /tmp/t6 && /tmp/t6
//

import Foundation

private var failures = 0

private func expectTrue(_ label: String, _ actual: Bool) {
    if actual {
        print("[通过] \(label)")
    } else {
        print("[失败] \(label)")
        failures += 1
    }
}

private func expectEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    if actual == expected {
        print("[通过] \(label): \(actual)")
    } else {
        print("[失败] \(label): 期望 \(expected)，实得 \(actual)")
        failures += 1
    }
}

func runAllTests() {
    // 1. parseUids：合法 / 空 / 非数字 / 越界
    expectEqual("parseUids '501,502,503'",
                HostsAllowedEditors.parseUids("501,502,503"),
                [501, 502, 503])
    expectEqual("parseUids 空字符串 → 空数组",
                HostsAllowedEditors.parseUids(""),
                [])
    expectEqual("parseUids 混杂字母 → 跳过",
                HostsAllowedEditors.parseUids("501,abc,502"),
                [501, 502])
    expectEqual("parseUids 含空白 → 正常",
                HostsAllowedEditors.parseUids("501, 502"),
                [501, 502])
    expectEqual("parseUids 负数 → 跳过",
                HostsAllowedEditors.parseUids("-1,501"),
                [501])

    // 2. parseUsernames
    expectEqual("parseUsernames 'alice,bob'",
                HostsAllowedEditors.parseUsernames("alice,bob"),
                ["alice", "bob"])
    expectEqual("parseUsernames 含空白 → trim",
                HostsAllowedEditors.parseUsernames(" alice , bob "),
                ["alice", "bob"])
    expectEqual("parseUsernames 全空白 → 空",
                HostsAllowedEditors.parseUsernames("  ,  "),
                [])

    // 3. Snapshot.init 去重 + 排序
    let snap = HostsAllowedEditors.Snapshot(uids: [3, 1, 2, 1], usernames: ["b", "a", "a"])
    expectEqual("Snapshot uids 去重+排序", snap.uids, [1, 2, 3])
    expectEqual("Snapshot usernames 去重+排序", snap.usernames, ["a", "b"])
    expectTrue("Snapshot 非空时 isEmpty=false", !snap.isEmpty)

    // 4. isAllowed 语义：空白名单放行；非空时校验
    let empty = HostsAllowedEditors.Snapshot(uids: [], usernames: [])
    expectTrue("空白名单放行 uid=0", HostsAllowedEditors.isAllowed(uid: 0, snapshot: empty))
    expectTrue("空白名单放行 uid=501", HostsAllowedEditors.isAllowed(uid: 501, snapshot: empty))
    expectTrue("空白名单放行 uid=999", HostsAllowedEditors.isAllowed(uid: 999, snapshot: empty))

    let one = HostsAllowedEditors.Snapshot(uids: [501], usernames: ["alice"])
    expectTrue("白名单内 501 通过", HostsAllowedEditors.isAllowed(uid: 501, snapshot: one))
    expectTrue("白名单外 502 拒绝", !HostsAllowedEditors.isAllowed(uid: 502, snapshot: one))
    expectTrue("白名单内 uid 0 拒绝", !HostsAllowedEditors.isAllowed(uid: 0, snapshot: one))

    // 5. hostsEditorsPath 是绝对路径
    let path = HelperConstants.hostsEditorsPath
    expectTrue("hostsEditorsPath 以 / 开头", path.hasPrefix("/"))
    expectTrue("hostsEditorsPath 含 com.skyc8266.deepsleep",
               path.contains("com.skyc8266.deepsleep"))
    expectTrue("hostsEditorsPath 在 /Library/Application Support 下",
               path.hasPrefix("/Library/Application Support"))

    print()
    if failures == 0 {
        print("测试结论: 全部通过")
    } else {
        print("测试结论: \(failures) 项失败")
        exit(1)
    }
}

@main
struct TestEntry {
    static func main() {
        runAllTests()
    }
}