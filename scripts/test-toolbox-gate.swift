//
//  test-toolbox-gate.swift
//  Deep Sleep 回归测试
//
//  验证两件事：
//  1. **网关彻底不可见**：工具清单里没有它，存储里的旧 ID 会被清掉，
//     保活也不依赖网关的任何类型（独立编译即可证明）。
//  2. **保活的持久化性质**：落盘字节稳定（.sortedKeys）、旧格式能迁移。
//
//  原来的这个脚本测的是「工具箱门禁 + 网关免责」——网关既然后来整块
//  隐藏了，免责链路不再有意义（用户根本走不到那张弹窗），
//  所以改成验证「网关不可见」这件事本身。
//
//  运行：
//  swiftc -parse-as-library \
//    DeepSleep/Views/ToolboxLayout.swift \
//    DeepSleep/AIKeepAlive/KeepAliveModels.swift \
//    DeepSleep/AIKeepAlive/KeepAliveError.swift \
//    DeepSleep/AIKeepAlive/KeepAliveStore.swift \
//    DeepSleep/AIKeepAlive/KeepAliveKeychain.swift \
//    scripts/test-toolbox-gate.swift -o /tmp/tb-gate && /tmp/tb-gate
//

import Foundation

@main
struct ToolboxGateTests {

    static var failures = 0
    static var total = 0

    /// 缺陷计数器：这些是**已确认的业务代码缺陷**，测试里标出来但不计入 exit code。
    static var confirmedDefects: [String] = []

    static func check(_ name: String, _ condition: Bool, _ actual: String = "") {
        total += 1
        if condition {
            print("  [通过] \(name)")
        } else {
            print("  [失败] \(name)" + (actual.isEmpty ? "" : " —— 实际: \(actual)"))
            failures += 1
        }
    }

    static func checkEqual<T: Equatable>(_ name: String, _ expected: T, _ actual: T) {
        check(name, expected == actual, "期望 \(expected)，实际 \(actual)")
    }

    /// 记录一个已确认的产品缺陷（测试本身是对的，代码是错的）。
    static func confirmDefect(_ id: String, _ detail: String) {
        confirmedDefects.append("[\(id)] \(detail)")
        print("  [缺陷] \(id)：\(detail)")
    }

    static func main() {
        let defaults = UserDefaults.standard

        // ============================================ 网关彻底不可见
        print("== 网关已隐藏：工具清单里没有它 ==")
        check(
            "ToolboxTool 里没有 aiGateway",
            !ToolboxTool.allCases.contains { $0.rawValue == "aiGateway" },
            "实际 \(ToolboxTool.allCases.map(\.rawValue))"
        )
        checkEqual("工具清单是 4 项", 4, ToolboxTool.allCases.count)
        check(
            "没有叫「网关」的工具",
            !ToolboxTool.allCases.contains { $0.title.contains("网关") },
            "实际 \(ToolboxTool.allCases.map(\.title))"
        )

        print("\n== 网关已隐藏：存储里的旧 ID 被清掉 ==")
        // 网关还在的时候存过布局的用户，升级后那段数据不能把网关带回来。
        let legacyLayout = ToolboxLayout(pinned: ["aiGateway"], rest: ["aiGateway", "nice"])
        check(
            "旧布局里的 aiGateway 不在工具清单里",
            !legacyLayout.orderedTools.contains { $0.rawValue == "aiGateway" },
            "实际 \(legacyLayout.orderedTools.map(\.rawValue))"
        )
        checkEqual("清理后仍是 4 项", 4, legacyLayout.orderedTools.count)

        // 直接解码一份含 aiGateway 的 JSON。
        let legacyJSON = Data(#"{"pinned":["aiGateway"],"rest":["nice"]}"#.utf8)
        let decoded = try! JSONDecoder().decode(ToolboxLayout.self, from: legacyJSON)
        check(
            "直接 decode 出来的数据里没有网关",
            !decoded.orderedTools.contains { $0.rawValue == "aiGateway" },
            "实际 \(decoded.orderedTools.map(\.rawValue))"
        )
        checkEqual(
            "直接 decode 出来的数据补齐了全部工具",
            4,
            decoded.orderedTools.count
        )
        check(
            "归一化后 pinned + rest 没有交集",
            Set(decoded.pinned).intersection(Set(decoded.rest)).count == 0
        )

        // ============================================ 工具箱归一化
        print("\n== 工具箱归一化 ==")
        let unknown = ToolboxLayout(pinned: ["nice", "不存在的工具"], rest: ["hosts"])
        checkEqual("未知 ID 被丢弃", ["nice"], unknown.pinned)
        checkEqual(
            "缺失的按 canonical 顺序补齐",
            ["hosts", "quarantine", "aiKeepAlive"],
            unknown.rest
        )

        let dup = ToolboxLayout(pinned: ["nice", "nice", "hosts"], rest: ["nice", "hosts"])
        checkEqual("重复 ID 只留一个", ["nice", "hosts"], dup.pinned)
        checkEqual("总数仍是 4", 4, dup.orderedTools.count)
        checkEqual(
            "pinned + rest 没有交集",
            0,
            Set(dup.pinned).intersection(Set(dup.rest)).count
        )

        // ============================================ 落盘字节稳定
        print("\n== 落盘编码必须用 .sortedKeys ==")
        // JSONEncoder 对 struct 的键序不固定 —— 同一份数据反复落盘能产出
        // 好几种字节，内容却等价。这里测的是「字节结果唯一」这个性质。
        var distinctSaveBytes: Set<Data> = []
        for _ in 0..<50 {
            KeepAliveStore.save([KeepAliveTaskProbe.makeTask()])
            if let data = UserDefaults.standard.data(forKey: KeepAliveStore.storageKey) {
                distinctSaveBytes.insert(data)
            }
        }
        checkEqual(
            "KeepAliveStore 连续 50 次落盘，字节结果唯一",
            1,
            distinctSaveBytes.count
        )
        UserDefaults.standard.removeObject(forKey: KeepAliveStore.storageKey)

        var distinctLayoutBytes: Set<Data> = []
        for _ in 0..<50 {
            ToolboxStore.save(ToolboxLayout.default)
            if let data = UserDefaults.standard.data(forKey: ToolboxStore.storageKey) {
                distinctLayoutBytes.insert(data)
            }
        }
        checkEqual(
            "ToolboxStore 连续 50 次落盘，字节结果唯一",
            1,
            distinctLayoutBytes.count
        )
        UserDefaults.standard.removeObject(forKey: ToolboxStore.storageKey)

        // 对照组：默认 JSONEncoder 不保证这个性质。
        var distinctDefault: Set<Data> = []
        for _ in 0..<50 {
            distinctDefault.insert(KeepAliveTaskProbe.encodeWithDefaultEncoder())
        }
        print("  （参考：默认 JSONEncoder 同一份数据 50 次编码出现 \(distinctDefault.count) 种字节）")

        // ============================================ 保活落盘往返
        print("\n== 保活任务落盘往返（走 KeepAliveStore 的真实路径）==")
        defaults.removeObject(forKey: KeepAliveStore.storageKey)
        let task = KeepAliveTask(
            id: UUID(),
            name: "门禁测试",
            baseURL: "https://api.example.com",
            format: .openAI,
            model: "m",
            apiKeyRef: "keepalive.test",
            schedule: KeepAliveSchedule(
                times: [KeepAliveTime(hour: 9, minute: 0)],
                weekdays: [2, 3, 4, 5, 6]
            ),
            requestTemplate: KeepAliveDefaults.defaultRequestTemplate,
            isEnabled: true,
            lastRunAt: nil,
            lastResult: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        KeepAliveStore.save([task])
        let loaded = KeepAliveStore.load()
        checkEqual("存盘后能读回", 1, loaded.count)
        checkEqual("时刻保留", ["09:00"], loaded.first?.schedule.times.map(\.display) ?? [])
        checkEqual(
            "星期保留",
            [2, 3, 4, 5, 6],
            loaded.first?.schedule.weekdays.sorted() ?? []
        )

        // 脏数据经 load() 后必须归一化。
        defaults.set(Data(#"{"pinned":["nice","ghost"],"rest":[]}"#.utf8), forKey: ToolboxStore.storageKey)
        let dirtyLoaded = ToolboxStore.load()
        checkEqual("脏数据经 load() 后总数正确", 4, dirtyLoaded.orderedTools.count)
        check(
            "脏数据经 load() 后没有未知 ID",
            !dirtyLoaded.pinned.contains("ghost") && !dirtyLoaded.rest.contains("ghost")
        )
        defaults.removeObject(forKey: ToolboxStore.storageKey)

        // 损坏（非 JSON）→ 默认布局。
        defaults.set(Data("garbage".utf8), forKey: ToolboxStore.storageKey)
        checkEqual(
            "非 JSON 数据 → 默认布局",
            4,
            ToolboxStore.load().orderedTools.count
        )
        check("非 JSON 数据 → 默认布局且无置顶", ToolboxStore.load().pinned.isEmpty)
        defaults.removeObject(forKey: ToolboxStore.storageKey)

        // ============================================ 旧格式迁移
        print("\n== 保活任务旧格式迁移 ==")
        let legacyTaskJSON = """
        [{
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "老任务",
          "baseURL": "https://api.example.com",
          "format": "openai",
          "model": "m",
          "apiKeyRef": "keepalive.legacy",
          "intervalMinutes": 240,
          "requestTemplate": "ping",
          "isEnabled": true,
          "lastRunAt": null,
          "lastResult": null,
          "createdAt": 1700000000
        }]
        """
        defaults.set(Data(legacyTaskJSON.utf8), forKey: KeepAliveStore.storageKey)
        let migrated = KeepAliveStore.load()
        checkEqual("旧任务读得出来", 1, migrated.count)
        checkEqual("旧任务名保留", "老任务", migrated.first?.name ?? "")
        checkEqual(
            "间隔迁移成每日时刻",
            ["00:00", "04:00", "08:00", "12:00", "16:00", "20:00"],
            migrated.first?.schedule.times.map(\.display) ?? []
        )
        checkEqual(
            "迁移后星期是每天",
            [1, 2, 3, 4, 5, 6, 7],
            migrated.first?.schedule.weekdays.sorted() ?? []
        )
        defaults.removeObject(forKey: KeepAliveStore.storageKey)

        // ============================================ 清理
        print("\n== 清理 ==")
        defaults.removeObject(forKey: KeepAliveStore.storageKey)
        defaults.removeObject(forKey: ToolboxStore.storageKey)
        check("测试用 key 已清理", defaults.data(forKey: ToolboxStore.storageKey) == nil)

        print("")
        if confirmedDefects.isEmpty {
            print("已确认缺陷：0")
        } else {
            print("已确认产品缺陷（测试能复现，代码需要改）：\(confirmedDefects.count)")
            for d in confirmedDefects { print("  - \(d)") }
        }
        print(failures == 0
              ? "\n测试结论: 全部通过（\(total) 项断言）"
              : "\n测试结论: \(failures) 项失败（共 \(total) 项断言）")
        exit(failures == 0 ? 0 : 1)
    }
}

/// 用真实源码里的 KeepAliveTask 探测 JSONEncoder 的键序随机性。
///
/// 这里的 KeepAliveTask 定义放在 test-toolbox-gate.swift 里会与
/// ToolboxLayout.swift 冲突（两个文件都要 @main），所以只用一个
/// 结构等价的最小类型来探测 JSONEncoder 行为 ——
/// JSONEncoder 对 struct 的键序行为与类型无关。
enum KeepAliveTaskProbe {
    struct T: Codable {
        var id: String
        var name: String
        var baseURL: String
        var format: String
        var model: String
        var apiKeyRef: String
        var schedule: String
        var requestTemplate: String
        var isEnabled: Bool
        var lastRunAt: Double?
        var lastResult: String?
        var createdAt: Double
    }

    /// 造一个结构等价的任务，用于探测真实落盘路径的字节稳定性。
    static func makeTask() -> KeepAliveTask {
        KeepAliveTask(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "n",
            baseURL: "https://x",
            format: .openAI,
            model: "m",
            apiKeyRef: "keepalive.u",
            schedule: KeepAliveSchedule(
                times: [KeepAliveTime(hour: 9, minute: 0)],
                weekdays: [2]
            ),
            requestTemplate: KeepAliveDefaults.defaultRequestTemplate,
            isEnabled: true,
            lastRunAt: nil,
            lastResult: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// 用**默认** JSONEncoder 编码 —— 用来证明「键序随机」这个语言事实。
    /// 真实落盘路径不该再用它（KeepAliveStore 显式加 .sortedKeys）。
    static func encodeWithDefaultEncoder() -> Data {
        let t = T(
            id: "u", name: "n", baseURL: "https://x", format: "openai", model: "m",
            apiKeyRef: "keepalive.u", schedule: "s", requestTemplate: "ping",
            isEnabled: true, lastRunAt: nil, lastResult: nil, createdAt: 0
        )
        return try! JSONEncoder().encode(t)
    }
}
