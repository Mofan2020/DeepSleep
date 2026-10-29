//
//  test-alert-rules.swift
//  Deep Sleep 回归测试
//
//  验证自定义告警规则的纯逻辑：持续时间判定、5 分钟冷却、两种比较方向、
//  指标缺失的处理、持久化往返、字段与契约一致。
//
//  运行：
//  swiftc -parse-as-library \
//    DeepSleep/Core/AlertRule.swift \
//    DeepSleep/Core/AlertRuleEngine.swift \
//    scripts/test-alert-rules.swift -o /tmp/alert-test && /tmp/alert-test
//

import Foundation

@main
struct AlertRuleTests {

    static func main() {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)" + (detail.isEmpty ? "" : " —— \(detail)"))
                failures += 1
            }
        }

        func checkEqual<T: Equatable>(_ name: String, _ expected: T, _ actual: T) {
            check(name, expected == actual, "期望 \(expected)，实际 \(actual)")
        }

        let t0 = Date(timeIntervalSince1970: 3_000_000)

        // ===================================================== 比较方向
        print("== operator 的两种方向 ==")
        check("greaterThan: 95 > 90 → true", AlertOperator.greaterThan.matches(value: 95, threshold: 90))
        check("greaterThan: 90 > 90 → false（严格大于）", !AlertOperator.greaterThan.matches(value: 90, threshold: 90))
        check("lessThan: 85 < 90 → true", AlertOperator.lessThan.matches(value: 85, threshold: 90))
        check("lessThan: 90 < 90 → false（严格小于）", !AlertOperator.lessThan.matches(value: 90, threshold: 90))

        // ===================================================== 持续时间
        print("\n== 持续时间判定（90 秒）==")
        let ramRule = AlertRule(name: "内存持续过高", metric: .ramPercent,
                                comparison: .greaterThan, threshold: 90,
                                durationSeconds: 90, action: .notification)

        var evaluator = AlertRuleEvaluator()
        var fired: [AlertTrigger]

        // 第一次超阈：只开始计时，不报
        fired = evaluator.evaluate(rules: [ramRule],
                                   metrics: AlertMetrics(ramPercent: 95), now: t0)
        check("首次超阈不立刻告警", fired.isEmpty)
        checkEqual("记下了 1 条待定", 1, evaluator.pendingCount)

        // 30 秒后仍在超阈：还不够 90 秒
        fired = evaluator.evaluate(rules: [ramRule],
                                   metrics: AlertMetrics(ramPercent: 95),
                                   now: t0.addingTimeInterval(30))
        check("30 秒时仍不告警", fired.isEmpty)

        // 89 秒：差一秒
        fired = evaluator.evaluate(rules: [ramRule],
                                   metrics: AlertMetrics(ramPercent: 95),
                                   now: t0.addingTimeInterval(89))
        check("89 秒时仍不告警", fired.isEmpty)

        // 90 秒：够了
        fired = evaluator.evaluate(rules: [ramRule],
                                   metrics: AlertMetrics(ramPercent: 96),
                                   now: t0.addingTimeInterval(90))
        checkEqual("满 90 秒告警一次", 1, fired.count)
        checkEqual("告警值取当时的读数（不是首次的）", 96.0, fired.first?.observedValue ?? 0)
        checkEqual("告警带的是同一条规则", ramRule.id, fired.first?.rule.id ?? UUID())
        check("告警后重置待定计数", evaluator.pendingCount == 0)

        // ===================================================== 中断重新计时
        print("\n== 条件中断要重新计时 ==")
        var interrupted = AlertRuleEvaluator()
        _ = interrupted.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 95), now: t0)
        _ = interrupted.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 95),
                                 now: t0.addingTimeInterval(60))
        // 第 70 秒掉回阈值以下 → 计时清零
        _ = interrupted.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 50),
                                 now: t0.addingTimeInterval(70))
        check("中断后待定清零", interrupted.pendingCount == 0)
        // 第 71 秒又超阈 → 重新开始计时
        let again = interrupted.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 95),
                                         now: t0.addingTimeInterval(71))
        check("重新超阈不立刻告警", again.isEmpty)
        // 第 71+89 秒：不够
        check("重新计时 89 秒时不报",
              interrupted.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 95),
                                   now: t0.addingTimeInterval(160)).isEmpty)
        // 第 71+90 秒：够了
        checkEqual("重新计满 90 秒才报",
                   1, interrupted.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 95),
                                           now: t0.addingTimeInterval(161)).count)

        // ===================================================== 冷却
        print("\n== 5 分钟冷却 ==")
        var cooled = AlertRuleEvaluator()
        _ = cooled.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 95), now: t0)
        let firstFire = cooled.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 95),
                                        now: t0.addingTimeInterval(90))
        checkEqual("第一次告警发出", 1, firstFire.count)

        // 再持续超阈 90 秒（累计 180 秒），仍在冷却期内 → 不报
        let secondTry = cooled.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 95),
                                        now: t0.addingTimeInterval(180))
        check("冷却期内（90 秒后）即使重新满足持续时间也不报", secondTry.isEmpty)

        // 冷却 299 秒时仍不报
        check("首次告警后 299 秒仍不报",
              cooled.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 95),
                              now: t0.addingTimeInterval(389)).isEmpty)

        // 冷却满 300 秒 + 重新满足持续时间 → 报
        checkEqual("冷却满 5 分钟后可再报",
                   1, cooled.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 95),
                                      now: t0.addingTimeInterval(390)).count)

        // ===================================================== 指标缺失
        print("\n== 指标取不到的处理 ==")
        var missing = AlertRuleEvaluator()
        _ = missing.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 95), now: t0)
        // 中间一拍读不到 RAM
        _ = missing.evaluate(rules: [ramRule], metrics: AlertMetrics(), now: t0.addingTimeInterval(30))
        check("指标读不到时清掉该规则的计时", missing.pendingCount == 0)
        // 恢复后要重新计时，不能拿旧起点直接报
        check("恢复后不立刻告警（不拿陈旧起点误报）",
              missing.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 95),
                               now: t0.addingTimeInterval(31)).isEmpty)
        checkEqual("恢复后重新计满 90 秒才报",
                   1, missing.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 95),
                                       now: t0.addingTimeInterval(121)).count)

        // ===================================================== 禁用 / 删除
        print("\n== 禁用与删除 ==")
        var disabled = AlertRuleEvaluator()
        var offRule = ramRule
        offRule.isEnabled = false
        check("禁用的规则不告警",
              disabled.evaluate(rules: [offRule], metrics: AlertMetrics(ramPercent: 99), now: t0).isEmpty)
        check("禁用的规则不占计时表", disabled.pendingCount == 0)

        var removed = AlertRuleEvaluator()
        _ = removed.evaluate(rules: [ramRule], metrics: AlertMetrics(ramPercent: 95), now: t0)
        _ = removed.evaluate(rules: [], metrics: AlertMetrics(ramPercent: 95),
                             now: t0.addingTimeInterval(10))
        check("规则被删后计时表被清理", removed.pendingCount == 0)

        // ===================================================== 多规则并存
        print("\n== 多规则并存 ==")
        let cpuRule = AlertRule(name: "CPU 过高", metric: .cpuPercent,
                                comparison: .greaterThan, threshold: 90,
                                durationSeconds: 30, action: .both)
        let diskRule = AlertRule(name: "磁盘将满", metric: .diskUsagePercent,
                                 comparison: .greaterThan, threshold: 95,
                                 durationSeconds: 0, action: .email)
        let tempRule = AlertRule(name: "温度过高", metric: .cpuTemperature,
                                 comparison: .greaterThan, threshold: 85,
                                 durationSeconds: 10, action: .notification)

        var multi = AlertRuleEvaluator()
        // 三个指标同时超阈；disk 的 durationSeconds = 0 → 第一拍就报
        let firstTick = multi.evaluate(rules: [cpuRule, diskRule, tempRule],
                                       metrics: AlertMetrics(cpuPercent: 95, ramPercent: 50,
                                                             singleProcessRAMGB: 1,
                                                             cpuTemperature: 88,
                                                             diskUsagePercent: 97),
                                       now: t0)
        checkEqual("durationSeconds=0 的规则第一拍就触发", 1, firstTick.count)
        checkEqual("触发的是磁盘规则", "磁盘将满", firstTick.first?.rule.name ?? "")

        // 30 秒后 CPU 与温度都满足持续时间
        let secondTick = multi.evaluate(rules: [cpuRule, diskRule, tempRule],
                                        metrics: AlertMetrics(cpuPercent: 95, ramPercent: 50,
                                                              singleProcessRAMGB: 1,
                                                              cpuTemperature: 88,
                                                              diskUsagePercent: 97),
                                        now: t0.addingTimeInterval(30))
        checkEqual("30 秒后 CPU 与温度两条一起触发", 2, secondTick.count)
        check("两条告警的规则 id 不同",
              Set(secondTick.map(\.rule.id)).count == 2)
        check("磁盘规则在冷却期内不重复触发",
              !secondTick.contains { $0.rule.name == "磁盘将满" })

        // ===================================================== 指示值边界
        print("\n== 边界与单位 ==")
        var edge = AlertRuleEvaluator()
        let lowDisk = AlertRule(name: "剩余空间", metric: .diskUsagePercent,
                                comparison: .lessThan, threshold: 10,
                                durationSeconds: 0, action: .notification)
        checkEqual("lessThan 方向：5% < 10% 触发",
                   1, edge.evaluate(rules: [lowDisk],
                                    metrics: AlertMetrics(diskUsagePercent: 5), now: t0).count)
        var edge2 = AlertRuleEvaluator()
        check("lessThan 方向：15% 不触发",
              edge2.evaluate(rules: [lowDisk],
                             metrics: AlertMetrics(diskUsagePercent: 15), now: t0).isEmpty)

        var edge3 = AlertRuleEvaluator()
        let singleGB = AlertRule(name: "单进程内存", metric: .singleProcessRAMGB,
                                 comparison: .greaterThan, threshold: 8,
                                 durationSeconds: 0, action: .notification)
        checkEqual("单进程 8.5 GB > 8 GB 触发",
                   1, edge3.evaluate(rules: [singleGB],
                                     metrics: AlertMetrics(singleProcessRAMGB: 8.5), now: t0).count)

        // ===================================================== 持久化往返
        print("\n== 持久化往返（alertRules.v1）==")
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AlertRuleStore.storageKey)
        check("没有记录时读回空列表", AlertRuleStore.load().isEmpty)

        let rules: [AlertRule] = [ramRule, cpuRule, diskRule, tempRule]
        AlertRuleStore.save(rules)
        let loaded = AlertRuleStore.load()
        checkEqual("读回条数一致", rules.count, loaded.count)
        check("读回内容与写入一致", loaded == rules)
        check("读回后 id 保持一致", loaded.map(\.id) == rules.map(\.id))
        check("读回后 operator 保持一致",
              loaded.map(\.operator) == rules.map(\.operator))
        check("读回后 action 保持一致", loaded.map(\.action) == rules.map(\.action))
        check("读回后 durationSeconds 保持一致",
              loaded.map(\.durationSeconds) == rules.map(\.durationSeconds))

        // .sortedKeys：同一份数据反复编码字节必须一致
        var unstable = 0
        var previous: Data?
        for _ in 0..<50 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try? encoder.encode(rules)
            if let previous, let data, previous != data { unstable += 1 }
            previous = data
        }
        checkEqual("50 次编码同一份规则，字节全部一致（.sortedKeys）", 0, unstable)

        // 数据损坏 → 空列表，不崩
        defaults.set(Data("这不是 JSON".utf8), forKey: AlertRuleStore.storageKey)
        check("数据损坏时读回空列表（不崩）", AlertRuleStore.load().isEmpty)

        // 存空列表 → 删 key
        AlertRuleStore.save([])
        check("保存空列表会删掉 key",
              defaults.data(forKey: AlertRuleStore.storageKey) == nil)
        defaults.removeObject(forKey: AlertRuleStore.storageKey)

        // ===================================================== 契约一致性
        print("\n== 契约 §8 的字段与枚举值 ==")
        checkEqual("持久化 key 是 alertRules.v1", "alertRules.v1", AlertRuleStore.storageKey)
        checkEqual("AlertMetric 五个值",
                   ["cpuPercent", "ramPercent", "singleProcessRAMGB",
                    "cpuTemperature", "diskUsagePercent"],
                   AlertMetric.allCases.map(\.rawValue))
        checkEqual("AlertOperator 两个值",
                   ["greaterThan", "lessThan"],
                   AlertOperator.allCases.map(\.rawValue))
        checkEqual("AlertAction 三个值",
                   ["notification", "email", "both"],
                   AlertAction.allCases.map(\.rawValue))

        // 动作组合的语义
        check("notification 不发邮件", AlertAction.notification.wantsNotification
              && !AlertAction.notification.wantsEmail)
        check("email 不发通知", AlertAction.email.wantsEmail
              && !AlertAction.email.wantsNotification)
        check("both 两个都发", AlertAction.both.wantsNotification
              && AlertAction.both.wantsEmail)

        // 编解码时 JSON 的键名必须与契约一致（operator 用反引号声明，键名仍是 operator）
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode([ramRule]),
           let json = String(data: data, encoding: .utf8) {
            for field in ["id", "name", "isEnabled", "metric", "operator",
                          "threshold", "durationSeconds", "action"] {
                check("JSON 里含字段 \(field)", json.contains("\"\(field)\""))
            }
        } else {
            check("规则能编码成 JSON", false)
        }

        // ===================================================== 观察者机制
        //
        // 为什么单独测：触发事件有两个消费者 —— 监控协调器用 `onTrigger`
        // 派发系统通知与邮件，告警规则页用观察者记「最近的触发」。
        // 如果只有一个闭包，界面那边一设就把通知派发顶掉了 ——
        // 症状是规则能触发、界面能看见，但通知发不出去，很难查。
        print("\n== 触发观察者与 onTrigger 并存 ==")

        let engine = AlertRuleEngine.shared
        // 两条规则：第二条用来绕开第一条的 5 分钟冷却
        // （冷却按规则 id 记，同一条规则冷却期内不会二次触发）。
        let obsCpuRule = AlertRule(
            name: "观察者测试-CPU",
            metric: .cpuPercent,
            comparison: .greaterThan,
            threshold: 50,
            durationSeconds: 0,
            action: .notification)
        let obsRamRule = AlertRule(
            name: "观察者测试-内存",
            metric: .ramPercent,
            comparison: .greaterThan,
            threshold: 50,
            durationSeconds: 0,
            action: .notification)
        engine.setRules([obsCpuRule, obsRamRule])

        var observerHits = 0
        var mainHits = 0
        let token = engine.addTriggerObserver { _ in observerHits += 1 }
        engine.onTrigger = { _ in mainHits += 1 }

        engine.metricsProvider = { AlertMetrics(cpuPercent: 90, ramPercent: 10) }
        engine.evaluateNow()

        check("观察者收到了触发", observerHits == 1, "收到 \(observerHits) 次")
        check("onTrigger 也收到了触发（没被观察者顶掉）", mainHits == 1, "收到 \(mainHits) 次")

        // 同一条规则在冷却期内不再触发
        engine.metricsProvider = { AlertMetrics(cpuPercent: 95, ramPercent: 10) }
        engine.evaluateNow()
        check("冷却期内同一条规则不重复触发", mainHits == 1, "收到 \(mainHits) 次")

        // 移除观察者后，另一条规则仍能触发，而观察者不再收到
        engine.removeTriggerObserver(token)
        engine.metricsProvider = { AlertMetrics(cpuPercent: 95, ramPercent: 90) }
        engine.evaluateNow()
        check("移除观察者后观察者不再收到", observerHits == 1, "收到 \(observerHits) 次")
        check("onTrigger 仍继续收到", mainHits == 2, "收到 \(mainHits) 次")

        // 清理：把规则与回调还原，别影响后续用例
        engine.setRules([])
        engine.onTrigger = nil
        engine.metricsProvider = nil
        defaults.removeObject(forKey: AlertRuleStore.storageKey)

        // ===================================================== 阈值校验
        //
        // 温度阈值不许超过 90°C 这条限制已经被去掉了。
        // 90°C 兜底接管的是**风扇转速**（把风扇拉到最大），跟告警是两条独立的路：
        // 兜底生效的时候告警照样该报，「温度已经到 90 了」正是最该报的时刻。
        print("\n== 阈值校验：温度阈值不受 90°C 兜底限制 ==")

        let hotRule = AlertRule(
            name: "温度过高",
            metric: .cpuTemperature,
            comparison: .greaterThan,
            threshold: 95,
            durationSeconds: 30,
            action: .notification)
        check("温度阈值 95°C 可以保存（兜底管风扇，不管告警）",
              AlertRule.validationError(for: hotRule) == nil,
              AlertRule.validationError(for: hotRule) ?? "")

        let hotterRule = AlertRule(
            name: "温度更高",
            metric: .cpuTemperature,
            comparison: .greaterThan,
            threshold: 120,
            durationSeconds: 10,
            action: .both)
        check("温度阈值 120°C 也可以保存",
              AlertRule.validationError(for: hotterRule) == nil,
              AlertRule.validationError(for: hotterRule) ?? "")

        // 反过来，真正该拦的还是得拦
        check("空名称被拦",
              AlertRule.validationError(for: AlertRule(
                name: "  ", metric: .cpuPercent, comparison: .greaterThan,
                threshold: 90, durationSeconds: 10)) != nil)
        check("负阈值被拦",
              AlertRule.validationError(for: AlertRule(
                name: "负数", metric: .cpuPercent, comparison: .greaterThan,
                threshold: -1, durationSeconds: 10)) != nil)

        // ===================================================== 汇总
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
