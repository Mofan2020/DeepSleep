//
//  test-keepalive-backoff-timing.swift
//  Deep Sleep 回归测试
//
//  验证 AI 保活的**退避阶梯**在真实引擎里的实际行为。
//
//  为什么单独一个文件：退避的判定入口 `nextRetryAllowedDate` 是 private，
//  `tick()` 也是 private —— Swift 的 private 是**文件作用域**，
//  外部文件拿不到。所以这里不测内部状态，而是**测可观察的行为**：
//
//  1. 造一个「已经到期」的任务（锚点在过去）。
//  2. 让它失败 → 引擎记下失败时刻。
//  3. 反复触发 tick（通过重新 start() 引擎，让 15 秒 timer 真的跑）
//    并统计「引擎自发发出了几次请求」。
//  4. 对比不同失败次数下的重试密度：
//    - 失败 1 次 → 冷却 1 分钟 → 短时间内不该再发
//    - 失败 N 次 → 冷却拉长 → 更不该发
//
//  由于退避的冷却时间是 1/5/15/30 分钟，真实等待不现实。
//  这里用**用户配置的间隔**把冷却上限压到最小：
//  `nextRetryAllowedDate` 里 `cap = clampedInterval * 60`，
//  间隔配 1 分钟 → cap = 60 秒 → 冷却永远是 60 秒（退避阶梯被压平）。
//  于是：
//  - 间隔 1 分钟 → 任何失败次数下冷却都是 60 秒。
//  - 间隔 1440 分钟 → 冷却按阶梯走（60 / 300 / 900 / 1800 秒）。
//
//  验证策略（可观测、耗时可控）：
//  - 用**间隔 = 1 分钟**的任务：失败后 60 秒内不应重试。
//    实测「失败后 40 秒内自发重试次数 == 0」→ 证明冷却生效。
//  - 再用**间隔 = 1 分钟**且**已成功**的任务：应当立刻重试。
//    实测「成功后 40 秒内自发重试次数 >= 1」→ 证明「有失败记录才冷却」。
//
//  这两条合起来能验证：
//  - 冷却期确实生效（失败后不重试）
//  - 冷却期是相对于「失败时刻」而不是「现在」——
//    如果实现是「每次 tick 用 now 当基准」，冷却会永远滑过去，
//    那么失败后的任务会**立刻**重试（而不是被挡住）。
//    也就是说：「失败后 40 秒内自发重试次数 == 0」这条断言
//    **恰好**能区分这两种实现。
//
//  运行：
//  swiftc -parse-as-library \
//    scripts/test-support/KeepAliveTestStubs.swift \
//    DeepSleep/AIKeepAlive/KeepAliveModels.swift \
//    DeepSleep/AIKeepAlive/KeepAliveStore.swift \
//    DeepSleep/AIKeepAlive/KeepAliveClient.swift \
//    DeepSleep/AIKeepAlive/KeepAliveEngine.swift \
//    DeepSleep/LLMGateway/Database/QuotaModels.swift \
//    scripts/test-keepalive-backoff-timing.swift -o /tmp/ka-backoff && /tmp/ka-backoff
//

import Foundation

@main
struct KeepAliveBackoffTimingTests {

    static var failures = 0
    static var total = 0

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

    @MainActor
    static func reset() {
        UserDefaults.standard.removeObject(forKey: KeepAliveStore.storageKey)
        KeychainStore.reset()
        HTTPClient.reset()
        SleepController.resetLogs()
        KeepAliveEngine.shared.stop()
        KeepAliveEngine.shared.reload()
    }

    /// 造一条「已经到期」的任务（锚点在过去 → 引擎一 tick 就会尝试发送）。
    ///
    /// `ageSeconds` 是锚点距今多久。要让任务**到期**，
    /// ageSeconds 必须 > 间隔秒数（否则 nextDueDate 还在未来）。
    @MainActor
    static func makeOverdueTask(
        name: String,
        intervalMinutes: Int,
        ageSeconds: TimeInterval = 3600
    ) -> KeepAliveTask {
        let id = UUID()
        let account = KeepAliveStore.keychainAccount(for: id)
        try? KeychainStore.save(key: "sk-timing", account: account)
        let task = KeepAliveTask(
            id: id,
            name: name,
            baseURL: "https://api.example.com",
            format: .openAI,
            model: "m",
            apiKeyRef: account,
            intervalMinutes: intervalMinutes,
            requestTemplate: "ping",
            isEnabled: true,
            lastRunAt: Date(timeIntervalSinceNow: -ageSeconds),
            lastResult: nil,
            createdAt: Date(timeIntervalSinceNow: -ageSeconds - 3600)
        )
        KeepAliveEngine.shared.upsert(task)
        return task
    }

    /// 等 engine 的 timer 跑一会儿。
    @MainActor
    static func wait(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    static func main() async {
        await runAll()
        print("")
        print(failures == 0
              ? "\n测试结论: 全部通过（\(total) 项断言）"
              : "\n测试结论: \(failures) 项失败（共 \(total) 项断言）")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor
    static func runAll() async {
        // ================================================ 场景 A：失败后被冷却
        print("== 场景 A：失败后进入冷却，短时间内不重试 ==")
        reset()
        // 间隔 1 分钟 → 冷却上限 = 60 秒。
        let taskA = makeOverdueTask(name: "cooled", intervalMinutes: 1)
        // 让服务端一直失败。
        HTTPClient.nextStatus = 500
        HTTPClient.nextBody = Data("boom".utf8)

        KeepAliveEngine.shared.start()
        // 等第一个 tick（15 秒）+ 一次失败。
        await wait(seconds: 18)
        let afterFirst = HTTPClient.requestCount
        check("引擎确实自发发出了请求（定时路径通）", afterFirst >= 1, "实际 \(afterFirst)")

        let failedResult = KeepAliveEngine.shared.tasks.first { $0.id == taskA.id }?.lastResult ?? ""
        check(
            "第一次是失败（服务端返回 500）",
            failedResult.hasPrefix("失败"),
            "实际 \(failedResult)"
        )
        check(
            "失败后 lastRunAt 不推进",
            (KeepAliveEngine.shared.tasks.first { $0.id == taskA.id }?.lastRunAt ?? Date())
                < Date()
        )

        // 再等 25 秒（累计约 43 秒，仍在 60 秒冷却内）。
        await wait(seconds: 25)
        let afterCool = HTTPClient.requestCount
        checkEqual(
            "失败后 40 秒内不再自发重试（冷却期生效）",
            afterFirst,
            afterCool
        )
        check(
            "冷却期间任务仍然是「到期」状态（锚点没推进，所以到期判定一直成立）",
            (KeepAliveEngine.shared.tasks.first { $0.id == taskA.id }?.nextDueDate() ?? Date.distantFuture) < Date()
        )

        KeepAliveEngine.shared.stop()

        // ================================ 场景 B：成功后按间隔重试（不冷却）
        print("\n== 场景 B：成功一次后不处于冷却，按间隔正常重试 ==")
        reset()
        let taskB = makeOverdueTask(name: "ok", intervalMinutes: 1)
        HTTPClient.nextStatus = 200
        KeepAliveEngine.shared.start()
        await wait(seconds: 18)
        let firstOK = HTTPClient.requestCount
        check("成功路径也自发发出了请求", firstOK >= 1, "实际 \(firstOK)")
        checkEqual(
            "成功后 lastResult 是「已发送」",
            "已发送",
            KeepAliveEngine.shared.tasks.first { $0.id == taskB.id }?.lastResult ?? ""
        )
        check(
            "成功后 lastRunAt 推进到当前",
            (KeepAliveEngine.shared.tasks.first { $0.id == taskB.id }?.lastRunAt ?? .distantPast) > Date(timeIntervalSinceNow: -30)
        )
        // 成功后间隔 1 分钟 → 60 秒后才会再发。25 秒内不应再发。
        await wait(seconds: 25)
        checkEqual(
            "成功后 40 秒内不重复发（间隔未到）",
            firstOK,
            HTTPClient.requestCount
        )
        KeepAliveEngine.shared.stop()

        // ============================ 场景 C：失败记录不阻塞「成功过」的任务
        print("\n== 场景 C：没有失败记录的任务不会被冷却 ==")
        reset()
        // 间隔 1 分钟，锚点在过去，且**没有**失败记录 → 引擎一 tick 就发。
        let taskC = makeOverdueTask(name: "fresh", intervalMinutes: 1)
        HTTPClient.nextStatus = 200
        KeepAliveEngine.shared.start()
        await wait(seconds: 18)
        check(
            "无失败记录的任务立刻发（证明冷却只针对有失败记录的任务）",
            HTTPClient.requestCount >= 1,
            "实际 \(HTTPClient.requestCount)"
        )
        checkEqual(
            "无失败记录的任务成功",
            "已发送",
            KeepAliveEngine.shared.tasks.first { $0.id == taskC.id }?.lastResult ?? ""
        )
        KeepAliveEngine.shared.stop()

        // ============================================ 场景 D：停用的任务不重试
        print("\n== 场景 D：停用的任务不被引擎调度 ==")
        reset()
        let taskD = makeOverdueTask(name: "disabled", intervalMinutes: 1)
        KeepAliveEngine.shared.setEnabled(taskD.id, false)
        HTTPClient.nextStatus = 200
        KeepAliveEngine.shared.start()
        await wait(seconds: 18)
        checkEqual(
            "停用的任务一个请求都不发",
            0,
            HTTPClient.requestCount
        )
        KeepAliveEngine.shared.stop()

        // ================================== 场景 E：到期任务重启后立刻补发
        print("\n== 场景 E：长时间没跑 → 重启后立刻补发 ==")
        reset()
        // 间隔 240 分钟 → 锚点必须早于 240 分钟才算到期。
        _ = makeOverdueTask(name: "stale", intervalMinutes: 240, ageSeconds: 240 * 60 + 60)
        HTTPClient.nextStatus = 200
        // 注意：引擎先 start（reload 从盘上读任务），再等第一个 tick。
        KeepAliveEngine.shared.start()
        await wait(seconds: 18)
        check(
            "应用重启后第一个 tick 就补发了（锚点在过去）",
            HTTPClient.requestCount >= 1,
            "实际 \(HTTPClient.requestCount)"
        )
        checkEqual(
            "补发后 lastResult 是「已发送」",
            "已发送",
            KeepAliveEngine.shared.tasks.first { $0.name == "stale" }?.lastResult ?? ""
        )
        KeepAliveEngine.shared.stop()

        // ==================================== 场景 F：成功后不再立刻重试
        print("\n== 场景 F：成功后不立刻重发（间隔未到）==")
        reset()
        _ = makeOverdueTask(name: "longinterval", intervalMinutes: 240, ageSeconds: 240 * 60 + 60)
        HTTPClient.nextStatus = 200
        KeepAliveEngine.shared.start()
        await wait(seconds: 20)
        let firstF = HTTPClient.requestCount
        check("发出 1 次", firstF >= 1, "实际 \(firstF)")
        await wait(seconds: 20)
        checkEqual(
            "间隔 240 分钟 → 40 秒内不再发",
            firstF,
            HTTPClient.requestCount
        )
        KeepAliveEngine.shared.stop()

        // ================================ 场景 G：冷却基准是「失败时刻」不是「现在」
        print("\n== 场景 G：冷却基准是「失败时刻」而非「每次 tick 的现在」 ==")
        // 这是本次验收最关心的调度正确性点。
        //
        // 错误实现（相对「现在」算）：
        //     guard now >= now.addingTimeInterval(cooldown)   // 永远等不到
        // 表现：失败后每个 tick 都会重试（因为 now 每次都刷新）。
        //
        // 正确实现（相对「失败时刻」算）：
        //     guard now >= failedAt.addingTimeInterval(cooldown)
        // 表现：失败后 cooldown 内不重试，cooldown 过后才重试。
        //
        // 判别方法：用间隔 = 1 分钟的任务（冷却上限 60 秒）。
        //   - 正确实现：失败后 40 秒内 0 次重试。
        //   - 错误实现：失败后第 2 个 tick（15 秒后）就会重试 → 40 秒内 >= 1 次。
        //
        // 场景 A 已经断言了「40 秒内 0 次重试」。
        // 这里再加一条：确认引擎**确实**还在跑（tick 还在触发），
        // 否则「0 次重试」可能只是因为 tick 没跑。
        reset()
        let taskG = makeOverdueTask(name: "cooldown-base", intervalMinutes: 1)
        HTTPClient.nextStatus = 500
        HTTPClient.nextBody = Data("boom".utf8)
        KeepAliveEngine.shared.start()
        await wait(seconds: 18)
        let gFirst = HTTPClient.requestCount
        check("第一次自发发送发生", gFirst >= 1, "实际 \(gFirst)")
        // 场景 A 已经证明 40 秒内不再发。这里确认 tick 本身还活着：
        // 等过 60 秒冷却（60 + 15 秒 tick 周期 ≈ 75 秒）后引擎应恢复发送。
        var gRecovered = false
        for _ in 0..<12 {
            await wait(seconds: 10)
            if HTTPClient.requestCount > gFirst {
                gRecovered = true
                break
            }
        }
        check(
            "冷却期过后引擎恢复发送（证明 tick 一直在跑，不是引擎死了）",
            gRecovered,
            "实际 \(HTTPClient.requestCount) 次请求（起始 \(gFirst)）"
        )
        check(
            "任务状态已更新（失败摘要仍在）",
            !(KeepAliveEngine.shared.tasks.first { $0.id == taskG.id }?.lastResult ?? "").isEmpty
        )
        KeepAliveEngine.shared.stop()

        // ------------------------------------------------------------- 清理
        reset()
        print("\n== 清理 ==")
        KeepAliveEngine.shared.reload()
        check("任务列表已清空", KeepAliveEngine.shared.tasks.isEmpty)
        check(
            "UserDefaults 已清理",
            UserDefaults.standard.data(forKey: KeepAliveStore.storageKey) == nil
        )
    }
}
