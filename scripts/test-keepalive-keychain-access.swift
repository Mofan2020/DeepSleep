//
//  test-keepalive-keychain-access.swift
//  Deep Sleep 回归测试
//
//  验证「钥匙串授权失败后不再反复弹框」这套机制：
//  - 标记 / 清除 / 查询
//  - 空 account 被忽略（不然一个空串会把所有任务都算成需要重新授权）
//  - 已被标记的 account 读之前就被短路，不会再去碰钥匙串
//
//  运行：
//  swiftc DeepSleep/AIKeepAlive/KeepAliveKeychainAccess.swift \
//         scripts/test-keepalive-keychain-access.swift \
//         -o /tmp/ka-kc-test && /tmp/ka-kc-test
//

import Foundation

@main
struct KeepAliveKeychainAccessTests {

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

        func checkEqual<T: Equatable>(_ name: String, _ expected: T, _ actual: T) {
            if expected == actual {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name) —— 期望 \(expected)，实际 \(actual)")
                failures += 1
            }
        }

        let access = KeepAliveKeychainAccess.shared
        access.clearAll()

        // ---------------------------------------------------- 基本标记
        check("初始状态没有需要重新授权的 account",
              access.deniedCount == 0,
              "count=\(access.deniedCount)")

        let accountA = "keepalive.11111111-1111-1111-1111-111111111111"
        let accountB = "keepalive.22222222-2222-2222-2222-222222222222"

        checkEqual("未标记的 account 不需要重新授权",
                   false, access.needsReauthorization(accountA))

        access.markDenied(accountA)
        check("标记后该 account 需要重新授权",
              access.needsReauthorization(accountA))
        checkEqual("标记计数正确", 1, access.deniedCount)

        // ---------------------------------------------------- 空 account
        access.markDenied("")
        checkEqual("空 account 不计入标记数", 1, access.deniedCount)
        checkEqual("空 account 不算需要重新授权",
                   false, access.needsReauthorization(""))

        // ---------------------------------------------------- 清除
        access.clear(accountA)
        check("清除后不再需要重新授权",
              !access.needsReauthorization(accountA))
        checkEqual("清除后计数归零", 0, access.deniedCount)

        // ---------------------------------------------------- 短路语义
        //
        // 这是整个模块的核心：命中标记的 account **读之前**就该被拦下来。
        // 如果等到读失败才处理，定时任务每一轮都会去问一次钥匙串，
        // 用户就得每隔一阵子输一次密码 —— 那比「更新后输一次」还糟。
        access.markDenied(accountB)
        check("已标记的 account 读之前就被短路",
              access.shouldSkipRead(accountB))
        check("未标记的 account 不短路",
              !access.shouldSkipRead(accountA))
        check("空 account 不短路",
              !access.shouldSkipRead(""))

        // ---------------------------------------------------- 列表
        let listed = access.deniedAccounts()
        checkEqual("列表包含被标记的 account", [accountB], listed)
        check("列表按字典序排列（同样的集合每次顺序一致）",
              listed == access.deniedAccounts().sorted())

        access.clearAll()
        checkEqual("clearAll 清空全部", 0, access.deniedCount)
        checkEqual("clearAll 后列表为空", [] as [String], access.deniedAccounts())

        // ---------------------------------------------------- 重复标记
        access.markDenied(accountA)
        access.markDenied(accountA)
        checkEqual("重复标记不会重复计数", 1, access.deniedCount)

        // ---------------------------------------------------- 线程安全
        //
        // 标记可能发生在后台线程（读钥匙串在后台队列），
        // 查询发生在主线程（界面刷新）。并发读写不能崩、不能丢。
        access.clearAll()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "kc-access-test", attributes: .concurrent)
        for i in 0..<200 {
            queue.async(group: group) {
                let acc = "keepalive.concurrent-\(i % 20)"
                access.markDenied(acc)
                _ = access.needsReauthorization(acc)
                _ = access.deniedCount
            }
        }
        group.wait()
        checkEqual("并发标记后计数正确（20 个不同 account）", 20, access.deniedCount)
        check("并发写入后查询仍然正确",
              access.needsReauthorization("keepalive.concurrent-7"))

        access.clearAll()

        // -------------------------------------------------------- 汇总
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
