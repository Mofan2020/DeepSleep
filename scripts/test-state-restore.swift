//
//  test-state-restore.swift
//  DeepSleep
//
//  跨重启状态恢复的自测：存档编解码 + 恢复判据 + 服务器模式的倒计时口径。
//
//  为什么必须有这层：这三样东西在真机上「失败」的样子都很温和 ——
//  设置没回来、第一次关屏来得太早或太晚，都不会报错，只会让人觉得
//  应用不可靠。而它们全是可以离线判定的纯逻辑，没理由留到真机上试。
//
//  运行：
//    bash scripts/run-all-tests.sh
//  或者单独：
//    DEEPSLEEP_RUNSTATE_SUITE=com.skyc8266.deepsleep.tests.runstate \
//    swiftc -parse-as-library DeepSleep/Core/RunState.swift \
//            DeepSleep/Core/ServerModeIdleWindow.swift \
//            scripts/test-state-restore.swift -o /tmp/t_state && /tmp/t_state
//

import Foundation

@main
struct StateRestoreTests {

    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            print("  [通过] \(name)")
        } else {
            print("  [失败] \(name)" + (detail.isEmpty ? "" : " —— \(detail)"))
            failures += 1
        }
    }

    static func checkEqual<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        check(name, actual == expected, "期望 \(expected)，实际 \(actual)")
    }

    // MARK: - 固定测试数据

    /// 认识的保持类型（与 AssertionKind 的 rawValue 一致）。
    static let known: Set<String> = [
        "preventIdleSystemSleep", "preventIdleDisplaySleep",
        "preventSystemSleep", "preventDiskIdle",
    ]
    static let privileged: Set<String> = ["preventSystemSleep"]

    static func environment(helper: Bool = true,
                            disclaimer: Bool = true,
                            needsAccessibility: Bool = false,
                            accessibility: Bool = true) -> RestoreEnvironment {
        RestoreEnvironment(
            helperReady: helper,
            disclaimerAccepted: disclaimer,
            serverModeNeedsAccessibility: needsAccessibility,
            accessibilityAuthorized: accessibility,
            knownAssertions: known,
            privilegedAssertions: privileged
        )
    }

    /// 从一组恢复项里找某一项的动作。
    static func action(_ entries: [RestoreEntry], _ item: RestoreItem) -> RestoreAction? {
        entries.first { $0.item == item }?.action
    }

    static func main() {
        testEncodingRoundTrip()
        testMissingKeysFallBackToDefaults()
        testUnknownAssertionIsDropped()
        testCorruptArchiveLoadsAsNil()
        testEmptyStateIsNotPersisted()
        testStoreRoundTrip()

        testRestoreAssertions()
        testRestoreHoldDeadline()
        testRestoreSleepDisabled()
        testRestoreServerMode()
        testRestoreFanControl()
        testAudioVolumeRestore()

        testIdleWindow()

        print("")
        if failures == 0 {
            print("测试结论: 全部通过")
        } else {
            print("测试结论: \(failures) 项失败")
            exit(1)
        }
    }

    // MARK: - 编解码

    static func testEncodingRoundTrip() {
        print("—— 存档编解码 ——")

        var state = RunState()
        state.fanControlEnabled = true
        state.manualAssertions = ["preventIdleSystemSleep", "preventDisplaySleep"]
        state.sleepDisabled = true
        state.holdUntil = Date(timeIntervalSince1970: 1_800_000_000)
        state.serverModeEnabled = true

        guard let data = try? JSONEncoder().encode(state),
              let decoded = try? JSONDecoder().decode(RunState.self, from: data) else {
            check("编解码往返", false, "编码或解码失败")
            return
        }
        checkEqual("编解码往返后完全一致", decoded, state)
    }

    static func testMissingKeysFallBackToDefaults() {
        print("")
        print("—— 老存档少字段 ——")

        // 只写了 fanControlEnabled 的「老版本」存档。
        let json = #"{"fanControlEnabled":true}"#
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RunState.self, from: data) else {
            check("缺字段的存档能读", false, "解码失败")
            return
        }
        checkEqual("缺的字段用默认值补上（风扇开关保留）", decoded.fanControlEnabled, true)
        checkEqual("缺 manualAssertions → 空", decoded.manualAssertions, [])
        checkEqual("缺 sleepDisabled → false", decoded.sleepDisabled, false)
        checkEqual("缺 holdUntil → nil", decoded.holdUntil, nil)
        checkEqual("缺 serverModeEnabled → false", decoded.serverModeEnabled, false)
    }

    static func testUnknownAssertionIsDropped() {
        print("")
        print("—— 不认识的保持类型 ——")

        var state = RunState()
        state.manualAssertions = ["preventIdleSystemSleep", "futureKindFromNewerVersion"]
        state.fanControlEnabled = true

        let pruned = state.retainingKnownAssertions(known)
        checkEqual("未知类型被丢掉", pruned.manualAssertions, ["preventIdleSystemSleep"])
        checkEqual("其余字段不受影响", pruned.fanControlEnabled, true)
    }

    static func testCorruptArchiveLoadsAsNil() {
        print("")
        print("—— 存档损坏 ——")

        let storage = RunStateStore.storage
        storage.set(Data("not json".utf8), forKey: RunStateStore.storageKey)
        checkEqual("内容损坏时读回 nil（而不是崩）", RunStateStore.load() == nil, true)
        storage.removeObject(forKey: RunStateStore.storageKey)
    }

    static func testEmptyStateIsNotPersisted() {
        print("")
        print("—— 默认值不落盘 ——")

        RunStateStore.clear()
        let fresh = RunState()
        checkEqual("默认状态被判为空", fresh.isEmpty, true)
        RunStateStore.save(fresh)
        checkEqual("空状态不写盘", RunStateStore.storage.object(forKey: RunStateStore.storageKey) == nil, true)

        var one = RunState()
        one.fanControlEnabled = true
        RunStateStore.save(one)
        checkEqual("非空状态写盘", RunStateStore.load(), one)
        RunStateStore.clear()
    }

    static func testStoreRoundTrip() {
        print("")
        print("—— 读-改-写 ——")

        RunStateStore.clear()
        RunStateStore.update { $0.fanControlEnabled = true }
        RunStateStore.update { $0.serverModeEnabled = true }
        let merged = RunStateStore.load()
        checkEqual("两次 update 不互相覆盖（风扇）", merged?.fanControlEnabled, true)
        checkEqual("两次 update 不互相覆盖（服务器模式）", merged?.serverModeEnabled, true)

        RunStateStore.clear()
        checkEqual("clear 之后读回 nil", RunStateStore.load() == nil, true)
    }

    // MARK: - 恢复判据：保持

    static func testRestoreAssertions() {
        print("")
        print("—— 恢复判据：手动保持 ——")

        var state = RunState()
        state.manualAssertions = ["preventIdleSystemSleep", "preventIdleDisplaySleep"]
        var entries = state.restoreEntries(environment: environment(), now: Date())
        checkEqual("本地断言可直接恢复（第一条）",
                   action(entries, .assertion("preventIdleSystemSleep")), .restore)
        checkEqual("本地断言可直接恢复（第二条）",
                   action(entries, .assertion("preventIdleDisplaySleep")), .restore)

        state.manualAssertions = ["preventSystemSleep"]
        entries = state.restoreEntries(environment: environment(), now: Date())
        checkEqual("助手就绪时特权断言可恢复",
                   action(entries, .assertion("preventSystemSleep")), .restore)

        entries = state.restoreEntries(environment: environment(helper: false), now: Date())
        checkEqual("助手没就绪时特权断言跳过",
                   action(entries, .assertion("preventSystemSleep")), .skip(.helperUnavailable))

        state.manualAssertions = ["preventIdleSystemSleep"]
        entries = state.restoreEntries(environment: environment(helper: false), now: Date())
        checkEqual("助手没就绪也不影响本地断言",
                   action(entries, .assertion("preventIdleSystemSleep")), .restore)

        // 不认识的类型：即使助手就绪也只能跳过。
        state.manualAssertions = ["somethingNew"]
        entries = state.restoreEntries(environment: environment(), now: Date())
        checkEqual("不认识的类型跳过",
                   action(entries, .assertion("somethingNew")), .skip(.unknownType))
    }

    // MARK: - 恢复判据：定时保持

    static func testRestoreHoldDeadline() {
        print("")
        print("—— 恢复判据：定时保持 ——")

        let now = Date()
        var state = RunState()
        state.manualAssertions = ["preventIdleSystemSleep"]
        state.holdUntil = now.addingTimeInterval(600)

        var entries = state.restoreEntries(environment: environment(), now: now)
        checkEqual("未到期：恢复定时", action(entries, .holdDeadline), .restore)
        checkEqual("未到期：断言照常恢复",
                   action(entries, .assertion("preventIdleSystemSleep")), .restore)

        state.holdUntil = now.addingTimeInterval(-600)
        entries = state.restoreEntries(environment: environment(), now: now)
        checkEqual("已到期：定时跳过", action(entries, .holdDeadline), .skip(.holdExpired))
        checkEqual("已到期：那批断言不再恢复（本该早就释放了）",
                   action(entries, .assertion("preventIdleSystemSleep")), .skip(.holdExpired))

        // 正好到点按到期处理 —— 不留一个「刚好卡在边界上」的歧义。
        state.holdUntil = now
        entries = state.restoreEntries(environment: environment(), now: now)
        checkEqual("正好到点算到期", action(entries, .holdDeadline), .skip(.holdExpired))

        state.holdUntil = nil
        entries = state.restoreEntries(environment: environment(), now: now)
        checkEqual("没有定时就不产生定时项", action(entries, .holdDeadline), nil)
    }

    // MARK: - 恢复判据：完全禁止系统睡眠

    static func testRestoreSleepDisabled() {
        print("")
        print("—— 恢复判据：完全禁止系统睡眠 ——")

        var state = RunState()
        state.sleepDisabled = true

        checkEqual("助手就绪 → 恢复",
                   action(state.restoreEntries(environment: environment(), now: Date()),
                          .sleepDisabled), .restore)
        checkEqual("助手没就绪 → 跳过",
                   action(state.restoreEntries(environment: environment(helper: false), now: Date()),
                          .sleepDisabled), .skip(.helperUnavailable))

        let off = RunState()
        checkEqual("没开就不产生这一项",
                   action(off.restoreEntries(environment: environment(), now: Date()),
                          .sleepDisabled), nil)
    }

    // MARK: - 恢复判据：服务器模式

    static func testRestoreServerMode() {
        print("")
        print("—— 恢复判据：服务器模式 ——")

        var state = RunState()
        state.serverModeEnabled = true

        checkEqual("助手就绪且不需要辅助功能 → 恢复",
                   action(state.restoreEntries(environment: environment(), now: Date()),
                          .serverMode), .restore)

        checkEqual("助手没就绪 → 跳过",
                   action(state.restoreEntries(environment: environment(helper: false), now: Date()),
                          .serverMode), .skip(.helperUnavailable))

        // 事件监听模式没授权：不能悄悄换成内核计时 —— 用户选的是哪个就跑哪个。
        checkEqual("事件监听模式缺辅助功能授权 → 跳过",
                   action(state.restoreEntries(
                            environment: environment(needsAccessibility: true, accessibility: false),
                            now: Date()),
                          .serverMode),
                   .skip(.accessibilityNotAuthorized))

        checkEqual("事件监听模式已授权 → 恢复",
                   action(state.restoreEntries(
                            environment: environment(needsAccessibility: true, accessibility: true),
                            now: Date()),
                          .serverMode),
                   .restore)
    }

    // MARK: - 恢复判据：风扇控制

    static func testRestoreFanControl() {
        print("")
        print("—— 恢复判据：风扇控制 ——")

        var state = RunState()
        state.fanControlEnabled = true

        checkEqual("免责声明已同意 + 助手就绪 → 恢复",
                   action(state.restoreEntries(environment: environment(), now: Date()),
                          .fanControl), .restore)

        checkEqual("没同意免责声明 → 跳过（不能替用户同意）",
                   action(state.restoreEntries(environment: environment(disclaimer: false),
                                               now: Date()),
                          .fanControl), .skip(.disclaimerNotAccepted))

        checkEqual("助手没就绪 → 跳过",
                   action(state.restoreEntries(environment: environment(helper: false), now: Date()),
                          .fanControl), .skip(.helperUnavailable))
    }

    // MARK: - 恢复判据：逐应用音量

    static func testAudioVolumeRestore() {
        print("")
        print("—— 恢复判据：逐应用音量 ——")

        let stored = [
            AudioControlSupport.volumeKeyPrefix + "com.apple.Safari",
            AudioControlSupport.volumeKeyPrefix + "com.apple.Music",
            AudioControlSupport.volumeKeyPrefix + "com.example.NotRunning",
            "enabled",          // 不是音量键，必须被忽略
            AudioControlSupport.volumeKeyPrefix,   // 空前缀，忽略
        ]

        let plan = AudioControlSupport.volumeRestorePlan(
            storedKeys: stored,
            liveKeys: ["com.apple.Safari", "com.apple.Music"]
        )
        checkEqual("正在运行的应用算已恢复",
                   plan.applied, ["com.apple.Music", "com.apple.Safari"])
        checkEqual("没在运行的应用算等它回来",
                   plan.pending, ["com.example.NotRunning"])

        let noneRunning = AudioControlSupport.volumeRestorePlan(storedKeys: stored, liveKeys: [])
        checkEqual("一个都没在运行 → 全部待恢复", noneRunning.applied, [])
        checkEqual("一个都没在运行 → 待恢复三条", noneRunning.pending.count, 3)

        let empty = AudioControlSupport.volumeRestorePlan(storedKeys: ["enabled"], liveKeys: [])
        checkEqual("没有音量存档时两边都空", empty.applied.isEmpty && empty.pending.isEmpty, true)
    }

    // MARK: - 服务器模式的倒计时口径

    static func testIdleWindow() {
        print("")
        print("—— 服务器模式：开启后不立刻关屏 ——")

        let threshold: TimeInterval = 600

        // 机器在开启前已经空闲了 3 小时（远程开启的典型场景）。
        let longIdleBefore: TimeInterval = 3 * 3600
        let atEnable = ServerModeIdleWindow.effectiveIdle(rawIdle: longIdleBefore, sinceEnabled: 0)
        checkEqual("刚开启时有效空闲为 0（不会立刻关屏）", atEnable, 0)
        checkEqual("刚开启时不该到点",
                   ServerModeIdlePolicy.decide(phase: .waitingForIdle,
                                               idle: atEnable,
                                               threshold: threshold) == .sleepNow,
                   false)

        let after5min = ServerModeIdleWindow.effectiveIdle(rawIdle: longIdleBefore + 300,
                                                           sinceEnabled: 300)
        checkEqual("开启 5 分钟后有效空闲 300 秒", after5min, 300)

        let after10min = ServerModeIdleWindow.effectiveIdle(rawIdle: longIdleBefore + 600,
                                                            sinceEnabled: 600)
        checkEqual("开启满阈值后有效空闲等于阈值", after10min, 600)
        checkEqual("到点才关屏",
                   ServerModeIdlePolicy.decide(phase: .waitingForIdle,
                                               idle: after10min,
                                               threshold: threshold),
                   .sleepNow)

        // 用户在开启后一直在用：原始空闲比「开启后经过的时间」小，取原始值。
        let userActive = ServerModeIdleWindow.effectiveIdle(rawIdle: 30, sinceEnabled: 1800)
        checkEqual("用户刚动过 → 按真实的最后操作计时", userActive, 30)

        // 开启很久之后，窗口不再是限制项。
        let longAfter = ServerModeIdleWindow.effectiveIdle(rawIdle: 900, sinceEnabled: 86400)
        checkEqual("开启很久之后取原始空闲", longAfter, 900)

        // 时钟回拨：不能变成负数，否则倒计时会瞬间归零并立刻关屏。
        checkEqual("负的原始空闲按 0 处理",
                   ServerModeIdleWindow.effectiveIdle(rawIdle: -100, sinceEnabled: 600), 0)
        checkEqual("负的开启时长按 0 处理",
                   ServerModeIdleWindow.effectiveIdle(rawIdle: 600, sinceEnabled: -100), 0)
    }
}
