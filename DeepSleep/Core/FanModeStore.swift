//
//  FanModeStore.swift
//  Deep Sleep
//
//  风扇模式的持久化。
//
//  键 `fanModes.v1`，值是「风扇序号 → 模式」。
//
//  为什么要有这一层：调速规则（目标风扇 / 最低温度 / 最高温度）是用户配的东西。
//  只放在内存里等于没保存 —— 切到别的页面再回来就没了，退出应用更没。
//
//  键用字符串而不是整数：JSON 的对象键只能是字符串，用 `[Int: FanMode]`
//  编码时 Foundation 会隐式转换，显式转一道省得踩类型转换的坑。
//

import Foundation

enum FanModeStore {

    static let storageKey = "fanModes.v1"

    /// 读回全部模式。存储不存在或内容损坏时返回空表。
    static func load() -> [Int: FanMode] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
        do {
            let raw = try JSONDecoder().decode([String: FanMode].self, from: data)
            var result: [Int: FanMode] = [:]
            for (key, mode) in raw {
                if let index = Int(key) { result[index] = mode }
            }
            return result
        } catch {
            NSLog("[DeepSleep] 风扇模式读取失败，已忽略：\(error.localizedDescription)")
            return [:]
        }
    }

    /// 写全部模式。空表时删掉 key，不留空壳。
    static func save(_ modes: [Int: FanMode]) {
        let defaults = UserDefaults.standard
        guard !modes.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        var raw: [String: FanMode] = [:]
        for (index, mode) in modes {
            raw[String(index)] = mode
        }
        let encoder = JSONEncoder()
        // 固定键序：同一个值多次编码能产出好几种字节，便于排查「到底存了什么」。
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(raw) else {
            NSLog("[DeepSleep] 风扇模式编码失败，本次改动未落盘")
            return
        }
        defaults.set(data, forKey: storageKey)
    }
}
