//
//  GatewayConfigStore.swift
//  Deep Sleep
//
//  网关配置的持久化：UserDefaults 存 JSON。
//
//  做法照抄 `Core/MonitorConfig.swift`：
//  - 一个 key 存整份 config；
//  - 读不到或解码失败时回落到 `.default`；
//  - 就默认值时不写盘（避免每次启动都动一次磁盘）。
//
//  为什么必须存：网关配置（端口 / 鉴权 / 日志）原来只在 `@Published` 内存里，
//  改完重启就丢 —— 用户以为改了就生效，其实每次启动都回到默认值。
//
//  安全约定：`authToken` 会被写进 UserDefaults。这是网关自己的访问令牌，
//  不是厂商 API Key（那些在 Keychain 里）。如果把监听地址改成 0.0.0.0，
//  这个 token 就是唯一的防线，所以它不应该复用厂商 key 的存储位置。
//

import Foundation

extension GatewayConfig {

    /// UserDefaults key。带 `.v1` 后缀是为了以后改结构时可以并存两版。
    static let storageKey = "gateway.config.v1"

    /// 默认配置的 JSON 形式，用于判断「是否还是默认值」。
    ///
    /// **必须用 `.sortedKeys`**：JSONEncoder 对 struct 的键序不固定 ——
    /// 同一个值多次编码能产出好几种字节（实测 12 字段的 struct 连续 50 次
    /// 出现 8 种，其中一种占约 80%）。不固定键序的话，
    /// 「和默认值一样吗」这个判断会随机地给出错误答案，
    /// 于是默认值也会被写进 UserDefaults。
    private static let defaultJSON: Data? = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(GatewayConfig.default)
    }()

    /// 从 UserDefaults 读。读不到或损坏时返回 `.default`。
    static func load() -> GatewayConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(GatewayConfig.self, from: data)
        } catch {
            return .default
        }
    }

    /// 写到 UserDefaults。如果就是默认值就不写（避免无谓的磁盘改动）。
    func saveIfNotDefault() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let mine = try? encoder.encode(self) else { return }
        if let defaultData = Self.defaultJSON, mine == defaultData {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
            return
        }
        UserDefaults.standard.set(mine, forKey: Self.storageKey)
    }
}
