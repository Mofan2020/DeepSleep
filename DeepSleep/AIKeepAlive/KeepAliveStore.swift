//
//  KeepAliveStore.swift
//  Deep Sleep
//
//  AI 保活任务的持久化：UserDefaults 里存 JSON。
//
//  做法照抄 ScheduledCommand（`scheduledCommands.v1`）：
//  - 一个 key 存整份数组，改动就整体重写；
//  - 存的是 `apiKeyRef`（Keychain account 名），不是 API Key 本身。
//
//  为什么用 UserDefaults 而不是 SQLite：任务数量是几十条量级，字段固定，
//  没有查询需求；LLMGateway 那边的 SQLite 是为了网关请求流水账，场景不同。
//
//  Keychain 的 account 名规则：`keepalive.<taskUUID>`。
//  复用 LLMGateway 的 KeychainStore（同一个 service `com.skyc8266.deepsleep.llmgateway`），
//  靠 account 前缀隔离 —— 改 service 会让用户已有的条目全部失效，不能动。
//

import Foundation

/// 保活任务的存储。
struct KeepAliveStore {

    /// UserDefaults key。带 `.v1` 后缀是为了以后改结构时可以并存两版。
    static let storageKey = "keepAliveTasks.v1"

    /// Keychain account 的前缀。
    static let keychainPrefix = "keepalive."

    /// 某个任务对应的 Keychain account 名。
    static func keychainAccount(for id: UUID) -> String {
        keychainPrefix + id.uuidString
    }

    /// 读出全部任务。数据损坏时返回空数组而不是崩掉。
    static func load() -> [KeepAliveTask] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([KeepAliveTask].self, from: data) else {
            return []
        }
        // 存盘时可能被手改过，读取时统一钳制间隔。
        return decoded.map { $0.clamped }
    }

    /// 覆盖写入全部任务。
    static func save(_ tasks: [KeepAliveTask]) {
        guard let data = encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// 编码器。**必须用 `.sortedKeys`**。
    ///
    /// `JSONEncoder` 对 struct 的键序不固定 —— 同一个值多次编码能产出
    /// 好几种字节（实测 12 字段的 struct 连续 50 次出现 8 种，其中一种
    /// 占约 80%）。键序不定的话，存盘内容每次都不一样，
    /// 「这次改动了什么」没法靠 diff 看出来，UserDefaults 里也会积攒
    /// 内容相同但字节不同的重复写入。
    private static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    /// 插入或更新一条。返回落盘后的任务列表。
    @discardableResult
    static func upsert(_ task: KeepAliveTask) -> [KeepAliveTask] {
        var tasks = load()
        let clamped = task.clamped
        if let idx = tasks.firstIndex(where: { $0.id == clamped.id }) {
            tasks[idx] = clamped
        } else {
            tasks.append(clamped)
        }
        save(tasks)
        return tasks
    }

    /// 删除一条。
    @discardableResult
    static func remove(id: UUID) -> [KeepAliveTask] {
        var tasks = load()
        tasks.removeAll { $0.id == id }
        save(tasks)
        return tasks
    }
}

// MARK: - Keychain 访问

extension KeepAliveStore {

    /// 异步读 Keychain。
    ///
    /// `KeychainStore.load` 是同步调用，在主线程上会卡一下 ——
    /// 钥匙串操作要走一次 IPC，几十到几百毫秒都可能。扔到后台队列。
    static func readAPIKey(account: String) async throws -> String? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let value = try KeychainStore.load(account: account)
                    cont.resume(returning: value)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// 异步写 Keychain。
    static func writeAPIKey(_ key: String, account: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try KeychainStore.save(key: key, account: account)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
