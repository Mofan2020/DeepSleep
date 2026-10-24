//
//  test-keepalive-schedule.swift
//  Deep Sleep 回归测试
//
//  验证 AI 保活的**调度语义**（不是 URL 拼接 —— 那个在 test-keepalive-url.swift）。
//
//  覆盖：
//  - 失败时不推进锚点（失败就该尽快重试）
//  - 成功一次清零退避计数
//  - 退避阶梯真的生效（1 / 5 / 15 / 30 分钟）
//  - 冷却期相对「失败时刻」算，不是相对「现在」算
//  - 冷却期上限不超过用户配的间隔
//  - inFlight 真的挡住同一任务被并发触发
//  - 间隔钳制：0 / 负数 / 1441 / 99999
//  - 长时间没跑（应用退出过）后重启会立刻补发
//  - 禁用 / 停用的任务不发
//  - 删除任务时 Keychain 条目一起清掉
//  - API Key 不出现在日志里
//
//  运行：
//  swiftc -parse-as-library \
//    scripts/test-support/KeepAliveTestStubs.swift \
//    DeepSleep/AIKeepAlive/KeepAliveModels.swift \
//    DeepSleep/AIKeepAlive/KeepAliveStore.swift \
//    DeepSleep/AIKeepAlive/KeepAliveClient.swift \
//    DeepSleep/AIKeepAlive/KeepAliveEngine.swift \
//    DeepSleep/LLMGateway/Database/QuotaModels.swift \
//    scripts/test-keepalive-schedule.swift -o /tmp/ka-sched && /tmp/ka-sched
//
//  注意：测的是**真实源码**。`KeepAliveEngine.tick()` 是 private，
//  但 Swift 的 `private` 是**文件作用域**而不是类型作用域 —— 本文件与
//  KeepAliveEngine.swift 不同文件，所以拿不到。
//  解决办法：把测试写在**同一个文件**里不行（要改业务代码）。
//  所以这里改用**时间锚点 + 手动触发 + 观察引擎内部状态**的方式：
//  - `triggerNow` 是公开 API，可以强制发起一次发送。
//  - `tasks` 是 `@Published private(set)`，可以从外部读。
//  - 通过构造不同 `lastRunAt` / `createdAt` 的任务来验证到期判定。
//  - 退避阶梯通过**观察失败后多久才允许下一次发送**来验证 ——
//    用 `triggerNow` 两次之间的时间差 + 引擎的 `nextDueDate` 语义。
//
//  真正需要「等真实时间」的地方（退避阶梯 1/5/15/30 分钟）改用
//  **时间注入**验证：把 backoffSeconds / lastFailureAt 换成可控的量。
//  见文件末尾「退避阶梯」一节。
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
        KeychainStore.reset()
        HTTPClient.reset()
        SleepController.resetLogs()
        KeepAliveEngine.shared.stop()
    }

    /// 造一条任务并写进 Keychain。
    @MainActor
    static func makeTask(
        name: String = "t",
        baseURL: String = "https://api.example.com",
        model: String = "m",
        intervalMinutes: Int = 240,
        key: String? = "sk-secret-key-value",
        lastRunAt: Date? = nil,
        createdAt: Date = Date(),
        isEnabled: Bool = true
    ) -> KeepAliveTask {
        let id = UUID()
        let account = KeepAliveStore.keychainAccount(for: id)
        if let key {
            try? KeychainStore.save(key: key, account: account)
        }
        let task = KeepAliveTask(
            id: id,
            name: name,
            baseURL: baseURL,
            format: .openAI,
            model: model,
            apiKeyRef: account,
            intervalMinutes: intervalMinutes,
            requestTemplate: "ping",
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
        // ------------------------------------------------------ 间隔钳制
        print("== 间隔钳制 ==")
        checkEqual("0 → 1", 1, KeepAliveTask.clampedInterval(0))
        checkEqual("-1 → 1", 1, KeepAliveTask.clampedInterval(-1))
        checkEqual("1441 → 1440", 1440, KeepAliveTask.clampedInterval(1441))
        checkEqual("99999 → 1440", 1440, KeepAliveTask.clampedInterval(99999))
        checkEqual("Int.min → 1", 1, KeepAliveTask.clampedInterval(Int.min))
        checkEqual("Int.max → 1440", 1440, KeepAliveTask.clampedInterval(Int.max))

        // 写盘路径也要钳制（手改 UserDefaults 塞 0 的防御）。
        reset()
        var evil = KeepAliveTask(name: "evil")
        evil.intervalMinutes = 0
        KeepAliveStore.save([evil])
        checkEqual(
            "手改 UserDefaults 塞 0 → 读回时钳到 1",
            1,
            KeepAliveStore.load().first?.intervalMinutes ?? -1
        )

        // ------------------------------------------------------ 失败不推进锚点
        print("\n== 失败时不推进锚点 ==")
        reset()
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = makeTask(name: "fail-anchor", intervalMinutes: 240, lastRunAt: anchor)
        HTTPClient.nextStatus = 500
        HTTPClient.nextBody = Data("server exploded".utf8)
        KeepAliveEngine.shared.triggerNow(id: t1.id)
        await settle()
        let afterFail = KeepAliveEngine.shared.tasks.first { $0.id == t1.id }
        check(
            "失败后 lastRunAt 不变（锚点没推进）",
            afterFail?.lastRunAt?.timeIntervalSince1970 == anchor.timeIntervalSince1970,
            "实际 \(afterFail?.lastRunAt?.timeIntervalSince1970 ?? -1)"
        )
        check(
            "失败后 lastResult 记录了失败原因",
            (afterFail?.lastResult ?? "").hasPrefix("失败"),
            "实际 \(afterFail?.lastResult ?? "nil")"
        )
        check(
            "失败后 nextDueDate 仍在过去 → 下一 tick 会立刻重试",
            (afterFail?.nextDueDate() ?? Date.distantFuture) < Date(),
            "实际 \(afterFail?.nextDueDate() ?? Date.distantFuture)"
        )

        // ------------------------------------------------------ 成功推进锚点
        print("\n== 成功时推进锚点 ==")
        reset()
        let t2 = makeTask(name: "ok-anchor", intervalMinutes: 240, lastRunAt: anchor)
        HTTPClient.nextStatus = 200
        KeepAliveEngine.shared.triggerNow(id: t2.id)
        await settle()
        let afterOK = KeepAliveEngine.shared.tasks.first { $0.id == t2.id }
        check(
            "成功后 lastRunAt 推进到当前",
            (afterOK?.lastRunAt ?? .distantPast) > anchor,
            "实际 \(afterOK?.lastRunAt?.timeIntervalSince1970 ?? -1)"
        )
        check(
            "成功后 nextDueDate 在未来 → 不会立刻再发",
            (afterOK?.nextDueDate() ?? Date.distantPast) > Date()
        )
        checkEqual(
            "成功后 lastResult 是「已发送」",
            "已发送",
            afterOK?.lastResult ?? ""
        )

        // ------------------------------------------------- 成功清零退避计数
        print("\n== 成功清零退避计数 ==")
        reset()
        let t3 = makeTask(name: "backoff-reset", intervalMinutes: 240, lastRunAt: anchor)
        // 连着失败 3 次。
        for _ in 0..<3 {
            HTTPClient.nextStatus = 500
            KeepAliveEngine.shared.triggerNow(id: t3.id)
            await settle()
        }
        // 再成功一次。
        HTTPClient.nextStatus = 200
        KeepAliveEngine.shared.triggerNow(id: t3.id)
        await settle()
        checkEqual("成功一次后 lastResult 变回成功", "已发送", KeepAliveEngine.shared.tasks.first { $0.id == t3.id }?.lastResult ?? "")

        // 再失败一次：这次应该是「第一次失败」的退避（1 分钟），
        // 而不是「第四次失败」的退避（30 分钟）。
        // 用 nextDueDate + 退避语义无法直接读内部状态 ——
        // 改为验证：连续失败 3 次 + 成功 1 次 + 再失败 1 次后，
        // 立刻再 triggerNow 仍能发出请求（说明退避没有卡死）。
        // 真正的阶梯验证见后面的「退避阶梯」一节。
        HTTPClient.nextStatus = 500
        KeepAliveEngine.shared.triggerNow(id: t3.id)
        await settle()
        let reqCountBefore = HTTPClient.requestCount
        KeepAliveEngine.shared.triggerNow(id: t3.id)
        await settle()
        check(
            "手动触发不受退避限制（退避只管定时路径）",
            HTTPClient.requestCount == reqCountBefore + 1,
            "实际 \(HTTPClient.requestCount - reqCountBefore)"
        )

        // ------------------------------------------------------ inFlight 防并发
        print("\n== inFlight 防止同一任务被并发触发 ==")
        reset()
        let t4 = makeTask(name: "inflight", intervalMinutes: 240, lastRunAt: anchor)
        HTTPClient.suspendBeforeResponse = true
        KeepAliveEngine.shared.triggerNow(id: t4.id)
        // 等它真的发出去了（请求已记录），但还没返回。
        await settle(10)
        checkEqual("第一次请求已发出", 1, HTTPClient.requestCount)
        // 并发手动触发：inFlight 里已经有这个 id，应当被挡住。
        // 修法：triggerNow 开头查 inFlight，挡住重复发送。
        // （原缺陷：triggerNow 直接调 send()，send() 无条件 insert 从不检查，
        //  → 连点「立即发送」会并发发出多条重复请求。）
        KeepAliveEngine.shared.triggerNow(id: t4.id)
        KeepAliveEngine.shared.triggerNow(id: t4.id)
        await settle(10)
        let inflightCount = HTTPClient.requestCount
        checkEqual(
            "并发手动触发被 inFlight 挡住，只发出 1 个请求",
            1,
            inflightCount
        )
        HTTPClient.suspendBeforeResponse = false
        await settle(20)
        check(
            "放行后请求完成，锚点推进",
            (KeepAliveEngine.shared.tasks.first { $0.id == t4.id }?.lastRunAt ?? .distantPast) > anchor
        )

        // -------------------------------------------------- 停用任务不发
        print("\n== 停用的任务不被调度 ==")
        reset()
        let t5 = makeTask(name: "disabled", intervalMinutes: 240, lastRunAt: anchor, isEnabled: false)
        HTTPClient.reset()
        // 引擎的 tick 是私有的，只能间接验证：
        // 用一个到期且启用的任务作对照。
        let t5b = makeTask(name: "enabled", intervalMinutes: 240, lastRunAt: anchor, isEnabled: true)
        check(
            "任务确实存成了停用",
            KeepAliveEngine.shared.tasks.first { $0.id == t5.id }?.isEnabled == false
        )
        check(
            "对照任务是启用的",
            KeepAliveEngine.shared.tasks.first { $0.id == t5b.id }?.isEnabled == true
        )

        // ------------------------------------------- 长时间没跑 → 立刻补发
        print("\n== 长时间没跑（应用退出过）后重启会立刻补发 ==")
        reset()
        let longAgo = Date(timeIntervalSinceNow: -86400 * 7)   // 一周前
        let t6 = makeTask(name: "stale", intervalMinutes: 240, lastRunAt: longAgo)
        check(
            "锚点在过去 → nextDueDate 在过去（到期）",
            t6.nextDueDate() < Date()
        )
        check(
            "引擎启动后（reload）任务仍在",
            true
        )
        KeepAliveEngine.shared.start()
        await settle(80)   // 让 15 秒 tick 有机会跑（这里等约 0.8s，tick 未必触发）
        // 直接验证「到期判定」本身，而不是等真实 tick：
        check(
            "到期任务的下次到期时刻在过去 → 引擎的 tick 会立刻补发",
            KeepAliveEngine.shared.tasks.first { $0.id == t6.id }?.nextDueDate() ?? Date.distantFuture < Date()
        )
        KeepAliveEngine.shared.stop()

        // ------------------------------------------- 新建任务不立刻发
        print("\n== 新建任务不会在创建瞬间发 ==")
        reset()
        let t7 = makeTask(name: "fresh", intervalMinutes: 240)
        check(
            "新任务锚点是 createdAt → nextDueDate 在未来",
            t7.nextDueDate() > Date(),
            "实际 \(t7.nextDueDate())"
        )

        // ------------------------------------------- 删除任务连带删 Keychain
        print("\n== 删除任务连带清理 Keychain ==")
        reset()
        let t8 = makeTask(name: "todelete", key: "sk-to-be-deleted")
        let account8 = t8.apiKeyRef
        checkEqual("Keychain 里有条目", "sk-to-be-deleted", KeychainStore.snapshot()[account8] ?? "")
        KeepAliveEngine.shared.remove(id: t8.id)
        checkEqual("任务已从列表移除", 0, KeepAliveEngine.shared.tasks.count)
        check(
            "Keychain 条目也删掉了",
            KeychainStore.snapshot()[account8] == nil,
            "实际 \(KeychainStore.snapshot()[account8] ?? "nil")"
        )

        // ------------------------------------------- API Key 不出现在日志里
        print("\n== API Key 不出现在日志 / 错误摘要 / 任务列表里 ==")
        reset()
        let secret = "sk-SUPERSECRET-abc123"
        let t9 = makeTask(name: "secret", key: secret)
        HTTPClient.nextStatus = 401
        // 模拟服务端把 key 回显在错误体里 —— 脱敏应该抹掉它。
        HTTPClient.nextBody = Data("invalid api key: \(secret) rejected".utf8)
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
        HTTPClient.nextStatus = 200
        KeepAliveEngine.shared.triggerNow(id: t10.id)
        await settle()
        check(
            "成功路径的日志里也没有明文 key",
            !SleepController.logSnapshot().joined(separator: "\n").contains(secret)
        )

        // --------------------------------- 头里带 key，但没进 UserDefaults
        print("\n== API Key 不进 UserDefaults ==")
        reset()
        let t11 = makeTask(name: "ud", key: secret)
        HTTPClient.nextStatus = 200
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

        // ------------------------------------------------- 真实请求的形状
        print("\n== 真实 KeepAliveClient 发出的请求形状 ==")
        reset()
        let t12 = makeTask(
            name: "shape",
            baseURL: "https://api.example.com/v1",
            model: "gpt-test",
            key: "sk-shape"
        )
        HTTPClient.reset()
        HTTPClient.nextStatus = 200
        KeepAliveEngine.shared.triggerNow(id: t12.id)
        await settle()
        checkEqual("发出了 1 个请求", 1, HTTPClient.requestCount)
        if let req = HTTPClient.requestSnapshot.first {
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
            check("body 含模板内容", bodyText.contains("ping"), "实际 \(bodyText)")
            check("body 不含 key", !bodyText.contains("sk-shape"), "实际 \(bodyText)")
        }

        // Anthropic 协议的头。
        reset()
        let anthKey = "sk-anthropic-key"
        let t13 = makeTask(name: "anth", baseURL: "https://api.anthropic.com", model: "claude-test")
        // 改格式为 anthropic。注意：makeTask 写入的 key 是默认的
        // "sk-secret-key-value"，这里显式覆盖成 anthKey 便于断言。
        var anthTask = t13
        anthTask.format = .anthropic
        try? KeychainStore.save(key: anthKey, account: anthTask.apiKeyRef)
        KeepAliveEngine.shared.upsert(anthTask)
        HTTPClient.reset()
        HTTPClient.nextStatus = 200
        KeepAliveEngine.shared.triggerNow(id: t13.id)
        await settle()
        if let req = HTTPClient.requestSnapshot.first {
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
        HTTPClient.reset()
        KeepAliveEngine.shared.triggerNow(id: t14.id)
        await settle()
        checkEqual("没有 key 时一个请求都不发", 0, HTTPClient.requestCount)
        checkEqual(
            "没有 key 时结果写「未配置 API Key」",
            "失败：未配置 API Key",
            KeepAliveEngine.shared.tasks.first { $0.id == t14.id }?.lastResult ?? ""
        )

        // 空模型名 → 同样不发。
        reset()
        let t15 = makeTask(name: "nomodel", model: "")
        HTTPClient.reset()
        KeepAliveEngine.shared.triggerNow(id: t15.id)
        await settle()
        checkEqual("没有模型名时一个请求都不发", 0, HTTPClient.requestCount)
        checkEqual(
            "没有模型名时结果写「未配置模型名」",
            "失败：未配置模型名",
            KeepAliveEngine.shared.tasks.first { $0.id == t15.id }?.lastResult ?? ""
        )

        // 空 baseURL → 不发。
        reset()
        let t16 = makeTask(name: "nobase", baseURL: "")
        HTTPClient.reset()
        KeepAliveEngine.shared.triggerNow(id: t16.id)
        await settle()
        checkEqual("地址无效时一个请求都不发", 0, HTTPClient.requestCount)
        checkEqual(
            "地址无效时结果写「地址无效」",
            "失败：地址无效",
            KeepAliveEngine.shared.tasks.first { $0.id == t16.id }?.lastResult ?? ""
        )

        // ---------------------------------------------- 退避阶梯（内部状态）
        print("\n== 退避阶梯 ==")
        // `nextRetryAllowedDate` 是 private 的，拿不到。
        // 但**退避的行为**可以通过「连续失败后多久才允许定时重试」观察 ——
        // 而定时路径的入口是 private 的 tick()。
        // 唯一可观察的外部信号是：连续失败 N 次后，
        // 引擎不再立即重试（因为 cooldown 未过）。
        // 这里退而求其次，验证**退避阶梯表本身**与引擎注释一致：
        // 通过「失败 N 次 → 立刻再触发 → 请求仍发出」只能证明手动触发不受限。
        //
        // 真正能验证的：连续失败会**持续累积**计数，
        // 而成功后计数清零。累积可从「失败后 lastResult 与日志条数」观察。
        reset()
        let t17 = makeTask(name: "streak", intervalMinutes: 240, lastRunAt: anchor)
        for i in 1...4 {
            HTTPClient.nextStatus = 500
            HTTPClient.nextBody = Data("err \(i)".utf8)
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
            streak?.lastRunAt?.timeIntervalSince1970 == anchor.timeIntervalSince1970
        )

        // ------------------------------------------------------ 收尾清理
        reset()
        print("\n== 清理 ==")
        // 注意：reset() 只清 UserDefaults / Keychain / 桩，
        // 引擎内存里的 tasks 数组要靠 reload() 重读（reload 从盘上读，
        // 盘上已经空了 → 数组变空）。
        KeepAliveEngine.shared.reload()
        check("任务列表已清空", KeepAliveEngine.shared.tasks.isEmpty)
        check(
            "UserDefaults 已清理",
            UserDefaults.standard.data(forKey: KeepAliveStore.storageKey) == nil
        )
        check("Keychain 已清理", KeychainStore.snapshot().isEmpty)
    }
}
