//
//  EmailThrottleStore.swift
//  Deep Sleep
//
//  邮件告警节流：每个 key 记住「上次成功发信时间」。
//
//  故意做成 UserDefaults（不是 Keychain / 文件）：
//   - 数据无敏感信息；
//   - 进程崩溃后还能读到 —— 不会因为重启把 cooldown 抹零导致一重启就被邮件轰炸。
//
//  key 命名约定（与 MonitoringCoordinator.sendEmailIfEnabled 保持一致）：
//   - overload         —— 系统过载
//   - singleRAM-<pid>  —— 单进程 RAM 超阈（每个 pid 单独窗口）
//   - cpuTemp-<int阈值> —— CPU 温度（不同阈值可各自独立计时）
//

import Foundation

@MainActor
final class EmailThrottleStore {

    static let shared = EmailThrottleStore()

    private init() {}

    private let key = "emailThrottle.v1"

    private var cache: [String: Date] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let map = try? JSONDecoder().decode([String: Date].self, from: data) else {
                return [:]
            }
            return map
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func lastSent(forKey key: String) -> Date? {
        cache[key]
    }

    func record(key: String, at date: Date) {
        var map = cache
        map[key] = date
        cache = map
    }

    func clear(key: String) {
        var map = cache
        map.removeValue(forKey: key)
        cache = map
    }
}
