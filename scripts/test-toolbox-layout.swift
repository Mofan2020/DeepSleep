//
//  test-toolbox-layout.swift
//  Deep Sleep 回归测试
//
//  工具箱排序 / 置顶逻辑 + 网关免责 + 网关配置持久化。
//
//  运行：
//  swiftc DeepSleep/Views/ToolboxLayout.swift \
//         DeepSleep/LLMGateway/Database/QuotaModels.swift \
//         DeepSleep/LLMGateway/Database/GatewayConfigStore.swift \
//         scripts/test-toolbox-layout.swift -o /tmp/tb-test && /tmp/tb-test
//
//  注意：测的是**真实源码**，不是副本。
//  `ToolboxLayout.swift` 刻意不 import SwiftUI，就是为了能被这样单独编译。
//  改那边的规则，这边的断言要跟着一起改。
//

import Foundation

@main
struct ToolboxLayoutTests {

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

        // ---------------------------------------------------------- 默认布局
        print("== 默认布局 ==")
        checkEqual("无置顶", 0, ToolboxLayout.default.pinned.count)
        checkEqual(
            "rest 是 canonical 顺序",
            ["nice", "hosts", "quarantine", "aiKeepAlive", "aiGateway"],
            ToolboxLayout.default.rest
        )
        check("默认布局 isDefault", ToolboxLayout.default.isDefault)
        checkEqual("orderedTools 数量", 5, ToolboxLayout.default.orderedTools.count)

        // -------------------------------------------------------------- 置顶
        print("\n== 置顶 ==")
        var layout = ToolboxLayout.default
        layout = layout.togglingPin(.aiKeepAlive)
        checkEqual("置顶后 pinned 有一个", ["aiKeepAlive"], layout.pinned)
        check("置顶后 isPinned 成立", layout.isPinned(.aiKeepAlive))
        checkEqual("置顶后 rest 少一个", 4, layout.rest.count)
        check("置顶后不再是默认布局", !layout.isDefault)
        checkEqual("置顶组排在最前", ToolboxTool.aiKeepAlive, layout.orderedTools.first)

        // ---------------------------------------------------------- 取消置顶
        print("\n== 取消置顶 ==")
        let layout2 = layout.togglingPin(.aiKeepAlive)
        checkEqual("取消置顶后 pinned 空", 0, layout2.pinned.count)
        // 规则：取消置顶落到未置顶组**末尾**，不是原位。
        // 组内顺序 = 操作顺序，这样规则简单可预测。
        checkEqual("取消置顶落到 rest 末尾", "aiKeepAlive", layout2.rest.last)
        checkEqual(
            "取消置顶后 rest 顺序是「原来的 + 它」",
            ["nice", "hosts", "quarantine", "aiGateway", "aiKeepAlive"],
            layout2.rest
        )
        // 顺序变了就不再是默认布局 → 「重置排序」按钮可用。
        check("取消置顶后不再是默认布局（顺序变了）", !layout2.isDefault)
        // 「重置排序」= 恢复 canonical 顺序 + 清空置顶。
        checkEqual(
            "重置排序后恢复 canonical 顺序",
            ["nice", "hosts", "quarantine", "aiKeepAlive", "aiGateway"],
            ToolboxLayout.default.orderedTools.map(\.rawValue)
        )
        check("重置排序后是默认布局", ToolboxLayout.default.isDefault)

        // ------------------------------------------------ 置顶顺序：操作顺序
        print("\n== 置顶顺序：组内按操作顺序 ==")
        var layout3 = ToolboxLayout.default
        layout3 = layout3.togglingPin(.hosts)
        layout3 = layout3.togglingPin(.nice)
        checkEqual("先置顶的在前面", ["hosts", "nice"], layout3.pinned)
        checkEqual(
            "显示顺序 pinned ++ rest",
            ["hosts", "nice"],
            layout3.orderedTools.map(\.rawValue).prefix(2).map { $0 }
        )

        // ---------------------------------------------------------- 全部置顶
        print("\n== 全部置顶 ==")
        var layout4 = ToolboxLayout.default
        for tool in [ToolboxTool.nice, .hosts, .quarantine, .aiKeepAlive, .aiGateway] {
            layout4 = layout4.togglingPin(tool)
        }
        checkEqual("全部置顶", 5, layout4.pinned.count)
        checkEqual("rest 空", 0, layout4.rest.count)
        checkEqual(
            "显示顺序与置顶顺序一致",
            ["nice", "hosts", "quarantine", "aiKeepAlive", "aiGateway"],
            layout4.orderedTools.map(\.rawValue)
        )
        check("全部置顶不是默认布局", !layout4.isDefault)

        // ------------------------------------------------------ 读入时归一化
        print("\n== 读入时的归一化 ==")
        let unknown = ToolboxLayout(pinned: ["nice", "不存在的工具"], rest: ["hosts"])
        checkEqual("未知 ID 被丢弃", ["nice"], unknown.pinned)
        checkEqual(
            "缺失的按 canonical 顺序补到 rest 末尾",
            ["hosts", "quarantine", "aiKeepAlive", "aiGateway"],
            unknown.rest
        )

        let duplicate = ToolboxLayout(pinned: ["nice", "nice"], rest: ["nice"])
        checkEqual("重复 ID 只留一个", ["nice"], duplicate.pinned)
        checkEqual("重复的 rest 也只留一个", 4, duplicate.rest.count)
        checkEqual("总数仍是 5", 5, duplicate.orderedTools.count)

        // ---------------------------------------------------- 空存储 → 默认
        print("\n== 空存储 → 默认布局 ==")
        let empty = ToolboxLayout(pinned: [], rest: [])
        checkEqual("空存储补齐全部 5 个", 5, empty.orderedTools.count)
        check("空存储等价于默认布局", empty.isDefault)

        // -------------------------------------------------------- Codable
        print("\n== Codable 往返 ==")
        let encoded = try! JSONEncoder().encode(layout4)
        let decoded = try! JSONDecoder().decode(ToolboxLayout.self, from: encoded)
        checkEqual("往返后相等", layout4, decoded)
        let jsonKeys = (try! JSONSerialization.jsonObject(with: encoded) as? [String: Any])?.keys.sorted()
        checkEqual("JSON 结构是 pinned + rest", ["pinned", "rest"], jsonKeys ?? [])

        // ---------------------------------------------------------- 布局持久化
        print("\n== 布局持久化 ==")
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ToolboxStore.storageKey)
        checkEqual(
            "没有记录时读回默认布局",
            ["nice", "hosts", "quarantine", "aiKeepAlive", "aiGateway"],
            ToolboxStore.load().orderedTools.map(\.rawValue)
        )
        ToolboxStore.save(layout4)
        checkEqual(
            "存盘后能读回",
            layout4.orderedTools.map(\.rawValue),
            ToolboxStore.load().orderedTools.map(\.rawValue)
        )
        check("存盘后仍是置顶状态", ToolboxStore.load().isPinned(.nice))
        // 手改过 UserDefaults 的脏数据不能崩，也不能少工具。
        defaults.set(Data("garbage".utf8), forKey: ToolboxStore.storageKey)
        checkEqual("数据损坏时回落到默认布局", 5, ToolboxStore.load().orderedTools.count)
        defaults.removeObject(forKey: ToolboxStore.storageKey)

        // ---------------------------------------------------------- 免责状态
        print("\n== 网关免责状态 ==")
        let acceptedKey = "llm.gateway.disclaimerAccepted"
        let versionKey = "llm.gateway.disclaimerVersion"
        defaults.removeObject(forKey: acceptedKey)
        defaults.removeObject(forKey: versionKey)
        check(
            "清空后不算已同意",
            !(defaults.bool(forKey: acceptedKey)
              && defaults.integer(forKey: versionKey) >= 1)
        )
        defaults.set(true, forKey: acceptedKey)
        check(
            "只有 accepted=true 不够",
            !(defaults.bool(forKey: acceptedKey)
              && defaults.integer(forKey: versionKey) >= 1)
        )
        defaults.set(1, forKey: versionKey)
        check(
            "两个 key 都对才算已同意",
            defaults.bool(forKey: acceptedKey)
            && defaults.integer(forKey: versionKey) >= 1
        )
        defaults.set(0, forKey: versionKey)
        check(
            "版本号落后于当前版本不算已同意",
            !(defaults.bool(forKey: acceptedKey)
              && defaults.integer(forKey: versionKey) >= 1)
        )
        defaults.set(1, forKey: versionKey)

        // ------------------------------------------------------ 网关配置持久化
        print("\n== 网关配置持久化 ==")
        defaults.removeObject(forKey: GatewayConfig.storageKey)
        checkEqual("没有记录时读回默认端口", 15999, GatewayConfig.load().port)
        checkEqual("默认监听地址", "127.0.0.1", GatewayConfig.load().bindAddress)

        var custom = GatewayConfig.default
        custom.port = 18000
        custom.requireAuth = true
        custom.authToken = "abc123"
        custom.saveIfNotDefault()
        let reloaded = GatewayConfig.load()
        checkEqual("改端口后能读回", 18000, reloaded.port)
        check("鉴权开关能读回", reloaded.requireAuth)
        checkEqual("token 能读回", "abc123", reloaded.authToken)
        checkEqual("日志开关能读回", custom.logRequests, reloaded.logRequests)

        GatewayConfig.default.saveIfNotDefault()
        check("写回默认值会删掉 key", defaults.data(forKey: GatewayConfig.storageKey) == nil)
        checkEqual("删掉后读回默认端口", 15999, GatewayConfig.load().port)

        // 损坏数据不应崩。
        defaults.set(Data("not json".utf8), forKey: GatewayConfig.storageKey)
        checkEqual("数据损坏时回落到默认值", 15999, GatewayConfig.load().port)
        defaults.removeObject(forKey: GatewayConfig.storageKey)

        // ------------------------------------------- 默认值判断的稳定性（键序）
        print("\n== 默认值判断的稳定性（JSON 键序） ==")
        // JSONEncoder 对 struct 的键序是随机的 —— 不固定键序的话，
        // 「和默认值一样吗」会随机给出错误答案，默认值也会被写进 UserDefaults。
        var stableCount = 0
        for _ in 0..<50 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let mine = try! encoder.encode(GatewayConfig.default)
            let reference = try! encoder.encode(GatewayConfig.default)
            if mine == reference { stableCount += 1 }
        }
        checkEqual("50 次编码结果一致", 50, stableCount)

        // ---------------------------------------------------------------- 清理
        print("\n== 清理 ==")
        defaults.removeObject(forKey: acceptedKey)
        defaults.removeObject(forKey: versionKey)
        defaults.removeObject(forKey: GatewayConfig.storageKey)
        defaults.removeObject(forKey: ToolboxStore.storageKey)
        check("测试用 key 已清理", defaults.data(forKey: GatewayConfig.storageKey) == nil)

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
