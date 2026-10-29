//
//  test-fan-mode-store.swift
//  DeepSleep
//
//  风扇模式（含调速规则）的持久化自测。
//
//  为什么单独测：用户报过「调速参数根本没保存 —— 切到别的页面再回来还是原样」。
//  根因有两层：规则只在内存里（退出就没了），以及界面自己存了一份 @State
//  而没有回读（切页回来视图重建，@State 回默认值）。
//  这一层测的是「存下来能不能读回来、读回来是不是原样」。
//
//  运行： bash scripts/test-fan-mode-store.sh
//

import Foundation

@main
struct FanModeStoreTests {

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

        func checkEqual<T: Equatable>(_ name: String, _ lhs: T, _ rhs: T) {
            if lhs == rhs {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)：期望 \(rhs)，实际 \(lhs)")
                failures += 1
            }
        }

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: FanModeStore.storageKey)

        // MARK: - 空态

        print("\n== 空态 ==")

        checkEqual("存储键是 fanModes.v1", FanModeStore.storageKey, "fanModes.v1")
        checkEqual("没有数据时读出空表", FanModeStore.load().count, 0)

        // MARK: - 往返

        print("\n== 存取往返 ==")

        // 用户配的那条规则：目标风扇 1，最低 55°C，最高 88°C
        let rule = FanMode.rule(targetFan: 1, minTempC: 55, maxTempC: 88)
        let modes: [Int: FanMode] = [
            0: .automatic,
            1: rule,
            2: .fixed(rpm: 1500)
        ]
        FanModeStore.save(modes)

        let loaded = FanModeStore.load()
        checkEqual("读回来的条数", loaded.count, 3)
        checkEqual("规则读回来一模一样", loaded[1], rule)
        checkEqual("自动模式读回来", loaded[0], .automatic)
        checkEqual("固定转速读回来", loaded[2], .fixed(rpm: 1500))

        // MARK: - 规则里的三个字段都在

        print("\n== 规则三要素（目标风扇 / 最低温度 / 最高温度）==")

        if case .rule(let target, let low, let high) = loaded[1] {
            checkEqual("目标风扇", target, 1)
            checkEqual("最低温度", low, 55.0)
            checkEqual("最高温度", high, 88.0)
        } else {
            check("读回来的是规则模式", false, "实际 \(String(describing: loaded[1]))")
        }

        // MARK: - 覆盖写

        print("\n== 覆盖写 ==")

        FanModeStore.save([0: .fixed(rpm: 2200)])
        checkEqual("覆盖后只剩一条", FanModeStore.load().count, 1)
        checkEqual("覆盖后内容正确", FanModeStore.load()[0], .fixed(rpm: 2200))

        // MARK: - 清空

        print("\n== 清空 ==")

        FanModeStore.save([:])
        checkEqual("空表写完读回来是空的", FanModeStore.load().count, 0)
        check("空表时把 key 删掉，不留空壳",
              defaults.data(forKey: FanModeStore.storageKey) == nil)

        // MARK: - 损坏数据

        print("\n== 损坏数据 ==")

        defaults.set(Data("这不是 JSON".utf8), forKey: FanModeStore.storageKey)
        checkEqual("内容损坏时读出空表（不崩）", FanModeStore.load().count, 0)

        defaults.removeObject(forKey: FanModeStore.storageKey)

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
