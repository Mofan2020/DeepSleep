//
//  KeepAliveKeychain.swift
//  Deep Sleep
//
//  AI 保活自己的 Keychain 访问层。
//
//  **为什么不复用 LLMGateway 的 KeychainStore**：
//  网关这块功能随时可能被关停或移除，保活不该被它的去留绑架。
//  独立的 service 让两边的凭据彻底分开：网关被移除时，保活已存的
//  API Key 还在，也不会被「清理网关凭据」的动作误删。
//
//  service 名保持固定 —— 改了用户已有的条目全部失效。
//  account 规则：`keepalive.<taskUUID>`（见 KeepAliveStore.keychainAccount）。
//

import Foundation
import Security

/// 保活凭据的 Keychain 错误。
enum KeepAliveKeychainError: LocalizedError {
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

/// 保活的 Keychain 包装。
enum KeepAliveKeychain {

    /// Keychain service。固定字符串，不要改 —— 改了用户已有的 key 全部失效。
    static let service = "com.skyc8266.deepsleep.keepalive"

    /// 写入 / 覆盖一条 key。
    static func save(key: String, account: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeepAliveKeychainError.dataCorrupted(account)
        }
        // 先删旧条目（upsert 语义）。
        try? delete(account: account)

        var query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     account,
            kSecValueData as String:       data,
            // 不设置 kSecAttrSynchronizable → 不同步到 iCloud。
            kSecAttrAccessible as String:  kSecAttrAccessibleAfterFirstUnlock,
        ]
        query = query as CFDictionary as? [String: Any] ?? query

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeepAliveKeychainError.unhandled(status, account)
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
                throw KeepAliveKeychainError.dataCorrupted(account)
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeepAliveKeychainError.unhandled(status, account)
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
            throw KeepAliveKeychainError.unhandled(status, account)
        }
    }
}
