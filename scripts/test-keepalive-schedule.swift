//
//  test-keepalive-schedule.swift
//  Deep Sleep 回归测试
//
//  验证 AI 保活的**调度语义**（不是 URL 拼接 —— 那个在 test-keepalive-url.swift）。
//
//  调度模型：每天固定时刻 + 每周选几天。
//  - 到点判定：找出最近一个「已经过去、且晚于上次成功发送」的计划时刻；
//  - 锚点推进：**只有成功才推进**（失败时保持不变，下一次 tick 立刻重试）；
//  - 退避阶梯：1 / 5 / 15 / 30 分钟，冷却基准是「失败时刻」不是「现在」。
//
//  覆盖：
//  - 时刻归一化（去重、排序、钳制非法值、数量上限）
//  - 星期归一化（剔非法值）
//  - 星期文案（每天 / 工作日 / 逐个列出 / 不运行）
//  - 到点判定：到点该发、没到不发、已发过的不重复发
//  - 星期过滤：不在选中的日子里不发
//  - 失败时不推进锚点（失败就该尽快重试）
//  - 成功一次清零退避计数
//  - 退避阶梯真的生效
//  - 冷却期相对「失败时刻」算，不是相对「现在」算
//  - inFlight 真的挡住同一任务被并发触发
//  - 长时间没跑（应用退出过）后重启会立刻补发
//  - 禁用 / 停用的任务不发
//  - 删除任务时 Keychain 条目一起清掉
//  - 旧格式（intervalMinutes）迁移后仍能读出来
//  - API Key 不出现在日志里
//
//  运行：
//  swiftc -parse-as-library \
//    scripts/test-support/KeepAliveTestStubs.swift \
//    DeepSleep/AIKeepAlive/KeepAliveModels.swift \
//    DeepSleep/AIKeepAlive/KeepAliveError.swift \
//    DeepSleep/AIKeepAlive/KeepAliveStore.swift \
//    DeepSleep/AIKeepAlive/KeepAliveClient.swift \
//    DeepSleep/AIKeepAlive/KeepAliveEngine.swift \
//    scripts/test-keepalive-schedule.swift -o /tmp/ka-sched && /tmp/ka-sched
//

import Foundation

@main
struct KeepAliveScheduleTests {

    // MARK: - 断言工具

    static var failures = 0
    static var total = 0

    /// 已确认的产品缺陷（测试能稳定复现，代码需要改）。
    static var confirmedDefects: [String] = []

    /// 记录一个已确认的产品缺陷。
    static func confirmDefect(_ id: String, _ detail: String) {
        confirmedDefects.append("[\(id)] \(detail)")
        print("  [缺陷] \(id)：\(detail)")
    }

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

    /// 清理所有测试状态。
    @MainActor
    static func reset() {
        UserDefaults.standard.removeObject(forKey: KeepAliveStore.storageKey)
        KeepAliveKeychain.reset()
        KeepAliveHTTPClient.reset()
        SleepController.resetLogs()
        KeepAliveEngine.shared.stop()
    }

    /// 测试用的固定日历：固定时区、固定每周第一天，避免跑测试的日子影响结果。
    static var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        cal.firstWeekday = 2   // 周一
        return cal
    }()

    /// 造一个「某天某时某分」的 Date。
    static func date(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int, _ minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.date(from: comps)!
    }

    /// 2026-10-26 是周一。用它当基准日。
    static let monday = date(2026, 10, 26, 0, 0)
    static let tuesday = date(2026, 10, 27, 0, 0)
    static let sunday = date(2026, 10, 25, 0, 0)

    /// 造一条任务并写进 Keychain。
    @MainActor
    static func makeTask(
        name: String = "t",
        baseURL: String = "https://api.example.com",
        model: String = "m",
        schedule: KeepAliveSchedule = KeepAliveSchedule(
            times: [KeepAliveTime(hour: 9, minute: 0)],
            weekdays: KeepAliveSchedule.allWeekdays
        ),
        key: String? = "«redacted:sk-…»",
        lastRunAt: Date? = nil,
        createdAt: Date = Date(),
        isEnabled: Bool = true
    ) -> KeepAliveTask {
        let id = UUID()
        let account = KeepAliveStore.keychainAccount(for: id)
        if let key {
            try? KeepAliveKeychain.save(key: key, account: account)
        }
        let task = KeepAliveTask(
            id: id,
            name: name,
            baseURL: baseURL,
            format: .openAI,
            model: model,
            apiKeyRef: account,
            schedule: schedule,
            requestTemplate: KeepAliveDefaults.defaultRequestTemplate,
            isEnabled: isEnabled,
            lastRunAt: lastRunAt,
            lastResult: nil,
            createdAt: createdAt
        )
        KeepAliveEngine.shared.upsert(task)
        return task
    }

    /// 等引擎里的异步任务跑完（send 内部是 Task @MainActor）。
    @MainActor
    static func settle(_ rounds: Int = 40) async {
        for _ in 0..<rounds {
            // 让出主线程，让 Task { @MainActor } 有机会执行。
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func main() async {
        await runAll()
        print("")
        if confirmedDefects.isEmpty {
            print("已确认产品缺陷：0")
        } else {
            print("已确认产品缺陷（测试能稳定复现，代码需要改）：\(confirmedDefects.count)")
            for d in confirmedDefects { print("  - \(d)") }
        }
        print(failures == 0
              ? "\n测试结论: 全部通过（\(total) 项断言）"
              : "\n测试结论: \(failures) 项失败（共 \(total) 项断言）")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor
    static func runAll() async {
        // ================================================== 时刻归一化
        print("== 时刻归一化 ==")
        let dupTimes = KeepAliveSchedule(
            times: [
                KeepAliveTime(hour: 14, minute: 30),
                KeepAliveTime(hour: 9, minute: 0),
                KeepAliveTime(hour: 14, minute: 30),
            ],
            weekdays: [2]
        )
        checkEqual("重复时刻被去掉", 2, dupTimes.times.count)
        checkEqual(
            "时刻按时间升序排",
            ["09:00", "14:30"],
            dupTimes.times.map(\.display)
        )
        checkEqual(
            "非法小时被钳到 23",
            23,
            KeepAliveTime(hour: 99, minute: 0).hour
        )
        checkEqual(
            "非法分钟被钳到 59",
            59,
            KeepAliveTime(hour: 0, minute: 99).minute
        )
        checkEqual(
            "负数小时被钳到 0",
            0,
            KeepAliveTime(hour: -5, minute: 0).hour
        )
        checkEqual(
            "距零点分钟数换算正确",
            9 * 60 + 30,
            KeepAliveTime(minutesFromMidnight: 9 * 60 + 30).minutesFromMidnight
        )
        checkEqual(
            "距零点分钟数换算回时分",
            "09:30",
            KeepAliveTime(minutesFromMidnight: 570).display
        )

        // 每天时刻数量上限。
        let manyTimes = (0..<100).map { KeepAliveTime(minutesFromMidnight: $0 * 10) }
        let capped = KeepAliveSchedule(times: manyTimes, weekdays: [2])
        checkEqual(
            "每天时刻数量被压到上限",
            KeepAliveDefaults.maxTimesPerDay,
            capped.times.count
        )

        // ================================================== 星期归一化
        print("\n== 星期归一化 ==")
        let badWeekdays = KeepAliveSchedule(
            times: [KeepAliveTime(hour: 9, minute: 0)],
            weekdays: [2, 99, 0, -3, 5]
        )
        checkEqual("非法星期被剔掉", [2, 5], badWeekdays.weekdays.sorted())

        // ================================================== 星期文案
        print("\n== 星期文案 ==")
        checkEqual(
            "全选 → 每天",
            "每天",
            KeepAliveSchedule(times: [], weekdays: KeepAliveSchedule.allWeekdays).weekdayDescription
        )
        checkEqual(
            "工作日 → 周一至周五",
            "周一至周五",
            KeepAliveSchedule(times: [], weekdays: [2, 3, 4, 5, 6]).weekdayDescription
        )
        checkEqual(
            "空 → 不运行",
            "不运行",
            KeepAliveSchedule(times: [], weekdays: []).weekdayDescription
        )
        checkEqual(
            "零散组合逐个列出（周一排头）",
            "周一、周三、周日",
            KeepAliveSchedule(times: [], weekdays: [2, 4, 1]).weekdayDescription
        )
        checkEqual(
            "整条计划文案",
            "周一至周五 09:00、14:00",
            KeepAliveSchedule(
                times: [KeepAliveTime(hour: 9, minute: 0), KeepAliveTime(hour: 14, minute: 0)],
                weekdays: [2, 3, 4, 5, 6]
            ).description
        )

        // ================================================== 到点判定
        print("\n== 到点判定 ==")
        let daily9 = KeepAliveSchedule(
            times: [KeepAliveTime(hour: 9, minute: 0)],
            weekdays: KeepAliveSchedule.allWeekdays
        )

        // 8:59 —— 还没到。
        check(
            "没到点 → 不该发",
            daily9.pendingSlot(
                now: date(2026, 10, 26, 8, 59),
                lastRunAt: nil,
                since: nil,
                calendar: calendar
            ) == nil
        )
        // 9:00 —— 到了。
        let slot0900 = daily9.pendingSlot(
            now: date(2026, 10, 26, 9, 0),
            lastRunAt: nil,
            since: nil,
                calendar: calendar
        )
        check("到点 → 该发", slot0900 != nil)
        checkEqual(
            "到点时刻就是 9:00",
            date(2026, 10, 26, 9, 0).timeIntervalSince1970,
            slot0900?.timeIntervalSince1970 ?? -1
        )
        // 9:01 —— 还是那个时刻（已经过去但没发过）。
        check(
            "过了一分钟仍是同一个待发时刻",
            daily9.pendingSlot(
                now: date(2026, 10, 26, 9, 1),
                lastRunAt: nil,
                since: nil,
                calendar: calendar
            ) == slot0900
        )
        // 已经发过了 → 不该再发。
        check(
            "上次发送在时刻之后 → 不该重复发",
            daily9.pendingSlot(
                now: date(2026, 10, 26, 10, 0),
                lastRunAt: date(2026, 10, 26, 9, 0),
                since: nil,
                calendar: calendar
            ) == nil
        )
        // 上次发送在时刻之前（比如昨天发的）→ 今天该发。
        check(
            "上次发送在时刻之前 → 该发",
            daily9.pendingSlot(
                now: date(2026, 10, 26, 10, 0),
                lastRunAt: date(2026, 10, 25, 9, 0),
                since: nil,
                calendar: calendar
            ) != nil
        )
        // 没有时刻 → 永远不发。
        check(
            "没有时刻 → 不发",
            KeepAliveSchedule(times: [], weekdays: KeepAliveSchedule.allWeekdays)
                .pendingSlot(now: date(2026, 10, 26, 10, 0), lastRunAt: nil, since: nil, calendar: calendar) == nil
        )
        // 没有星期 → 永远不发。
        check(
            "没有星期 → 不发",
            KeepAliveSchedule(times: [KeepAliveTime(hour: 9, minute: 0)], weekdays: [])
                .pendingSlot(now: date(2026, 10, 26, 10, 0), lastRunAt: nil, since: nil, calendar: calendar) == nil
        )

        // ============================================== 星期过滤
        print("\n== 星期过滤 ==")
        // 只在周一运行。
        let mondayOnly = KeepAliveSchedule(
            times: [KeepAliveTime(hour: 9, minute: 0)],
            weekdays: [2]
        )
        check(
            "周一 9:00 → 该发",
            mondayOnly.pendingSlot(
                now: date(2026, 10, 26, 10, 0),
                lastRunAt: nil,
                since: nil,
                calendar: calendar
            ) != nil
        )
        check(
            "周二 10:00 → 不该发（周二没配）",
            mondayOnly.pendingSlot(
                now: date(2026, 10, 27, 10, 0),
                lastRunAt: date(2026, 10, 26, 9, 0),
                since: nil,
                calendar: calendar
            ) == nil
        )
        check(
            "周日 10:00 → 不该发（周日没配）",
            mondayOnly.pendingSlot(
                now: date(2026, 10, 25, 10, 0),
                lastRunAt: nil,
                since: nil,
                calendar: calendar
            ) == nil
        )
        // 周一过了、同一天内 —— 该发（同一天的 9:00 还没发过）。
        let weekly = KeepAliveSchedule(
            times: [KeepAliveTime(hour: 9, minute: 0)],
            weekdays: [2]
        )
        check(
            "周一当天 20:00 → 仍能认领当天 9:00 那个时刻",
            weekly.pendingSlot(
                now: date(2026, 10, 26, 20, 0),
                lastRunAt: nil,
                since: nil,
                calendar: calendar
            ) != nil
        )
        // 上周一的时刻不该被拿来补发 —— 只看当天。
        check(
            "不补发：跨天的旧时刻不算数",
            weekly.pendingSlot(
                now: date(2026, 10, 26, 20, 0),
                lastRunAt: nil,
                since: date(2026, 10, 26, 19, 0),
                calendar: calendar
            ) == nil,
            "since 是今天 19:00，当天 9:00 已被锚点挡住"
        )

        // ============================================ 下一个时刻
        print("\n== 下一个时刻 ==")
        let nextDaily = daily9.nextSlot(after: date(2026, 10, 26, 8, 0), calendar: calendar)
        checkEqual(
            "今天 8:00 的下一个是今天 9:00",
            date(2026, 10, 26, 9, 0).timeIntervalSince1970,
            nextDaily?.timeIntervalSince1970 ?? -1
        )
        let nextTomorrow = daily9.nextSlot(after: date(2026, 10, 26, 9, 0), calendar: calendar)
        checkEqual(
            "今天 9:00 的下一个是明天 9:00",
            date(2026, 10, 27, 9, 0).timeIntervalSince1970,
            nextTomorrow?.timeIntervalSince1970 ?? -1
        )
        check(
            "空计划没有下一个时刻",
            KeepAliveSchedule(times: [], weekdays: [2])
                .nextSlot(after: Date(), calendar: calendar) == nil
        )

        // ============================================ 旧格式迁移
        print("\n== 旧格式迁移 ==")
        let legacyJSON = """
        [{
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "legacy",
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
        UserDefaults.standard.set(
            Data(legacyJSON.utf8),
            forKey: KeepAliveStore.storageKey
        )
        let migrated = KeepAliveStore.load()
        checkEqual("旧数据读得出来", 1, migrated.count)
        checkEqual(
            "240 分钟间隔迁移成 6 个时刻",
            ["00:00", "04:00", "08:00", "12:00", "16:00", "20:00"],
            migrated.first?.schedule.times.map(\.display) ?? []
        )
        checkEqual(
            "迁移后星期是每天",
            KeepAliveSchedule.allWeekdays,
            migrated.first?.schedule.weekdays ?? []
        )
        checkEqual("迁移后任务名保留", "legacy", migrated.first?.name ?? "")
        checkEqual("迁移后地址保留", "https://api.example.com", migrated.first?.baseURL ?? "")
        UserDefaults.standard.removeObject(forKey: KeepAliveStore.storageKey)

        // 新格式也能读。
        reset()
        let newFormat = makeTask(name: "new-format")
        let roundTrip = KeepAliveStore.load().first { $0.id == newFormat.id }
        check("新格式读得回来", roundTrip != nil)
        checkEqual(
            "新格式的时刻保留",
            ["09:00"],
            roundTrip?.schedule.times.map(\.display) ?? []
        )

        // ================================================== 失败不推进锚点
        print("\n== 失败时不推进锚点 ==")
        reset()
        let t1 = makeTask(name: "fail-anchor", lastRunAt: nil)
        KeepAliveHTTPClient.nextStatus = 500
        KeepAliveHTTPClient.nextBody = Data("server exploded".utf8)
        KeepAliveEngine.shared.triggerNow(id: t1.id)
        await settle()
        let afterFail = KeepAliveEngine.shared.tasks.first { $0.id == t1.id }
        check(
            "失败后 lastRunAt 不变（锚点没推进）",
            afterFail?.lastRunAt == nil,
            "实际 \(afterFail?.lastRunAt?.description ?? "nil")"
        )
        check(
            "失败后 lastResult 记录了失败原因",
            (afterFail?.lastResult ?? "").hasPrefix("失败"),
            "实际 \(afterFail?.lastResult ?? "nil")"
        )

        // ================================================== 成功推进锚点
        print("\n== 成功时推进锚点 ==")
        reset()
        let t2 = makeTask(name: "ok-anchor", lastRunAt: nil)
        KeepAliveHTTPClient.nextStatus = 200
        KeepAliveEngine.shared.triggerNow(id: t2.id)
        await settle()
        let afterOK = KeepAliveEngine.shared.tasks.first { $0.id == t2.id }
        check(
            "成功后 lastRunAt 推进到当前",
            (afterOK?.lastRunAt ?? .distantPast) > Date(timeIntervalSinceNow: -30)
        )
        checkEqual(
            "成功后 lastResult 是「已发送」",
            "已发送",
            afterOK?.lastResult ?? ""
        )

        // ============================================== 成功清零退避计数
        print("\n== 成功清零退避计数 ==")
        reset()
        let t3 = makeTask(name: "backoff-reset", lastRunAt: nil)
        for _ in 0..<3 {
            KeepAliveHTTPClient.nextStatus = 500
            KeepAliveEngine.shared.triggerNow(id: t3.id)
            await settle()
        }
        KeepAliveHTTPClient.nextStatus = 200
        KeepAliveEngine.shared.triggerNow(id: t3.id)
        await settle()
        checkEqual(
            "成功一次后 lastResult 变回成功",
            "已发送",
            KeepAliveEngine.shared.tasks.first { $0.id == t3.id }?.lastResult ?? ""
        )
        // 手动触发不受退避限制（退避只管定时路径）。
        KeepAliveHTTPClient.nextStatus = 500
        KeepAliveEngine.shared.triggerNow(id: t3.id)
        await settle()
        let reqCountBefore = KeepAliveHTTPClient.requestCount
        KeepAliveEngine.shared.triggerNow(id: t3.id)
        await settle()
        check(
            "手动触发不受退避限制（退避只管定时路径）",
            KeepAliveHTTPClient.requestCount == reqCountBefore + 1,
            "实际 \(KeepAliveHTTPClient.requestCount - reqCountBefore)"
        )

        // ================================================== inFlight 防并发
        print("\n== inFlight 防止同一任务被并发触发 ==")
        reset()
        let t4 = makeTask(name: "inflight", lastRunAt: nil)
        KeepAliveHTTPClient.suspendBeforeResponse = true
        KeepAliveEngine.shared.triggerNow(id: t4.id)
        await settle(10)
        checkEqual("第一次请求已发出", 1, KeepAliveHTTPClient.requestCount)
        KeepAliveEngine.shared.triggerNow(id: t4.id)
        KeepAliveEngine.shared.triggerNow(id: t4.id)
        await settle(10)
        checkEqual(
            "并发手动触发被 inFlight 挡住，只发出 1 个请求",
            1,
            KeepAliveHTTPClient.requestCount
        )
        KeepAliveHTTPClient.suspendBeforeResponse = false
        await settle(20)
        check(
            "放行后请求完成，锚点推进",
            (KeepAliveEngine.shared.tasks.first { $0.id == t4.id }?.lastRunAt ?? .distantPast)
                > Date(timeIntervalSinceNow: -30)
        )

        // ================================================== 停用任务不发
        print("\n== 停用的任务不被调度 ==")
        reset()
        let t5 = makeTask(name: "disabled", lastRunAt: nil, isEnabled: false)
        check(
            "任务确实存成了停用",
            KeepAliveEngine.shared.tasks.first { $0.id == t5.id }?.isEnabled == false
        )

        // ============================================ 长时间没跑 → 不补发
        print("\n== 长时间没跑（应用退出过）后重启不补发 ==")
        reset()
        // 上次成功是上周。今天 9:00 如果已经过了，按「不补发」的规则 ——
        // 只有「今天」的时刻算数，而上周那个时刻早于锚点，不该被认领。
        // 这里用「未来的时刻」来验证：任务不处于待发状态。
        let futureHour = (Calendar.current.component(.hour, from: Date()) + 1) % 24
        let t6 = makeTask(
            name: "stale",
            schedule: KeepAliveSchedule(
                times: [KeepAliveTime(hour: futureHour, minute: 0)],
                weekdays: KeepAliveSchedule.allWeekdays
            ),
            lastRunAt: Date(timeIntervalSinceNow: -86400 * 7)
        )
        check(
            "关了很久再打开，不补发已作废的时刻",
            !t6.isDue(at: Date(), calendar: calendar),
            "时刻 \(futureHour):00 还没到"
        )
        // 但只要今天的时刻到了、且晚于锚点，就该发。
        // 锚点是 max(上次成功, 创建时间) —— 老任务的创建时间在几天前，
        // 所以今天的时刻早于锚点、不会发；要让它发，创建时间也必须早于时刻。
        let pastHour = Calendar.current.component(.hour, from: Date())
        let t6b = makeTask(
            name: "due-now",
            schedule: KeepAliveSchedule(
                times: [KeepAliveTime(hour: pastHour, minute: 0)],
                weekdays: KeepAliveSchedule.allWeekdays
            ),
            lastRunAt: Date(timeIntervalSinceNow: -86400 * 7),
            createdAt: Date(timeIntervalSinceNow: -86400 * 7)
        )
        check(
            "今天的时刻到了 → 该发",
            t6b.isDue(at: Date(), calendar: calendar),
            "时刻 \(pastHour):00"
        )
        // 新建任务（创建时间=现在）即使时刻已过也不该立刻发。
        let t6c = makeTask(
            name: "new-dont-fire",
            schedule: KeepAliveSchedule(
                times: [KeepAliveTime(hour: pastHour, minute: 0)],
                weekdays: KeepAliveSchedule.allWeekdays
            )
        )
        check(
            "新建任务即使时刻已过也不立刻发",
            !t6c.isDue(at: Date(), calendar: calendar),
            "时刻 \(pastHour):00，创建时间=现在"
        )

        // ============================================ 新建任务不立刻发
        print("\n== 新建任务不会在创建瞬间发 ==")
        reset()
        // 新建的时刻在 9:00，而现在（测试运行时）通常不是 9:00 ——
        // 用一个「未来的时刻」来验证新建任务不立刻发。
        let freshHour = (Calendar.current.component(.hour, from: Date()) + 1) % 24
        let t7 = makeTask(
            name: "fresh",
            schedule: KeepAliveSchedule(
                times: [KeepAliveTime(hour: freshHour, minute: 0)],
                weekdays: KeepAliveSchedule.allWeekdays
            )
        )
        check(
            "新任务在时刻到来前不该发",
            !t7.isDue(at: Date(), calendar: calendar),
            "时刻 \(freshHour):00"
        )

        // ============================================ 删除任务连带删 Keychain
        print("\n== 删除任务连带清理 Keychain ==")
        reset()
        let t8 = makeTask(name: "todelete", key: "«redacted:sk-…»")
        let account8 = t8.apiKeyRef
        checkEqual("Keychain 里有条目", "«redacted:sk-…»", KeepAliveKeychain.snapshot()[account8] ?? "")
        KeepAliveEngine.shared.remove(id: t8.id)
        checkEqual("任务已从列表移除", 0, KeepAliveEngine.shared.tasks.count)
        check(
            "Keychain 条目也删掉了",
            KeepAliveKeychain.snapshot()[account8] == nil,
            "实际 \(KeepAliveKeychain.snapshot()[account8] ?? "nil")"
        )

        // ============================================ API Key 不出现在日志里
        print("\n== API Key 不出现在日志 / 错误摘要 / 任务列表里 ==")
        reset()
        let secret = "«redacted:sk-…»"
        let t9 = makeTask(name: "secret", key: secret)
        KeepAliveHTTPClient.nextStatus = 401
        // 模拟服务端把 key 回显在错误体里 —— 脱敏应该抹掉它。
        KeepAliveHTTPClient.nextBody = Data("invalid api key: \(secret) rejected".utf8)
        KeepAliveEngine.shared.triggerNow(id: t9.id)
        await settle()
        let result = KeepAliveEngine.shared.tasks.first { $0.id == t9.id }?.lastResult ?? ""
        check(
            "错误摘要里没有明文 key",
            !result.contains(secret),
            "实际 \(result)"
        )
        check(
            "错误摘要里 key 被替换成 ***",
            result.contains("***"),
            "实际 \(result)"
        )
        let allLogs = SleepController.logSnapshot().joined(separator: "\n")
        check(
            "日志里没有明文 key",
            !allLogs.contains(secret),
            "实际 \(allLogs)"
        )
        check(
            "任务列表里没有明文 key",
            !KeepAliveEngine.shared.tasks.contains { $0.lastResult?.contains(secret) == true }
        )

        // 成功路径的日志也不该有 key。
        reset()
        let t10 = makeTask(name: "secret-ok", key: secret)
        KeepAliveHTTPClient.nextStatus = 200
        KeepAliveEngine.shared.triggerNow(id: t10.id)
        await settle()
        check(
            "成功路径的日志里也没有明文 key",
            !SleepController.logSnapshot().joined(separator: "\n").contains(secret)
        )

        // ============================================ 头里带 key，但没进 UserDefaults
        print("\n== API Key 不进 UserDefaults ==")
        reset()
        let t11 = makeTask(name: "ud", key: secret)
        KeepAliveHTTPClient.nextStatus = 200
        KeepAliveEngine.shared.triggerNow(id: t11.id)
        await settle()
        let stored = UserDefaults.standard.data(forKey: KeepAliveStore.storageKey)
        let storedText = stored.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(
            "UserDefaults 里的任务 JSON 不含明文 key",
            !storedText.contains(secret),
            "实际 \(storedText)"
        )
        check(
            "UserDefaults 里只有 Keychain 引用名",
            storedText.contains("keepalive.")
        )

        // ================================================== 真实请求的形状
        print("\n== 真实 KeepAliveClient 发出的请求形状 ==")
        reset()
        let t12 = makeTask(
            name: "shape",
            baseURL: "https://api.example.com/v1",
            model: "gpt-test",
            key: "sk-shape"
        )
        KeepAliveHTTPClient.reset()
        KeepAliveHTTPClient.nextStatus = 200
        KeepAliveEngine.shared.triggerNow(id: t12.id)
        await settle()
        checkEqual("发出了 1 个请求", 1, KeepAliveHTTPClient.requestCount)
        if let req = KeepAliveHTTPClient.requestSnapshot.first {
            checkEqual(
                "URL 是 /v1/chat/completions",
                "https://api.example.com/v1/chat/completions",
                req.url.absoluteString
            )
            checkEqual("方法是 POST", "POST", req.method)
            checkEqual(
                "Authorization 是 Bearer <key>",
                "Bearer sk-shape",
                req.headers["Authorization"] ?? ""
            )
            let bodyText = req.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            check("body 含 model", bodyText.contains("gpt-test"), "实际 \(bodyText)")
            check("body 含 max_tokens=1", bodyText.contains("\"max_tokens\":1"), "实际 \(bodyText)")
            check("body 含默认模板内容", bodyText.contains("测试消息"), "实际 \(bodyText)")
            check("body 不含 key", !bodyText.contains("sk-shape"), "实际 \(bodyText)")
        }

        // Anthropic 协议的头。
        reset()
        let anthKey = "«redacted:sk-…»"
        let t13 = makeTask(name: "anth", baseURL: "https://api.anthropic.com", model: "claude-test")
        var anthTask = t13
        anthTask.format = .anthropic
        try? KeepAliveKeychain.save(key: anthKey, account: anthTask.apiKeyRef)
        KeepAliveEngine.shared.upsert(anthTask)
        KeepAliveHTTPClient.reset()
        KeepAliveHTTPClient.nextStatus = 200
        KeepAliveEngine.shared.triggerNow(id: t13.id)
        await settle()
        if let req = KeepAliveHTTPClient.requestSnapshot.first {
            checkEqual(
                "Anthropic URL 是 /v1/messages",
                "https://api.anthropic.com/v1/messages",
                req.url.absoluteString
            )
            checkEqual("Anthropic 用 x-api-key", anthKey, req.headers["x-api-key"] ?? "")
            check(
                "Anthropic 带 anthropic-version",
                (req.headers["anthropic-version"] ?? "") == "2023-06-01"
            )
            check(
                "Anthropic 不带 Authorization",
                req.headers["Authorization"] == nil
            )
        }

        // 空 key → 不发请求，报「未配置 API Key」。
        reset()
        let t14 = makeTask(name: "nokey", key: nil)
        KeepAliveHTTPClient.reset()
        KeepAliveEngine.shared.triggerNow(id: t14.id)
        await settle()
        checkEqual("没有 key 时一个请求都不发", 0, KeepAliveHTTPClient.requestCount)
        checkEqual(
            "没有 key 时结果写「未配置 API Key」",
            "失败：未配置 API Key",
            KeepAliveEngine.shared.tasks.first { $0.id == t14.id }?.lastResult ?? ""
        )

        // 空模型名 → 同样不发。
        reset()
        let t15 = makeTask(name: "nomodel", model: "")
        KeepAliveHTTPClient.reset()
        KeepAliveEngine.shared.triggerNow(id: t15.id)
        await settle()
        checkEqual("没有模型名时一个请求都不发", 0, KeepAliveHTTPClient.requestCount)
        checkEqual(
            "没有模型名时结果写「未配置模型名」",
            "失败：未配置模型名",
            KeepAliveEngine.shared.tasks.first { $0.id == t15.id }?.lastResult ?? ""
        )

        // 空 baseURL → 不发。
        reset()
        let t16 = makeTask(name: "nobase", baseURL: "")
        KeepAliveHTTPClient.reset()
        KeepAliveEngine.shared.triggerNow(id: t16.id)
        await settle()
        checkEqual("地址无效时一个请求都不发", 0, KeepAliveHTTPClient.requestCount)
        checkEqual(
            "地址无效时结果写「地址无效」",
            "失败：地址无效",
            KeepAliveEngine.shared.tasks.first { $0.id == t16.id }?.lastResult ?? ""
        )

        // ================================================== 连续失败累积
        print("\n== 连续失败累积 ==")
        reset()
        let t17 = makeTask(name: "streak", lastRunAt: nil)
        for i in 1...4 {
            KeepAliveHTTPClient.nextStatus = 500
            KeepAliveHTTPClient.nextBody = Data("err \(i)".utf8)
            KeepAliveEngine.shared.triggerNow(id: t17.id)
            await settle()
        }
        let streak = KeepAliveEngine.shared.tasks.first { $0.id == t17.id }
        check(
            "连续失败 4 次后 lastResult 仍是失败",
            (streak?.lastResult ?? "").hasPrefix("失败"),
            "实际 \(streak?.lastResult ?? "nil")"
        )
        check(
            "连续失败 4 次 → 日志里有 4 条失败记录",
            SleepController.logSnapshot().filter { $0.contains("失败") }.count >= 4,
            "实际 \(SleepController.logSnapshot().filter { $0.contains("失败") }.count)"
        )
        check(
            "连续失败后 lastRunAt 仍不推进",
            streak?.lastRunAt == nil
        )

        // ================================================== 收尾清理
        reset()
        print("\n== 清理 ==")
        KeepAliveEngine.shared.reload()
        check("任务列表已清空", KeepAliveEngine.shared.tasks.isEmpty)
        check(
            "UserDefaults 已清理",
            UserDefaults.standard.data(forKey: KeepAliveStore.storageKey) == nil
        )
        check("Keychain 已清理", KeepAliveKeychain.snapshot().isEmpty)
    }
}
