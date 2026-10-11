//
//  KeychainStore.swift
//  Deep Sleep
//
//  LLM Gateway 的 API Key 存储：macOS Keychain (kSecClassGenericPassword)。
//
//  隔离策略：
//  - service 固定为 com.skyc8266.deepsleep.llmgateway；不和 DeepSleep 主 Keychain 混。
//  - 每个 key 用「account」标识：用户起的 alias（displayName）。
//  - 同一 alias 可覆盖写入（upsert 语义）。
//
//  安全考虑：
//  - 不强制 iCloud 同步；用 kSecAttrSynchronizable 不设置（默认就是 false）。
//  - 不要求用户生物识别——本地用户从 Keychain 读取本身受 macOS 控制。
//  - 不写日志：API Key 一旦打印到日志就是漏。
//

import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case unhandled(OSStatus, String)  // (status, account)
    case dataCorrupted(String)
    var errorDescription: String? {
        switch self {
        case .unhandled(let status, let account):
            let cfMsg = SecCopyErrorMessageString(status, nil)
            let msg = (cfMsg as String?) ?? "OSStatus \(status)"
            return "Keychain 操作失败 [\(account)]：\(msg)"
        case .dataCorrupted(let account):
            return "Keychain 中的 [\(account)] 数据损坏"
        }
    }
}

/// LLM Gateway 的 Keychain 包装。
struct KeychainStore {

    /// Keychain service。固定字符串，不要随便改——改了用户全部 alias 都会失效。
    static let service = "com.skyc8266.deepsleep.llmgateway"

    /// 写入 / 覆盖一条 key。
    static func save(key: String, account: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainStoreError.dataCorrupted(account)
        }
        // 先尝试删旧条目（upsert 语义）。
        try? delete(account: account)

        var query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     account,
            kSecValueData as String:       data,
            // kSecAttrSynchronizable 缺省 → 不同步到 iCloud。
            kSecAttrAccessible as String:  kSecAttrAccessibleAfterFirstUnlock,
        ]
        // 在 Swift 5 上隐式桥接要求类型为 CFDictionary。
        query = query as CFDictionary as? [String: Any] ?? query

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unhandled(status, account)
        }
    }

    /// 读一条 key；不存在返回 nil。
    static func load(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     account,
            kSecReturnData as String:      true,
            kSecMatchLimit as String:      kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                throw KeychainStoreError.dataCorrupted(account)
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.unhandled(status, account)
        }
    }

    /// 删一条 key；不存在不报错。
    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandled(status, account)
        }
    }

    /// 列出所有 account 名（按 service 过滤）。
    static func listAccounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String:               kSecClassGenericPassword,
            kSecAttrService as String:         service,
            kSecReturnAttributes as String:    true,
            kSecMatchLimit as String:          kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            guard let arr = items as? [[String: Any]] else { return [] }
            return arr.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw KeychainStoreError.unhandled(status, "<list>")
        }
    }
}