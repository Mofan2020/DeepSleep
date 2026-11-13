//
//  test-audio-control.swift
//  DeepSleep
//
//  音频控制纯逻辑的回归护栏。
//
//  为什么只测纯逻辑：音频引擎要真机、真输出设备、真进程才有意义，
// 放进 CI 会既慢又不稳定。所以把**能脱离硬件验证的部分**全部拆到
//  AudioControlSupport 里 —— 增益换算、clamp、合并规则、存储键 ——
//  这里测的是那些真正会算错的地方。
//
//  这条挡的是 v1.12.0 的三个具体错误：
//  1. 增益曲线搞反（音量 50% 变成 200% 增益 → 削波 + 震耳）
//  2. clamp 漏了上界（超过 100% 的值直接进 IOProc → 削波）
//  3. 同 bundleID 的多进程没合并（一个 app 出现两行，音量互相覆盖）
//

import Foundation

@main
struct AudioControlTests {

    static func main() {
        var failures = 0
        var checks = 0

        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if condition {
                print("  [通过] \(name)")
            } else {
                failures += 1
                print("  [失败] \(name)")
            }
        }

        func checkEqual<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
            checks += 1
            if actual == expected {
                print("  [通过] \(name)")
            } else {
                failures += 1
                print("  [失败] \(name)：期望 \(expected)，实际 \(actual)")
            }
        }

        // MARK: - 增益曲线

        print("\n== 增益曲线 ==")

        // 平方曲线：0 → 0, 0.5 → 0.25, 1.0 → 1.0
        checkEqual("音量 0% 的增益是 0", AudioControlSupport.gain(for: 0), 0)
        checkEqual("音量 50% 的增益是 0.25（平方曲线）", AudioControlSupport.gain(for: 0.5), 0.25)
        checkEqual("音量 100% 的增益是 1（unity，不放大）", AudioControlSupport.gain(for: 1.0), 1.0)

        // 关键性质：增益必须 <= 1（放大会导致削波）
        var maxGain: Float = 0
        for step in 0...100 {
            let v = Double(step) / 100.0
            maxGain = max(maxGain, AudioControlSupport.gain(for: v))
        }
        check("全量程增益不超过 1（绝不放大）", maxGain <= 1.0)
        checkEqual("全量程最大增益就是 1", maxGain, 1.0)

        // 增益必须单调递增
        var monotonic = true
        var previous: Float = -1
        for step in 0...100 {
            let g = AudioControlSupport.gain(for: Double(step) / 100.0)
            if g < previous { monotonic = false }
            previous = g
        }
        check("增益随音量单调递增", monotonic)

        // 增益不能是负数
        var anyNegative = false
        for step in 0...100 {
            if AudioControlSupport.gain(for: Double(step) / 100.0) < 0 { anyNegative = true }
        }
        check("增益没有负值", !anyNegative)

        // MARK: - 反向换算

        print("\n== 增益 ↔ 音量 反向换算 ==")

        checkEqual("增益 0.25 还原成音量 50%", AudioControlSupport.volume(from: 0.25), 0.5)
        checkEqual("增益 1.0 还原成音量 100%", AudioControlSupport.volume(from: 1.0), 1.0)
        checkEqual("增益 0 还原成音量 0", AudioControlSupport.volume(from: 0), 0)

        // 往返一致性：volume → gain → volume 必须回到原值
        var roundTripOK = true
        for step in 0...100 {
            let v = Double(step) / 100.0
            let back = AudioControlSupport.volume(from: AudioControlSupport.gain(for: v))
            if abs(back - v) > 0.0001 { roundTripOK = false }
        }
        check("音量→增益→音量 往返一致", roundTripOK)

        // MARK: - Clamp

        print("\n== Clamp ==")

        checkEqual("负值被拉到 0", AudioControlSupport.clampVolume(-0.5), 0)
        checkEqual("超过 1 被拉到 1", AudioControlSupport.clampVolume(1.8), 1.0)
        checkEqual("正常值不动", AudioControlSupport.clampVolume(0.42), 0.42)
        checkEqual("上界就是 maxVolume", AudioControlSupport.clampVolume(100), AudioControlSupport.maxVolume)

        // 越界值进增益函数也不能放大
        check("越界音量进增益函数仍然是 1", AudioControlSupport.gain(for: 99.0) <= 1.0)
        check("负音量进增益函数是 0", AudioControlSupport.gain(for: -3.0) == 0)

        // MARK: - 百分比格式化

        print("\n== 百分比格式化 ==")

        checkEqual("0 格式化成 0%", AudioControlSupport.formatPercent(0), "0%")
        checkEqual("0.5 格式化成 50%", AudioControlSupport.formatPercent(0.5), "50%")
        checkEqual("1 格式化成 100%", AudioControlSupport.formatPercent(1), "100%")
        checkEqual("超界值不会显示成 100% 以上", AudioControlSupport.formatPercent(2.0), "100%")

        // MARK: - 同 bundleID 合并

        print("\n== 同 bundleID 合并 ==")

        let merged = AudioControlSupport.mergeByBundleID([
            (objectID: 1, pid: 100, bundleID: "com.apple.Safari", isProducing: true),
            (objectID: 2, pid: 101, bundleID: "com.apple.Safari", isProducing: false),
            (objectID: 3, pid: 200, bundleID: "com.apple.Music", isProducing: true),
            (objectID: 4, pid: 300, bundleID: nil, isProducing: true),
        ])

        checkEqual("合并后是 3 行（Safari 两个进程合成一行）", merged.count, 3)

        let safari = merged.first { $0.bundleID == "com.apple.Safari" }
        check("Safari 行存在", safari != nil)
        checkEqual("Safari 行收了 2 个进程", safari?.processIDs.count ?? 0, 2)
        checkEqual("Safari 行收了 2 个音频对象", safari?.audioObjectIDs.count ?? 0, 2)
        check("Safari 任一进程在出声就算在出声", safari?.isProducingAudio == true)
        checkEqual("Safari 进程号已排序", safari?.processIDs ?? [], [100, 101])

        let noBundle = merged.first { $0.bundleID == nil }
        check("无 bundleID 的进程单独成行", noBundle != nil)
        check("无 bundleID 的行 ID 是 pid 形式", noBundle?.id.hasPrefix("pid:") == true)

        // 不同的 bundleID 不能被合并
        let music = merged.first { $0.bundleID == "com.apple.Music" }
        check("Music 与 Safari 是不同的行", music?.id != safari?.id)

        // 无 bundleID 的两个不同 pid 不能被合并
        let merged2 = AudioControlSupport.mergeByBundleID([
            (objectID: 10, pid: 400, bundleID: nil, isProducing: true),
            (objectID: 11, pid: 401, bundleID: nil, isProducing: true),
        ])
        checkEqual("两个无 bundleID 的进程是 2 行", merged2.count, 2)

        // MARK: - 显示名

        print("\n== 显示名 ==")

        checkEqual("bundleID 取最后一段", AudioControlSupport.displayName(bundleID: "com.apple.Safari", processIDs: [1]), "Safari")
        checkEqual("无 bundleID 用 pid", AudioControlSupport.displayName(bundleID: nil, processIDs: [42]), "进程 42")
        checkEqual("空 bundleID 当作无", AudioControlSupport.displayName(bundleID: "", processIDs: [7]), "进程 7")

        // MARK: - 是否需要建引擎

        print("\n== 引擎创建判据 ==")

        check("音量 100% 且在出声 → 不需要引擎", !AudioControlSupport.needsEngine(volume: 1.0, isProducing: true))
        check("音量 50% 且在出声 → 需要引擎", AudioControlSupport.needsEngine(volume: 0.5, isProducing: true))
        check("音量 50% 但不在出声 → 不需要引擎", !AudioControlSupport.needsEngine(volume: 0.5, isProducing: false))
        check("音量 0% 且在出声 → 需要引擎（静音）", AudioControlSupport.needsEngine(volume: 0.0, isProducing: true))

        // MARK: - 存储键

        print("\n== 存储键 ==")

        let app = AudioControlledApp(
            id: "com.apple.Safari",
            displayName: "Safari",
            bundleID: "com.apple.Safari",
            processIDs: [100, 101],
            audioObjectIDs: [1, 2],
            isProducingAudio: true,
            volume: 1.0
        )
        checkEqual("存储键带 bundleID", AudioControlSupport.volumeKey(for: app), "volume:com.apple.Safari")
        checkEqual("存储键与 uniqueKey 一致", app.uniqueKey, "com.apple.Safari")

        // 不同 app 的存储键不能撞
        let app2 = AudioControlledApp(
            id: "com.apple.Music",
            displayName: "Music",
            bundleID: "com.apple.Music",
            processIDs: [200],
            audioObjectIDs: [3],
            isProducingAudio: false,
            volume: 1.0
        )
        check("不同 app 的存储键不同", AudioControlSupport.volumeKey(for: app) != AudioControlSupport.volumeKey(for: app2))

        // MARK: - 持久化往返

        print("\n== 持久化往返 ==")

        let suiteName = "com.skyc8266.deepsleep.tests.audio-control"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(0.42, forKey: AudioControlSupport.volumeKey(for: app))
            let readBack = AudioControlSupport.storedVolume(for: app, defaults: defaults)
            checkEqual("存进去的音量能读回来", readBack, 0.42)

            // 没存过的 app 读到 unity（1.0），不是 0
            let missing = AudioControlSupport.storedVolume(for: app2, defaults: defaults)
            checkEqual("没存过的 app 读到 unity 而不是 0", missing, 1.0)

            // 显式存 0 也要能读回 0（静音是有意义的设置）
            defaults.set(0.0, forKey: AudioControlSupport.volumeKey(for: app2))
            checkEqual("显式存的 0 能读回 0", AudioControlSupport.storedVolume(for: app2, defaults: defaults), 0.0)

            defaults.removePersistentDomain(forName: suiteName)
        } else {
            check("能建测试用的 UserDefaults suite", false)
        }

        // MARK: - 结论

        print("\n====================================================")
        print("测试结论: \(checks - failures) 项通过，\(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
