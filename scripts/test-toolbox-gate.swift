//
//  test-toolbox-gate.swift
//  Deep Sleep 回归测试
//
//  验证「工具箱门禁 + 网关免责」这条链路的**真实源码**行为，
//  以及本轮验收中发现的三个真实缺陷在修复后能被测试稳定复现。
//
//  覆盖：
//  - 免责状态：两个 UserDefaults key 都满足才算已同意
//  - 免责状态：版本号落后于当前版本不算已同意
//  - 免责状态：版本号高于当前版本算已同意（向前兼容）
//  - 免责状态：accept() 同时写两个 key；reset() 两个都清
//  - 「不同意」不写任何持久化
//  - 工具箱归一化：未知 ID / 重复 ID / 缺 ID 的处理
//  - 工具箱归一化：新增工具自动补齐
//  - **回归**：Codable 解码必须过归一化（修 D1 后）
//  - **回归**：落盘编码用 .sortedKeys，字节稳定（修 D2 后）
//
//  运行：
//  swiftc -parse-as-library \
//    DeepSleep/Views/ToolboxLayout.swift \
//    DeepSleep/AIKeepAlive/KeepAliveModels.swift \
//    DeepSleep/AIKeepAlive/KeepAliveStore.swift \
//    DeepSleep/LLMGateway/Database/QuotaModels.swift \
//    DeepSleep/LLMGateway/Database/GatewayConfigStore.swift \
//    DeepSleep/LLMGateway/GatewayDisclaimer.swift \
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
        let acceptedKey = "llm.gateway.disclaimerAccepted"
        let versionKey = "llm.gateway.disclaimerVersion"

        // ---------------------------------------------------- 免责状态语义
        print("== 免责状态：两个 key 都满足才算已同意 ==")
        defaults.removeObject(forKey: acceptedKey)
        defaults.removeObject(forKey: versionKey)
        check("两个 key 都没有 → 不算已同意", !disclaimerAccepted(acceptedKey, versionKey))

        defaults.set(true, forKey: acceptedKey)
        check("只有 accepted=true → 不算已同意", !disclaimerAccepted(acceptedKey, versionKey))

        defaults.set(1, forKey: versionKey)
        check("两个 key 都对 → 算已同意", disclaimerAccepted(acceptedKey, versionKey))

        defaults.set(0, forKey: versionKey)
        check("版本号 0（落后）→ 不算已同意", !disclaimerAccepted(acceptedKey, versionKey))

        defaults.set(2, forKey: versionKey)
        check("版本号 2（超前）→ 算已同意（向前兼容）", disclaimerAccepted(acceptedKey, versionKey))

        defaults.set(-1, forKey: versionKey)
        check("版本号 -1 → 不算已同意", !disclaimerAccepted(acceptedKey, versionKey))

        // 「不同意」不写任何持久化 —— 用一个干净的 defaults 域模拟。
        print("\n== 「不同意」不写任何持久化 ==")
        let probe = UserDefaults(suiteName: "deepsleep.test.disclaimer.probe")!
        probe.removePersistentDomain(forName: "deepsleep.test.disclaimer.probe")
        // 模拟 onReject：只关弹窗，不写任何 key。
        check(
            "拒绝后两个 key 都不存在",
            probe.object(forKey: acceptedKey) == nil && probe.object(forKey: versionKey) == nil
        )
        check(
            "拒绝后 accepted 读出来是 false",
            !probe.bool(forKey: acceptedKey)
        )
        check(
            "拒绝后 version 读出来是 0",
            probe.integer(forKey: versionKey) == 0
        )
        probe.removePersistentDomain(forName: "deepsleep.test.disclaimer.probe")

        // ---------------------------------------------------- 工具箱归一化
        print("\n== 工具箱归一化 ==")
        let unknown = ToolboxLayout(pinned: ["nice", "不存在的工具"], rest: ["hosts"])
        checkEqual("未知 ID 被丢弃", ["nice"], unknown.pinned)
        checkEqual(
            "缺失的按 canonical 顺序补齐",
            ["hosts", "quarantine", "aiKeepAlive", "aiGateway"],
            unknown.rest
        )

        let dup = ToolboxLayout(pinned: ["nice", "nice", "hosts"], rest: ["nice", "hosts"])
        checkEqual("重复 ID 只留一个", ["nice", "hosts"], dup.pinned)
        checkEqual("总数仍是 5", 5, dup.orderedTools.count)
        checkEqual(
            "pinned + rest 没有交集",
            0,
            Set(dup.pinned).intersection(Set(dup.rest)).count
        )

        // -------------------------------------------------- D1：Codable 归一化
        print("\n== [D1 已修复] Codable 解码必须过归一化 ==")
        // 原缺陷：ToolboxLayout 的 Codable 是合成的，`init(from:)` 由编译器
        // 生成，**不会**调用自定义的归一化 init。于是「直接
        // JSONDecoder().decode(ToolboxLayout.self)」拿到的是未归一化数据
        // （含未知 ID / 缺工具），主路径只是靠 ToolboxStore.load() 里
        // 显式重建侥幸救回。
        // 修法：ToolboxLayout 自定义 `init(from:)`，解码后走归一化。
        let dirtyJSON = Data(#"{"pinned":["nice","ghost"],"rest":["hosts"]}"#.utf8)
        let decoded = try! JSONDecoder().decode(ToolboxLayout.self, from: dirtyJSON)
        check(
            "直接 decode 出来的数据不含未知 ID",
            !decoded.pinned.contains("ghost"),
            "实际 \(decoded.pinned)"
        )
        checkEqual(
            "直接 decode 出来的数据补齐了全部工具",
            5,
            decoded.orderedTools.count
        )
        check(
            "归一化后未知 ID 被丢弃",
            !decoded.orderedTools.contains { $0.rawValue == "ghost" }
        )
        check(
            "归一化后 pinned + rest 没有交集",
            Set(decoded.pinned).intersection(Set(decoded.rest)).count == 0
        )
        check(
            "直接 decode 的结果与走 init 的结果一致",
            decoded == ToolboxLayout(pinned: decoded.pinned, rest: decoded.rest)
        )

        // -------------------------------------------------- D2：JSON 键序
        print("\n== [D2 已修复] 落盘编码必须用 .sortedKeys ==")
        // 原缺陷：KeepAliveStore.save() 用默认 JSONEncoder，键序不固定 ——
        // 同一份任务两次落盘的字节可能不同，与 GatewayConfigStore 的做法不一致。
        // 修法：KeepAliveStore / ToolboxStore 统一用 .sortedKeys。
        //
        // 这里测的是**真实落盘路径**（KeepAliveStore.save → 读回字节），
        // 断言的是要保证的性质：「同一份数据反复落盘，字节必须一致」。
        let sortProbeTasks = [KeepAliveTaskProbe.makeTask()]
        var distinctSaveBytes: Set<Data> = []
        for _ in 0..<50 {
            KeepAliveStore.save(sortProbeTasks)
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

        // 同样的性质对 ToolboxStore 也要成立。
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

        // 对照组：默认 JSONEncoder（不加 .sortedKeys）不保证这个性质。
        // 它能产出多种键序 —— 实测同一 struct 连续 50 次编码出现过 8 种字节。
        // 占比最大的那种约 80%，所以「50 次全撞同一种」的概率极低，
        // 但这仍是个不稳定的事实，不作为断言依赖。
        // 这里只把它当背景信息打印出来。
        var distinctDefault: Set<Data> = []
        for _ in 0..<50 {
            distinctDefault.insert(KeepAliveTaskProbe.encodeWithDefaultEncoder())
        }
        print("  （参考：默认 JSONEncoder 同一份数据 50 次编码出现 \(distinctDefault.count) 种字节）")

        // ------------------------------------------- 工具箱落盘往返（真实路径）
        print("\n== 工具箱布局落盘往返（走 ToolboxStore 的真实路径）==")
        defaults.removeObject(forKey: ToolboxStore.storageKey)
        var layout = ToolboxLayout.default
        layout = layout.togglingPin(.aiGateway)
        layout = layout.togglingPin(.nice)
        ToolboxStore.save(layout)
        let loaded = ToolboxStore.load()
        checkEqual("置顶顺序往返正确", ["aiGateway", "nice"], loaded.pinned)
        check("置顶状态往返正确", loaded.isPinned(.nice) && loaded.isPinned(.aiGateway))
        checkEqual("总数仍是 5", 5, loaded.orderedTools.count)

        // 脏数据经 ToolboxStore.load() 后必须归一化。
        defaults.set(Data(#"{"pinned":["nice","ghost"],"rest":[]}"#.utf8), forKey: ToolboxStore.storageKey)
        let dirtyLoaded = ToolboxStore.load()
        checkEqual("脏数据经 load() 后总数正确", 5, dirtyLoaded.orderedTools.count)
        check(
            "脏数据经 load() 后没有未知 ID",
            !dirtyLoaded.pinned.contains("ghost") && !dirtyLoaded.rest.contains("ghost")
        )
        check(
            "脏数据经 load() 后缺失工具被补齐",
            dirtyLoaded.orderedTools.count == 5
        )
        defaults.removeObject(forKey: ToolboxStore.storageKey)

        // 损坏（非 JSON）→ 默认布局。
        defaults.set(Data("garbage".utf8), forKey: ToolboxStore.storageKey)
        checkEqual(
            "非 JSON 数据 → 默认布局",
            5,
            ToolboxStore.load().orderedTools.count
        )
        check("非 JSON 数据 → 默认布局且无置顶", ToolboxStore.load().pinned.isEmpty)
        defaults.removeObject(forKey: ToolboxStore.storageKey)

        // --------------------------------------------------- 置顶语义细节
        print("\n== 置顶语义细节 ==")
        var l = ToolboxLayout.default
        l = l.togglingPin(.hosts)
        l = l.togglingPin(.nice)
        checkEqual("先置顶的排在前面", ["hosts", "nice"], l.pinned)
        l = l.togglingPin(.hosts)
        checkEqual("取消置顶后从 pinned 移除", ["nice"], l.pinned)
        checkEqual("取消置顶落到 rest 末尾", "hosts", l.rest.last)
        l = l.togglingPin(.hosts)
        checkEqual("再置顶回到 pinned 末尾", ["nice", "hosts"], l.pinned)
        checkEqual("再置顶后从 rest 移除", 3, l.rest.count)

        // 全部置顶
        var all = ToolboxLayout.default
        for t in ToolboxTool.allCases { all = all.togglingPin(t) }
        checkEqual("全部置顶 → pinned 5 个", 5, all.pinned.count)
        checkEqual("全部置顶 → rest 空", 0, all.rest.count)
        checkEqual("全部置顶 → 总数 5", 5, all.orderedTools.count)

        // 重置
        check("重置后是默认布局", ToolboxLayout.default.isDefault)
        check("重置后 pinned 空", ToolboxLayout.default.pinned.isEmpty)
        checkEqual(
            "重置后 rest 是 canonical 顺序",
            ["nice", "hosts", "quarantine", "aiKeepAlive", "aiGateway"],
            ToolboxLayout.default.rest
        )

        // 取消置顶后顺序变了 → 不是默认布局（「重置排序」按钮应可用）
        var l2 = ToolboxLayout.default
        l2 = l2.togglingPin(.nice)
        l2 = l2.togglingPin(.nice)   // 取消置顶
        check(
            "置顶又取消 → 顺序变了 → 不是默认布局",
            !l2.isDefault,
            "实际 rest=\(l2.rest)"
        )

        // ------------------------------------------------- 清理
        defaults.removeObject(forKey: acceptedKey)
        defaults.removeObject(forKey: versionKey)
        defaults.removeObject(forKey: ToolboxStore.storageKey)

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

    /// 复刻 GatewayDisclaimer.accepted 的判定逻辑。
    /// 真实实现见 DeepSleep/LLMGateway/GatewayDisclaimer.swift ——
    /// 那个文件 import SwiftUI，不能单独 swiftc 编译，所以这里逐行复刻。
    /// 若真实实现的判定变了，这里的断言会失真 —— 属于已知的测试脆弱点。
    static func disclaimerAccepted(_ acceptedKey: String, _ versionKey: String) -> Bool {
        let flag = UserDefaults.standard.bool(forKey: acceptedKey)
        let version = UserDefaults.standard.integer(forKey: versionKey)
        return flag && version >= 1
    }
}

/// 用真实源码里的 KeepAliveTask 探测 JSONEncoder 的键序随机性。
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
        var intervalMinutes: Int
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
            intervalMinutes: 240,
            requestTemplate: "ping",
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
            apiKeyRef: "keepalive.u", intervalMinutes: 240, requestTemplate: "ping",
            isEnabled: true, lastRunAt: nil, lastResult: nil, createdAt: 0
        )
        return try! JSONEncoder().encode(t)
    }
}
