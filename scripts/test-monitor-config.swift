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

        // 用**独立的 suite**而不是 `UserDefaults.standard`。
        //
        // `monitorConfig.v1` 是 App 真实在用的键名 —— 拿 standard 去写，
        // 跑一次测试就把用户真的监控配置改了（阈值、采样间隔全丢）。
        // 独立 suite 有自己的偏好域，跟 App 那边互不干扰。
        //
        // suite 名通过环境变量注入：`MonitorConfig` 的存储位置在**类加载时**
        // 就定下来了（static let 只算一次），测试代码没法在运行时再改它。
        // 环境变量是唯一能在进程启动前就把它定好的入口。
        //
        // 结束前必须清干净：suite 里的东西留在磁盘上，下次跑会读到上次的残留。
        let suiteName = "com.skyc8266.deepsleep.tests.monitor-config"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            print("  [失败] 建不出独立的 UserDefaults suite")
            print("\n测试结论: 1 项失败")
            exit(1)
        }
        defaults.removePersistentDomain(forName: suiteName)
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

        // ------------------------------------------------- CPU 温度开关迁移
        //
        // v1.7.2 那版 CPU 温度走 SMC，Apple Silicon 上读不到任何 key，
        // 于是「读到空采样 → 自动把 cpuTempEnabled 写成 false 并落盘」。
        // v1.7.4 又把界面开关锁死成 false，用户改不回来。
        // v1.9.3 温度改走 IOHID 通道后，这个 false 必须还回去。
        print("\n== CPU 温度开关迁移 ==")

        let migrationFlag = "monitorConfig.migrated.cpuTempIOHID"
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: migrationFlag)

        // 模拟老存档：cpuTempEnabled 被自动关成 false，其它字段是用户改过的值。
        var legacy = MonitorConfig.default
        legacy.cpuTempEnabled = false
        legacy.ramHighPercent = 95.5
        legacy.cpuHighPercent = 95.7
        legacy.singleProcessRAMBytes = 8 * 1024 * 1024 * 1024
        legacy.sampleIntervalSeconds = 5
        legacy.saveIfNotDefault()

        let migrated = MonitorConfig.load()
        check("迁移后 CPU 温度开关恢复为开启", migrated.cpuTempEnabled)
        check("迁移不碰 RAM 阈值", migrated.ramHighPercent == 95.5,
              "实际 \(migrated.ramHighPercent)")
        check("迁移不碰 CPU 阈值", migrated.cpuHighPercent == 95.7,
              "实际 \(migrated.cpuHighPercent)")
        check("迁移不碰单进程 RAM 阈值",
              migrated.singleProcessRAMBytes == 8 * 1024 * 1024 * 1024,
              "实际 \(migrated.singleProcessRAMBytes)")
        check("迁移不碰采样间隔", migrated.sampleIntervalSeconds == 5,
              "实际 \(migrated.sampleIntervalSeconds)")
        check("迁移标记已落盘", defaults.object(forKey: migrationFlag) != nil)

        // 迁移只做一次：用户之后自己把开关关掉，load() 不该再把它打开。
        var userDisabled = migrated
        userDisabled.cpuTempEnabled = false
        userDisabled.saveIfNotDefault()
        check("用户主动关掉后不会被迁移改回", !MonitorConfig.load().cpuTempEnabled)

        // 没有老存档时（全新安装）不该凭空写迁移标记以外的东西。
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: migrationFlag)
        check("没有存档时读回默认配置", MonitorConfig.load() == MonitorConfig.default)
        check("默认配置的 CPU 温度开关本来就是开的",
              MonitorConfig.default.cpuTempEnabled)

        // --------------------------------------------------------- 汇总
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
