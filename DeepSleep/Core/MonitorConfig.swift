//
//  MonitorConfig.swift
//  Deep Sleep
//
//  监控配置的持久化。
//
//  把 MonitorConfig 改成 Codable 并加 UserDefaults 桥。这是用户上一版
//  报的 bug：「启用监控」勾选切页回来没保留、「保存设置」按钮没用。
//  根因：之前是 @State + 内存里唯一的 struct，没有持久化与回读。
//
//  v1.4.1 起改：用 UserDefaults 的 JSON 形式持久化整个 config，
//  MonitoringView onAppear 时 load，任意字段变化时 save。
//

import Foundation

extension MonitorConfig {
    private static let storageKey = "monitorConfig.v1"

    /// 默认配置的 JSON 形式，用于比较「是否还是默认值」以决定是否落盘。
    /// 避免每次启动都把默认值写一遍 UserDefaults（污染磁盘）。
    private static let defaultJSON: Data? = {
        try? JSONEncoder().encode(MonitorConfig.default)
    }()

    /// 从 UserDefaults 读。读不到或损坏时返回 .default。
    public static func load() -> MonitorConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(MonitorConfig.self, from: data)
        } catch {
            return .default
        }
    }

    /// 写到 UserDefaults。如果就是默认值就不写（避免无谓的磁盘改动）。
    public func saveIfNotDefault() {
        if let defaultData = Self.defaultJSON,
           let mine = try? JSONEncoder().encode(self),
           mine == defaultData {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}