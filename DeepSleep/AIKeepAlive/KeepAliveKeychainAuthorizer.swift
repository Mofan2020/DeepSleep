//
//  KeepAliveKeychainAuthorizer.swift
//  Deep Sleep
//
//  「一键授权」：把当前这个应用重新写进每条 API Key 条目的钥匙串 ACL。
//
//  ## 解决的是什么问题
//
//  Deep Sleep 用 ad-hoc 签名（没有 Developer ID 证书），签名身份就是可执行
//  文件的 cdhash，**每次重新构建都会变**。钥匙串的条目 ACL 里记的正是
//  `cdhash:xxxx`（实测，见 ACL 里那条 Partitions 描述），所以每次更新之后，
//  新版本读旧条目都会被当成陌生应用，弹框要密码。
//
//  用户手工的解法是「点编辑、把 API Key 重新填一次」—— 要填 N 次。
//  这个模块的解法是：一次点按，把 N 条全部触发一遍授权，用户在每个框上
//  点「始终允许」，之后这个版本的定时任务就再也不会弹框。
//
//  ## 为什么不能靠「再读一遍成功」判断
//
//  用户点「仅此一次」之后，**同一个进程在本轮生命周期内**再读同一条不会再
//  弹框 —— 系统记住了这次会话的授权。所以「第二次读取也成功了」不能证明
//  用户点的是「始终允许」，两个选项都会让第二次成功。
//
//  唯一可靠的判据是 **ACL 里受信任应用的数量**：
//  「始终允许」会把当前 cdhash 追加进 ACL，「仅此一次」不碰 ACL。
//  授权前记一次、授权后再记一次，**变多了才是真的始终授权**。
//
//  ## 这套 API 是 deprecated 的
//
//  `SecKeychainItemCopyAccess` / `SecAccessCopyACLList` / `SecACLCopyContents`
//  在 macOS 10.10 就标了 deprecated（`SecKeychain` 整体被 `SecItem` 取代），
//  但实测在 macOS 26 上仍然可用且能读到真实数据（见
//  `scripts/test-keychain-authorizer.swift` 的自检）。
//  这里用它是因为**没有替代品**：新的 `SecItem` API 完全不暴露 ACL。
//  所以把用到的三处集中在这个文件里，将来若真的失效，只需要改这一处。
//

import Foundation
import Security

/// 一条任务的授权结果。
enum KeepAliveAuthorizationOutcome: Equatable, Sendable {
    /// 本来就能读，不需要授权。通常是同一个版本内第二次点。
    case alreadyTrusted
    /// 用户点了「始终允许」，ACL 已更新 —— 这个版本后续不会再弹。
    case alwaysAllowed
    /// 用户点了「仅此一次」，或直接关掉了授权框。下次还会弹。
    case onlyOnce
    /// 用户点了「不允许」。
    case denied
    /// 钥匙串里没有这条条目（数据丢了，需要重填）。
    case missing
    /// 其它失败，附带原因。
    case failed(String)

    /// 这条结果算不算「以后不会再弹框」。
    var isSettled: Bool {
        switch self {
        case .alreadyTrusted, .alwaysAllowed: return true
        case .onlyOnce, .denied, .missing, .failed: return false
        }
    }

    /// 给界面看的文案。
    ///
    /// 只讲用户要做什么、做成了没有，不讲 ACL 与 cdhash 这些内部机制。
    var title: String {
        switch self {
        case .alreadyTrusted: return "已授权"
        case .alwaysAllowed:  return "已设为始终允许"
        case .onlyOnce:       return "只授权了一次"
        case .denied:         return "已拒绝"
        case .missing:        return "钥匙串里没有这条"
        case .failed(let reason): return "授权失败：\(reason)"
        }
    }

    /// 需要用户继续处理时的提示。已解决的状态没有提示。
    var hint: String? {
        switch self {
        case .alreadyTrusted, .alwaysAllowed:
            return nil
        case .onlyOnce:
            return "下次任务运行时会再问一次。请重新点一次，并在弹出框里选「始终允许」。"
        case .denied:
            return "这次拒绝了访问，任务读不到 Key。请重新点一次并选「始终允许」。"
        case .missing:
            return "这条任务的 Key 已经不在钥匙串里了，请在「编辑」里重新填一次。"
        case .failed:
            return "系统没能完成授权，稍后重试一次。"
        }
    }
}

/// 单条任务的处理结果。
struct KeepAliveAuthorizationItem: Identifiable, Sendable {
    let id = UUID()
    /// 任务名（给用户看）。
    let taskName: String
    /// 钥匙串 account（`keepalive.<uuid>`）。
    let account: String
    let outcome: KeepAliveAuthorizationOutcome
}

/// 一批的结果。
struct KeepAliveAuthorizationReport: Sendable {
    let items: [KeepAliveAuthorizationItem]

    var settledCount: Int { items.filter { $0.outcome.isSettled }.count }

    /// 全部解决了吗。空批次也算「没东西要处理」。
    var allSettled: Bool { items.allSatisfy { $0.outcome.isSettled } }

    /// 汇总成一句给界面用的话。
    var summary: String {
        if items.isEmpty { return "没有需要授权的任务。" }
        if allSettled {
            return "\(items.count) 条任务的授权都已就绪，后续定时运行不会再弹框。"
        }
        let pending = items.count - settledCount
        return "\(settledCount) 条已就绪，还有 \(pending) 条需要再点一次。"
    }
}

/// 一键授权。
///
/// 全部同步执行 —— 调用方必须**不要在主线程**上跑：
/// 每一条都可能弹出系统授权框并等用户操作，主线程会被卡住。
enum KeepAliveKeychainAuthorizer {

    /// 给一批任务做授权。
    ///
    /// - Parameter tasks: 要处理的 (任务名, account) 列表。
    /// - Returns: 逐条结果。
    static func authorizeAll(_ tasks: [(name: String, account: String)]) -> KeepAliveAuthorizationReport {
        var items: [KeepAliveAuthorizationItem] = []
        for task in tasks {
            let outcome = authorize(account: task.account)
            items.append(KeepAliveAuthorizationItem(
                taskName: task.name,
                account: task.account,
                outcome: outcome))
        }
        return KeepAliveAuthorizationReport(items: items)
    }

    /// 授权一条。
    static func authorize(account: String) -> KeepAliveAuthorizationOutcome {
        // 1. 授权前先记下 ACL 里受信任应用的数量。
        //
        //    这一步可能本身就要授权（实测 `kSecReturnRef` 不读密文，
        //    多数情况下不弹；但取不到时下面按「拿不到 before」处理）。
        let before = trustedApplicationCount(account: account)

        // 2. 读一次 —— 这是唯一会弹授权框的地方，跟真实任务读 Key 走同一条路径。
        let startedAt = Date()
        do {
            guard try KeepAliveKeychain.load(account: account) != nil else {
                return .missing
            }
        } catch let error as KeepAliveKeychainError {
            switch error {
            case .authorizationDenied:
                return .denied
            case .interactionNotAllowed:
                return .failed("当前没有可以弹授权框的界面")
            case .unhandled(let status, _):
                // errSecUserCanceled：用户关掉了授权框，效果同「只授权一次」。
                if status == errSecUserCanceled { return .onlyOnce }
                return .failed(SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")
            case .dataCorrupted:
                return .failed("钥匙串里的数据损坏")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
        let elapsed = Date().timeIntervalSince(startedAt)

        // 3. 授权后再记一次 ACL。
        let after = trustedApplicationCount(account: account)

        // 4. 判定交给纯函数 —— 它可以被回归测试完整覆盖，不需要弹框。
        return Self.decide(before: before, after: after, elapsed: elapsed)
    }

    /// 判定用户点了什么。
    ///
    /// 抽成纯函数是为了可测：真实路径要弹系统授权框，没法自动化；
    /// 而这里的判断规则才是最容易写错的地方（阈值、nil 分支）。
    ///
    /// - Parameters:
    ///   - before: 授权前 ACL 里受信任应用的数量；读不到为 nil。
    ///   - after: 授权后同样的数字；读不到为 nil。
    ///   - elapsed: 中间那次读取花了多久。用户点一下框至少要一秒。
    static func decide(before: Int?, after: Int?, elapsed: TimeInterval) -> KeepAliveAuthorizationOutcome {
        // 硬判据：受信任应用变多了 ⇒ 用户点了「始终允许」。
        // 「仅此一次」不会修改 ACL —— 这是两种选择唯一的可观测差别。
        if let before, let after {
            if after > before { return .alwaysAllowed }
            // 数量没变，但这次读取快得不像弹过框 —— 本来就能读，不需要授权。
            if before > 0 && elapsed < instantThreshold { return .alreadyTrusted }
            // 数量没变且等待过 ⇒ 用户点了「仅此一次」。
            return .onlyOnce
        }

        // ACL 读不到时的退路：`before` 为 nil 说明取 ACL 那一步失败（可能它自己
        // 触发了授权），这时只剩 `after` 可用。只要条目确实带了受信任应用、
        // 且这次读取没等过，就说明授权已经落在 ACL 上。
        // 这个判断不如上面硬，所以只在拿不到 before 时才用。
        if let after {
            if after > 0 && elapsed < instantThreshold { return .alreadyTrusted }
            return .onlyOnce
        }
        // 连条目引用都拿不到，无法确认 —— 不冒充成功。
        return .failed("读不到钥匙串条目的访问控制信息，无法确认是否已设为始终允许")
    }

    /// 低于这个耗时，认为没有弹过框（用户点一下至少要一秒）。
    private static let instantThreshold: TimeInterval = 0.5

    // MARK: - ACL 读取

    /// 条目 ACL 里「受信任应用」的总数。读不到返回 nil。
    ///
    /// 用 `kSecReturnRef` 只要引用、不要密文，所以正常情况下不会触发
    /// 数据访问授权。
    static func trustedApplicationCount(account: String) -> Int? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: KeepAliveKeychain.service,
            kSecAttrAccount as String: account,
            kSecReturnRef as String:   true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let item else {
            return nil
        }

        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item as! SecKeychainItem, &access) == errSecSuccess,
              let access else {
            return nil
        }

        var aclList: CFArray?
        guard SecAccessCopyACLList(access, &aclList) == errSecSuccess,
              let acls = aclList as? [SecACL] else {
            return nil
        }

        var total = 0
        for acl in acls {
            var apps: CFArray?
            var description: CFString?
            var promptSelector = SecKeychainPromptSelector()
            if SecACLCopyContents(acl, &apps, &description, &promptSelector) == errSecSuccess {
                total += (apps as? [SecTrustedApplication])?.count ?? 0
            }
        }
        return total
    }
}
