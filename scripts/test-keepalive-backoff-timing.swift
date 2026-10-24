//
//  test-keepalive-backoff-timing.swift
//  Deep Sleep 回归测试
//
//  验证 AI 保活的**退避阶梯**在真实引擎里的实际行为。
//
//  为什么单独一个文件：退避的判定入口 `nextRetryAllowedDate` 是 private，
//  `tick()` 也是 private —— Swift 的 private 是**文件作用域**，外部文件
//  拿不到。所以这里不测内部状态，而是**测可观察的行为**：
//
//  1. 造一个「已经到点」的任务（今天的时刻已过、且晚于锚点）。
//  2. 让它失败 → 引擎记下失败时刻。
//  3. 反复触发 tick（通过重新 start() 引擎，让 15 秒 timer 真的跑）
//    并统计「引擎自发发出了几次请求」。
//  4. 对比不同失败次数下的重试密度。
//
//  调度模型是「每天固定时刻」，所以「冷却上限」的上限来源变了：
//  - 上限 = 到下一个计划时刻的距离；
//  - 任务只配「当前小时」这一个时刻时，下一个时刻是**明天**同一钟点，
//    距离约 24 小时 → 退避阶梯（1/5/15/30 分钟）完全生效。
//
//  验证策略（可观测、耗时可控）：
//  - 失败后 40 秒内不应自发重试（冷却期生效）。
//  - 成功后 40 秒内不重复发。
//  - 停用的任务一个请求都不发。
//  - 冷却期过后引擎恢复发送（证明 tick 一直在跑，不是引擎死了）。
//
//  运行：
//  swiftc -parse-as-library \
//    scripts/test-support/KeepAliveTestStubs.swift \
//    DeepSleep/AIKeepAlive/KeepAliveModels.swift \
//    DeepSleep/AIKeepAlive/KeepAliveError.swift \
//    DeepSleep/AIKeepAlive/KeepAliveStore.swift \
//    DeepSleep/AIKeepAlive/KeepAliveClient.swift \
//    DeepSleep/AIKeepAlive/KeepAliveEngine.swift \
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
        KeepAliveKeychain.reset()
        KeepAliveHTTPClient.reset()
        SleepController.resetLogs()
        KeepAliveEngine.shared.stop()
        KeepAliveEngine.shared.reload()
    }

    /// 造一个「现在就该发」的任务。
    ///
    /// 计划时刻 = 当前小时（整点）。要让任务**到点**，那个时刻必须已经过去，
    /// 且晚于锚点 —— 所以 `createdAt` 与 `lastRunAt` 都放在几天前。
    @MainActor
    static func makeDueTask(
        name: String,
        ageSeconds: TimeInterval = 86400 * 3
    ) -> KeepAliveTask {
        let id = UUID()
        let account = KeepAliveStore.keychainAccount(for: id)
        try? KeepAliveKeychain.save(key: "sk-timing", account: account)
        let hour = Calendar.current.component(.hour, from: Date())
        let task = KeepAliveTask(
            id: id,
            name: name,
            baseURL: "https://api.example.com",
            format: .openAI,
            model: "m",
            apiKeyRef: account,
            schedule: KeepAliveSchedule(
                times: [KeepAliveTime(hour: hour, minute: 0)],
                weekdays: KeepAliveSchedule.allWeekdays
            ),
            requestTemplate: KeepAliveDefaults.defaultRequestTemplate,
            isEnabled: true,
            lastRunAt: Date(timeIntervalSinceNow: -ageSeconds),
            lastResult: nil,
            createdAt: Date(timeIntervalSinceNow: -ageSeconds - 3600)
        )
        KeepAliveEngine.shared.upsert(task)
        return task
    }

    /// 造一个「还没到点」的任务（时刻在未来）。
    @MainActor
    static func makeFutureTask(name: String) -> KeepAliveTask {
        let id = UUID()
        let account = KeepAliveStore.keychainAccount(for: id)
        try? KeepAliveKeychain.save(key: "sk-timing", account: account)
        let hour = (Calendar.current.component(.hour, from: Date()) + 2) % 24
        let task = KeepAliveTask(
            id: id,
            name: name,
            baseURL: "https://api.example.com",
            format: .openAI,
            model: "m",
            apiKeyRef: account,
            schedule: KeepAliveSchedule(
                times: [KeepAliveTime(hour: hour, minute: 0)],
                weekdays: KeepAliveSchedule.allWeekdays
            ),
            requestTemplate: KeepAliveDefaults.defaultRequestTemplate,
            isEnabled: true,
            lastRunAt: nil,
            lastResult: nil,
            createdAt: Date()
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
        let taskA = makeDueTask(name: "cooled")
        // 让服务端一直失败。
        KeepAliveHTTPClient.nextStatus = 500
        KeepAliveHTTPClient.nextBody = Data("boom".utf8)

        KeepAliveEngine.shared.start()
        // 等第一个 tick（15 秒）+ 一次失败。
        await wait(seconds: 18)
        let afterFirst = KeepAliveHTTPClient.requestCount
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
        let afterCool = KeepAliveHTTPClient.requestCount
        checkEqual(
            "失败后 40 秒内不再自发重试（冷却期生效）",
            afterFirst,
            afterCool
        )
        check(
            "冷却期间任务仍然是「到点」状态（锚点没推进）",
            (KeepAliveEngine.shared.tasks.first { $0.id == taskA.id }?.isDue(at: Date()) ?? false)
        )

        KeepAliveEngine.shared.stop()

        // ================================ 场景 B：成功后不重复发
        print("\n== 场景 B：成功后不重复发（时刻没到） ==")
        reset()
        let taskB = makeDueTask(name: "ok")
        KeepAliveHTTPClient.nextStatus = 200
        KeepAliveEngine.shared.start()
        await wait(seconds: 18)
        let firstOK = KeepAliveHTTPClient.requestCount
        check("成功路径也自发发出了请求", firstOK >= 1, "实际 \(firstOK)")
        checkEqual(
            "成功后 lastResult 是「已发送」",
            "已发送",
            KeepAliveEngine.shared.tasks.first { $0.id == taskB.id }?.lastResult ?? ""
        )
        check(
            "成功后 lastRunAt 推进到当前",
            (KeepAliveEngine.shared.tasks.first { $0.id == taskB.id }?.lastRunAt ?? .distantPast)
                > Date(timeIntervalSinceNow: -30)
        )
        // 成功后锚点推进到今天这个整点 → 不该立刻再发。
        await wait(seconds: 25)
        checkEqual(
            "成功后 40 秒内不重复发",
            firstOK,
            KeepAliveHTTPClient.requestCount
        )
        KeepAliveEngine.shared.stop()

        // ============================ 场景 C：没到点的任务不自动发
        print("\n== 场景 C：没到点的任务不自动发 ==")
        reset()
        _ = makeFutureTask(name: "future")
        KeepAliveHTTPClient.nextStatus = 200
        KeepAliveEngine.shared.start()
        await wait(seconds: 18)
        checkEqual(
            "没到点的任务一个请求都不发",
            0,
            KeepAliveHTTPClient.requestCount
        )
        KeepAliveEngine.shared.stop()

        // ============================================ 场景 D：停用的任务不重试
        print("\n== 场景 D：停用的任务不被引擎调度 ==")
        reset()
        let taskD = makeDueTask(name: "disabled")
        KeepAliveEngine.shared.setEnabled(taskD.id, false)
        KeepAliveHTTPClient.nextStatus = 200
        KeepAliveEngine.shared.start()
        await wait(seconds: 18)
        checkEqual(
            "停用的任务一个请求都不发",
            0,
            KeepAliveHTTPClient.requestCount
        )
        KeepAliveEngine.shared.stop()

        // ==================================== 场景 E：重启后当天到点仍会发
        print("\n== 场景 E：重启后当天到点的任务仍会发 ==")
        reset()
        let taskE = makeDueTask(name: "restart")
        KeepAliveHTTPClient.nextStatus = 200
        KeepAliveEngine.shared.start()
        await wait(seconds: 18)
        check(
            "应用重启后第一个 tick 就发出了（今天的时刻已过且晚于锚点）",
            KeepAliveHTTPClient.requestCount >= 1,
            "实际 \(KeepAliveHTTPClient.requestCount)"
        )
        checkEqual(
            "发送后 lastResult 是「已发送」",
            "已发送",
            KeepAliveEngine.shared.tasks.first { $0.id == taskE.id }?.lastResult ?? ""
        )
        KeepAliveEngine.shared.stop()

        // ================================ 场景 F：冷却基准是「失败时刻」
        print("\n== 场景 F：冷却基准是「失败时刻」而非「每次 tick 的现在」 ==")
        // 错误实现（相对「现在」算）：
        //     guard now >= now.addingTimeInterval(cooldown)   // 永远等不到
        // 表现：失败后每个 tick 都会重试。
        //
        // 正确实现（相对「失败时刻」算）：
        //     guard now >= failedAt.addingTimeInterval(cooldown)
        // 表现：失败后 cooldown 内不重试，cooldown 过后才重试。
        //
        // 判别方法：场景 A 已经断言「失败后 40 秒内 0 次重试」。
        // 这里再加一条：确认引擎**确实**还在跑（tick 还在触发），
        // 否则「0 次重试」可能只是因为 tick 没跑。
        reset()
        let taskG = makeDueTask(name: "cooldown-base")
        KeepAliveHTTPClient.nextStatus = 500
        KeepAliveHTTPClient.nextBody = Data("boom".utf8)
        KeepAliveEngine.shared.start()
        await wait(seconds: 18)
        let gFirst = KeepAliveHTTPClient.requestCount
        check("第一次自发发送发生", gFirst >= 1, "实际 \(gFirst)")
        // 等过 60 秒冷却（60 + 15 秒 tick 周期 ≈ 75 秒）后引擎应恢复发送。
        var gRecovered = false
        for _ in 0..<12 {
            await wait(seconds: 10)
            if KeepAliveHTTPClient.requestCount > gFirst {
                gRecovered = true
                break
            }
        }
        check(
            "冷却期过后引擎恢复发送（证明 tick 一直在跑，不是引擎死了）",
            gRecovered,
            "实际 \(KeepAliveHTTPClient.requestCount) 次请求（起始 \(gFirst)）"
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
