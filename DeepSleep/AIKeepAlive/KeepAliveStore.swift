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
// 用保活自己的 Keychain 层（`KeepAliveKeychain.swift`），service 独立于网关 ——
// 网关随时可能被移除，保活的凭据不该跟着一起失效。
//
//  版本迁移：v1.8.1 及以前的任务用「间隔分钟数」表达节奏（`intervalMinutes`）。
// v1.8.2 改成「每天固定时刻 + 每周选几天」，字段从 `intervalMinutes` 变成
// `schedule`。老数据必须迁移 —— 不迁移的话解码直接失败，用户的任务会全部消失。
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
              let decoded = try? JSONDecoder().decode([LegacyAwareTask].self, from: data) else {
            return []
        }
        // 存盘时可能被手改过，读取时统一归一化。
        return decoded.map { $0.migrated.clamped }
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

// MARK: - 旧格式迁移

/// 能同时读懂新旧两种格式的任务。
///
/// 新格式有 `schedule`，旧格式有 `intervalMinutes`。用 `decodeIfPresent`
/// 分别取，缺哪个都当成「没配」：
///  - 新格式 → `schedule` 有值，`intervalMinutes` 为 nil，直接用 schedule；
///  - 旧格式 → `schedule` 为 nil，拿 `intervalMinutes` 推算一个每日计划。
private struct LegacyAwareTask: Decodable {

    /// CodingKeys 要显式写 —— 一旦提供了自定义的 `init(from:)`，
    /// 编译器就不再合成 CodingKeys 了。
    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, format, model, apiKeyRef
        case intervalMinutes, schedule, requestTemplate
        case isEnabled, lastRunAt, lastResult, createdAt
    }

    var id: UUID
    var name: String
    var baseURL: String
    var format: KeepAliveFormat
    var model: String
    var apiKeyRef: String
    var intervalMinutes: Int?
    var schedule: KeepAliveSchedule?
    var requestTemplate: String?
    var isEnabled: Bool?
    var lastRunAt: Date?
    var lastResult: String?
    var createdAt: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        format = try container.decode(KeepAliveFormat.self, forKey: .format)
        model = try container.decode(String.self, forKey: .model)
        apiKeyRef = try container.decode(String.self, forKey: .apiKeyRef)
        intervalMinutes = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes)
        schedule = try container.decodeIfPresent(KeepAliveSchedule.self, forKey: .schedule)
        requestTemplate = try container.decodeIfPresent(String.self, forKey: .requestTemplate)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled)
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastResult = try container.decodeIfPresent(String.self, forKey: .lastResult)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    /// 转成当前格式的任务。
    var migrated: KeepAliveTask {
        let resolvedSchedule: KeepAliveSchedule
        if let schedule {
            resolvedSchedule = schedule
        } else if let intervalMinutes {
            resolvedSchedule = KeepAliveSchedule.migratedFromLegacyInterval(intervalMinutes)
        } else {
            resolvedSchedule = .default
        }

        return KeepAliveTask(
            id: id,
            name: name,
            baseURL: baseURL,
            format: format,
            model: model,
            apiKeyRef: apiKeyRef,
            schedule: resolvedSchedule,
            requestTemplate: requestTemplate ?? KeepAliveDefaults.defaultRequestTemplate,
            isEnabled: isEnabled ?? true,
            lastRunAt: lastRunAt,
            lastResult: lastResult,
            createdAt: createdAt
        )
    }
}

// MARK: - Keychain 访问

extension KeepAliveStore {

    /// 异步读 Keychain。
    ///
    /// `KeepAliveKeychain.load` 是同步调用，在主线程上会卡一下 ——
    /// 钥匙串操作要走一次 IPC，几十到几百毫秒都可能。扔到后台队列。
    static func readAPIKey(account: String) async throws -> String? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let value = try KeepAliveKeychain.load(account: account)
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
                    try KeepAliveKeychain.save(key: key, account: account)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
