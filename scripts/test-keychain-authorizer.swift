//
//  test-keychain-authorizer.swift
//  Deep Sleep 回归测试
//
//  覆盖「一键授权」的判定逻辑与 ACL 读取。
//
//  ## 为什么不测完整的 authorize()
//
//  完整路径会弹出系统授权框并等用户点选，没法自动化。所以把最可错的部分
//  ——「根据授权前后 ACL 应用数的变化判断用户点了什么」—— 抽成纯函数
//  `KeepAliveKeychainAuthorizer.decide(before:after:elapsed:)`，在这里穷举。
//
//  真实钥匙串那一段（建条目 → 读 ACL → 删条目）标了环境变量开关：
//  它要碰真钥匙串，默认不跑，免得在常规回归里留下垃圾条目。
//
//  运行：
//  swiftc -O scripts/test-keychain-authorizer.swift \
//         DeepSleep/AIKeepAlive/KeepAliveKeychainAuthorizer.swift \
//         DeepSleep/AIKeepAlive/KeepAliveKeychain.swift \
//         DeepSleep/AIKeepAlive/KeepAliveKeychainAccess.swift \
//         -o /tmp/t && /tmp/t
//
//  要连真实钥匙串一起测：
//  DS_KEYCHAIN_AUTHORIZER_TEST=1 /tmp/t
//

import Foundation
import Security

@main
struct KeychainAuthorizerTests {

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

        func name(_ outcome: KeepAliveAuthorizationOutcome) -> String {
            switch outcome {
            case .alreadyTrusted: return "alreadyTrusted"
            case .alwaysAllowed:  return "alwaysAllowed"
            case .onlyOnce:       return "onlyOnce"
            case .denied:         return "denied"
            case .missing:        return "missing"
            case .failed:         return "failed"
            }
        }

        // ============================================ 判定：ACL 数量增加
        //
        // 这是整个功能的核心判据。用户点「始终允许」会把当前 cdhash 追加进
        // 条目 ACL，「仅此一次」不动 ACL。所以「变多了」= 始终允许。

        print("--- 判定：始终允许（ACL 变多）---")
        var r = KeepAliveKeychainAuthorizer.decide(before: 1, after: 2, elapsed: 3.0)
        check("1 → 2 判为 alwaysAllowed", r == .alwaysAllowed, name(r))

        r = KeepAliveKeychainAuthorizer.decide(before: 0, after: 1, elapsed: 5.0)
        check("0 → 1 判为 alwaysAllowed", r == .alwaysAllowed, name(r))

        // 关键反例：即使等了很久，只要 ACL 变多就是始终允许。
        // 这条防的是「用耗时当主判据」的错误实现 —— 用户犹豫十秒才点，
        // 仍然是始终允许。
        r = KeepAliveKeychainAuthorizer.decide(before: 2, after: 3, elapsed: 30.0)
        check("ACL 变多时，耗时长也判为 alwaysAllowed", r == .alwaysAllowed, name(r))

        // ============================================ 判定：仅此一次

        print("--- 判定：仅此一次（ACL 没变）---")
        r = KeepAliveKeychainAuthorizer.decide(before: 1, after: 1, elapsed: 3.0)
        check("1 → 1 且等待过，判为 onlyOnce", r == .onlyOnce, name(r))

        r = KeepAliveKeychainAuthorizer.decide(before: 2, after: 2, elapsed: 10.0)
        check("2 → 2 且等待过，判为 onlyOnce", r == .onlyOnce, name(r))

        // ============================================ 判定：本来就已授权

        print("--- 判定：已授权（数量没变且没等待）---")
        r = KeepAliveKeychainAuthorizer.decide(before: 2, after: 2, elapsed: 0.01)
        check("2 → 2 且没等待，判为 alreadyTrusted", r == .alreadyTrusted, name(r))

        // ACL 里没有受信任应用时（before == 0），即使没等待也不能算已授权 ——
        // 那种条目要么是「所有人可读」，要么状态不明，不该报「已就绪」。
        r = KeepAliveKeychainAuthorizer.decide(before: 0, after: 0, elapsed: 0.01)
        check("0 → 0 即使没等待也不判 alreadyTrusted", r == .onlyOnce, name(r))

        // ============================================ 判定：ACL 读不到

        print("--- 判定：ACL 读不到时的退路 ---")
        r = KeepAliveKeychainAuthorizer.decide(before: nil, after: 3, elapsed: 0.01)
        check("before 为 nil、after > 0 且没等待，判为 alreadyTrusted",
              r == .alreadyTrusted, name(r))

        r = KeepAliveKeychainAuthorizer.decide(before: nil, after: 3, elapsed: 4.0)
        check("before 为 nil、after > 0 但等待过，判为 onlyOnce",
              r == .onlyOnce, name(r))

        r = KeepAliveKeychainAuthorizer.decide(before: nil, after: nil, elapsed: 0.01)
        if case .failed = r {
            check("before/after 都为 nil 时判为 failed（不冒充成功）", true)
        } else {
            check("before/after 都为 nil 时判为 failed（不冒充成功）", false, name(r))
        }

        // ============================================ 结果类型的语义

        print("--- 结果语义 ---")
        check("alwaysAllowed 算已就绪", KeepAliveAuthorizationOutcome.alwaysAllowed.isSettled)
        check("alreadyTrusted 算已就绪", KeepAliveAuthorizationOutcome.alreadyTrusted.isSettled)
        check("onlyOnce 不算已就绪", !KeepAliveAuthorizationOutcome.onlyOnce.isSettled)
        check("denied 不算已就绪", !KeepAliveAuthorizationOutcome.denied.isSettled)
        check("missing 不算已就绪", !KeepAliveAuthorizationOutcome.missing.isSettled)
        check("failed 不算已就绪", !KeepAliveAuthorizationOutcome.failed("x").isSettled)

        // 汇总口径：只要有一条没就绪，整批就不能说「都好了」。
        let mixed = KeepAliveAuthorizationReport(items: [
            KeepAliveAuthorizationItem(taskName: "A", account: "a", outcome: .alwaysAllowed),
            KeepAliveAuthorizationItem(taskName: "B", account: "b", outcome: .onlyOnce),
        ])
        check("混合结果不算 allSettled", !mixed.allSettled)
        check("混合结果 settledCount 为 1", mixed.settledCount == 1, "\(mixed.settledCount)")

        let allGood = KeepAliveAuthorizationReport(items: [
            KeepAliveAuthorizationItem(taskName: "A", account: "a", outcome: .alwaysAllowed),
            KeepAliveAuthorizationItem(taskName: "B", account: "b", outcome: .alreadyTrusted),
        ])
        check("全部到位时 allSettled 为真", allGood.allSettled)

        let empty = KeepAliveAuthorizationReport(items: [])
        check("空批次算 allSettled（没有东西要处理）", empty.allSettled)

        // ============================================ ACL 读取：不存在的条目

        print("--- ACL 读取 ---")
        let ghost = "keepalive.TEST-DOES-NOT-EXIST-\(UUID().uuidString)"
        let ghostCount = KeepAliveKeychainAuthorizer.trustedApplicationCount(account: ghost)
        check("不存在的 account 返回 nil", ghostCount == nil,
              ghostCount.map(String.init) ?? "nil")

        // ============================================ 真实钥匙串（可选）
        //
        // 这一段会往真实钥匙串写条目。虽然写自己建的条目不弹框，
        // 但万一留下垃圾会污染用户数据，所以默认跳过。

        if ProcessInfo.processInfo.environment["DS_KEYCHAIN_AUTHORIZER_TEST"] == "1" {
            print("--- 真实钥匙串（自建条目）---")
            let account = "keepalive.TEST-\(UUID().uuidString)"
            do {
                try KeepAliveKeychain.save(key: "test-key-value", account: account)
                check("能写入测试条目", true)

                let count = KeepAliveKeychainAuthorizer.trustedApplicationCount(account: account)
                check("新写入的条目 ACL 里有受信任应用", (count ?? 0) > 0,
                      count.map(String.init) ?? "nil")

                // 自己写的条目自己读：不应该弹框，所以应当判已授权。
                let outcome = KeepAliveKeychainAuthorizer.authorize(account: account)
                check("读自己写的条目判为 alreadyTrusted", outcome == .alreadyTrusted,
                      name(outcome))

                try KeepAliveKeychain.delete(account: account)
                let afterDelete = KeepAliveKeychainAuthorizer.trustedApplicationCount(account: account)
                check("删除后 ACL 读不到", afterDelete == nil,
                      afterDelete.map(String.init) ?? "nil")
            } catch {
                check("真实钥匙串那一段跑完没抛错", false, "\(error)")
                // 尽量收尾，别留垃圾
                try? KeepAliveKeychain.delete(account: account)
            }
        } else {
            print("--- 真实钥匙串 ---")
            print("  [跳过] 需要写真实钥匙串，默认不跑。")
            print("         要跑的话：DS_KEYCHAIN_AUTHORIZER_TEST=1 <本程序>")
        }

        // ============================================ 汇总
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
