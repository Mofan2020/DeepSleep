//
//  test-monitor-config.swift
//  Deep Sleep 回归测试
//
//  验证 MonitorConfig 的 UserDefaults 持久化：
//  - 「和默认值一样吗」的判断必须稳定（JSONEncoder 键序不固定会破坏它）
//  - 是默认值 → 删掉 key
//  - 不是默认值 → 写入且能读回
//  - 数据损坏 → 回落默认值
//
//  运行：
//  swiftc -parse-as-library \
//    DeepSleep/Core/SystemMonitor.swift \
//    DeepSleep/Core/MonitorConfig.swift \
//    scripts/test-monitor-config.swift -o /tmp/mc-test && /tmp/mc-test
//

import Foundation

@main
struct MonitorConfigTests {

    static func main() {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ actual: String = "") {
            if condition {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)" + (actual.isEmpty ? "" : " —— 实际: \(actual)"))
                failures += 1
            }
        }

        func checkEqual<T: Equatable>(_ name: String, _ expected: T, _ actual: T) {
            check(name, expected == actual, "期望 \(expected)，实际 \(actual)")
        }

        let defaults = UserDefaults.standard
        let key = "monitorConfig.v1"
        defaults.removeObject(forKey: key)

        // --------------------------------------------------- 默认值判断的稳定性
        print("== 默认值判断的稳定性（JSON 键序）==")
        // 复刻 saveIfNotDefault 的比较逻辑：同一份数据反复编码，
        // 每次都要和 defaultJSON 逐字节相等。
        // 编码器键序不固定时，这个比较会随机失败。
        let defaultJSON: Data? = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try? encoder.encode(MonitorConfig.default)
        }()
        check("默认配置能编码出 JSON", defaultJSON != nil)

        var mismatches = 0
        for _ in 0..<200 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let mine = try? encoder.encode(MonitorConfig.default),
                  let base = defaultJSON else { continue }
            if mine != base { mismatches += 1 }
        }
        checkEqual("200 次编码同一个默认配置，字节全部一致", 0, mismatches)

        // 对照组：默认 JSONEncoder（不加 .sortedKeys）不保证这一点。
        // 这个事实是「必须显式 .sortedKeys」的原因，不是断言对象。
        var distinctDefault: Set<Data> = []
        for _ in 0..<200 {
            if let d = try? JSONEncoder().encode(MonitorConfig.default) {
                distinctDefault.insert(d)
            }
        }
        print("  （参考：默认 JSONEncoder 编码默认配置出现 \(distinctDefault.count) 种字节）")

        // 真实场景：`defaultJSON` 是类加载时编码一次存下的，用户改回默认值
        // 后再编码一次，两次的键序可能不同 → 逐字节比较会误判成
        // 「不等于默认值」，该删的 key 删不掉。
        // 断言要保证的是「有 .sortedKeys 时一定稳定」：
        var stableMismatch = 0
        for _ in 0..<200 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let mine = try? encoder.encode(MonitorConfig.default),
               let base = defaultJSON,
               mine != base {
                stableMismatch += 1
            }
        }
        checkEqual("加 .sortedKeys 后与 defaultJSON 的比较 200 次全一致", 0, stableMismatch)

        // --------------------------------------------------------- 落盘往返
        print("\n== 落盘往返 ==")
        defaults.removeObject(forKey: key)
        check("没有记录时读回默认配置", MonitorConfig.load() == MonitorConfig.default)

        var custom = MonitorConfig.default
        custom.ramHighPercent = 92
        custom.nicePageSize = 30
        custom.emailAlertEnabled = true
        custom.saveIfNotDefault()
        check("非默认值会写进 UserDefaults", defaults.data(forKey: key) != nil)

        let loaded = MonitorConfig.load()
        checkEqual("读回后的 RAM 阈值一致", 92.0, loaded.ramHighPercent)
        checkEqual("读回后的每页条数一致", 30, loaded.nicePageSize)
        check("读回后的邮件开关一致", loaded.emailAlertEnabled)

        // -------------------------------------------------- 写回默认值会删 key
        print("\n== 写回默认值会删掉 key ==")
        var back = MonitorConfig.default
        back.ramHighPercent = 92
        back.saveIfNotDefault()
        check("先写一份非默认值", defaults.data(forKey: key) != nil)
        MonitorConfig.default.saveIfNotDefault()
        check(
            "写回默认值后 key 被删掉",
            defaults.data(forKey: key) == nil
        )
        check("删掉后读回仍是默认配置", MonitorConfig.load() == MonitorConfig.default)

        // 反复写回默认值不应留下任何残留
        for _ in 0..<20 {
            MonitorConfig.default.saveIfNotDefault()
        }
        check(
            "反复写回默认值 20 次，key 仍然不存在",
            defaults.data(forKey: key) == nil
        )

        // --------------------------------------------------------- 数据损坏
        print("\n== 数据损坏 ==")
        defaults.set(Data("这不是 JSON".utf8), forKey: key)
        check("数据损坏时读回默认配置", MonitorConfig.load() == MonitorConfig.default)
        defaults.removeObject(forKey: key)

        // --------------------------------------------------------- 汇总
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
