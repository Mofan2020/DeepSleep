//
//  KeepAliveKeychainAccess.swift
//  Deep Sleep
//
//  记录「哪些保活任务的 API Key 需要用户重新授权」。
//
//  为什么需要这个模块：
//
//  钥匙串在应用更新之后会拒绝访问旧条目 —— 钥匙串靠 designated requirement
//  判断「来读的是不是同一个应用」，签名一变就失配，于是弹出「Deep Sleep
//  想要访问钥匙串中的密钥」，要求输入钥匙串密码。
//
//  这里解决的是**弹框的频率**问题，不是弹框本身：
//
//  保活任务是定时触发的。如果每次触发都去读一次钥匙串，用户在授权之后
//  每隔一段时间就要再输一次密码 —— 那比「每次更新输一次」还烦。
//
//  所以：一旦某个 account 确认授权失败，就把它记下来；后续调度直接跳过
//  这个任务，**不再触发钥匙串的授权框**；等用户在界面上重新输入一次
//  API Key（写入成功），标记才解除。
//
//  为什么不 import Security：这个模块只存 account 名字，不碰钥匙串 API。
//  这样它能被普通权限的单测直接覆盖（scripts/test-keepalive-keychain-access.swift），
//  不需要钥匙串、不需要用户授权。
//

import Foundation
import Security

/// 保活凭据的 Keychain 错误。
///
/// **为什么放在这个文件里而不是 `KeepAliveKeychain.swift`**：
/// 回归测试用 `scripts/test-support/KeepAliveTestStubs.swift` 里的内存版
/// 顶替真实的 Keychain（那个桩只顶替了存取，不含错误类型）。
/// 错误类型放在这里，两个测试脚本就都能编译到同一份定义 ——
/// 否则每个用到桩的脚本都得再编一遍真实实现，而桩和真实实现会重名冲突。
enum KeepAliveKeychainError: LocalizedError {
    case unhandled(OSStatus, String)  // (status, account)
    case dataCorrupted(String)
    /// 钥匙串拒绝授权：条目在，但当前应用不被信任。
    ///
    /// 什么时候会走到这里：**应用更新之后**。钥匙串按 designated requirement
    /// 判断「来读的是不是同一个应用」，签名一变就失配，于是弹框要密码。
    /// 用户输完密码，系统会把新签名加进信任列表，之后就能读了。
    ///
    /// 这类错误跟「条目不存在」必须分开：前者用户输一次密码就好了，
    /// 后者说明数据真的丢了。混在一起报「读取失败」，用户不知道该做什么。
    case authorizationDenied(String)
    /// 当前会话不允许弹交互（比如在后台任务里读）。
    case interactionNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case .unhandled(let status, let account):
            let cfMsg = SecCopyErrorMessageString(status, nil)
            let msg = (cfMsg as String?) ?? "OSStatus \(status)"
            return "Keychain 操作失败 [\(account)]：\(msg)"
        case .dataCorrupted(let account):
            return "Keychain 中的 [\(account)] 数据损坏"
        case .authorizationDenied(let account):
            return "钥匙串拒绝了访问 [\(account)]：应用更新后系统认不出这是同一个应用，需要你重新授权一次"
        case .interactionNotAllowed(let account):
            return "钥匙串访问需要用户确认 [\(account)]：当前没有可以弹授权框的界面"
        }
    }

    /// 把 OSStatus 归类。
    ///
    /// 只认这两个具体的码，其余一律按 `unhandled` 原样抛出 ——
    /// 猜错方向比不分类更糟（会把真错误说成授权问题，用户白折腾）。
    static func classify(_ status: OSStatus, account: String) -> KeepAliveKeychainError {
        switch status {
        case errSecAuthFailed:
            return .authorizationDenied(account)
        case errSecInteractionNotAllowed:
            return .interactionNotAllowed(account)
        default:
            return .unhandled(status, account)
        }
    }
}

/// 钥匙串访问状态。线程安全。
final class KeepAliveKeychainAccess: @unchecked Sendable {

    static let shared = KeepAliveKeychainAccess()

    private let lock = NSLock()
    /// 已经确认「钥匙串拒绝访问」的 account 集合。
    private var denied: Set<String> = []

    /// 记下一个授权失败的 account。
    ///
    /// 空字符串不是合法 account（account 规则是 `keepalive.<uuid>`），
    /// 直接忽略 —— 不然一个空 account 会把所有任务都算成需要重新授权。
    func markDenied(_ account: String) {
        guard !account.isEmpty else { return }
        lock.withLock { _ = denied.insert(account) }
    }

    /// 授权恢复（写入成功）后解除标记。
    func clear(_ account: String) {
        lock.withLock { _ = denied.remove(account) }
    }

    /// 这个 account 是否处于「已知授权失败」状态。
    func needsReauthorization(_ account: String) -> Bool {
        guard !account.isEmpty else { return false }
        return lock.withLock { denied.contains(account) }
    }

    /// 读之前先问一句：要不要直接跳过？
    ///
    /// 命中就**不要碰钥匙串** —— 碰了就会弹框。这条是整个模块的核心：
    /// 「不再打扰用户」靠的是不发起请求，不是靠捕获错误。
    func shouldSkipRead(_ account: String) -> Bool {
        needsReauthorization(account)
    }

    /// 当前所有需要重新授权的 account（给界面列提示用）。
    func deniedAccounts() -> [String] {
        lock.withLock { Array(denied).sorted() }
    }

    /// 需要重新授权的 account 数量。
    var deniedCount: Int {
        lock.withLock { denied.count }
    }

    /// 全部清空（用户可能手动在钥匙串访问里重新授权了）。
    func clearAll() {
        lock.withLock { denied.removeAll() }
    }
}
