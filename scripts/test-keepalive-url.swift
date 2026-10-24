//
//  test-keepalive-url.swift
//  Deep Sleep 回归测试
//
//  验证 AI 保活模块里那些「拼错一次就整条链路失效」的东西：
//  - URL 拼接（baseurl 带不带尾斜杠、带不带 /v1、空地址）
//  - 默认请求模板非空且可还原
//  - 任务模型的 Codable 往返
//  - 时刻与星期的归一化
//  - 自定义解码必须过归一化（手改过的存储不能原样进运行时）
//
//  运行：
//  swiftc DeepSleep/AIKeepAlive/KeepAliveModels.swift scripts/test-keepalive-url.swift \
//         -o /tmp/ka-test && /tmp/ka-test
//

import Foundation

@main
struct KeepAliveTests {

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

        // ---------------------------------------------------------- URL 拼接
        print("== URL 拼接：OpenAI 端点 ==")
        checkEqual(
            "不带尾斜杠 → 补 /v1",
            "https://api.openai.com/v1/chat/completions",
            KeepAliveEndpoint.chatURL(baseURL: "https://api.openai.com", format: .openAI)?.absoluteString ?? ""
        )
        checkEqual(
            "带尾斜杠 → 不多补斜杠",
            "https://api.openai.com/v1/chat/completions",
            KeepAliveEndpoint.chatURL(baseURL: "https://api.openai.com/", format: .openAI)?.absoluteString ?? ""
        )
        checkEqual(
            "多个尾斜杠 → 全部去掉",
            "https://api.openai.com/v1/chat/completions",
            KeepAliveEndpoint.chatURL(baseURL: "https://api.openai.com///", format: .openAI)?.absoluteString ?? ""
        )
        checkEqual(
            "已带 /v1 → 不重复拼",
            "https://api.openai.com/v1/chat/completions",
            KeepAliveEndpoint.chatURL(baseURL: "https://api.openai.com/v1", format: .openAI)?.absoluteString ?? ""
        )
        checkEqual(
            "已带 /v1/ → 归一化后不重复拼",
            "https://api.openai.com/v1/chat/completions",
            KeepAliveEndpoint.chatURL(baseURL: "https://api.openai.com/v1/", format: .openAI)?.absoluteString ?? ""
        )
        checkEqual(
            "已带 /v1 又带尾斜杠 → 归一化后不重复拼",
            "https://api.openai.com/v1/chat/completions",
            KeepAliveEndpoint.chatURL(baseURL: "https://api.openai.com/v1//", format: .openAI)?.absoluteString ?? ""
        )
        checkEqual(
            "带子路径 → 保留路径",
            "https://example.com/proxy/v1/chat/completions",
            KeepAliveEndpoint.chatURL(baseURL: "https://example.com/proxy", format: .openAI)?.absoluteString ?? ""
        )
        checkEqual(
            "前后空白 → 去掉",
            "https://api.openai.com/v1/chat/completions",
            KeepAliveEndpoint.chatURL(baseURL: "  https://api.openai.com  ", format: .openAI)?.absoluteString ?? ""
        )

        print("\n== URL 拼接：Anthropic 端点 ==")
        checkEqual(
            "不带 /v1 → 补 /v1/messages",
            "https://api.anthropic.com/v1/messages",
            KeepAliveEndpoint.chatURL(baseURL: "https://api.anthropic.com", format: .anthropic)?.absoluteString ?? ""
        )
        checkEqual(
            "已带 /v1 → 不重复拼",
            "https://api.anthropic.com/v1/messages",
            KeepAliveEndpoint.chatURL(baseURL: "https://api.anthropic.com/v1", format: .anthropic)?.absoluteString ?? ""
        )
        checkEqual(
            "已带 /v1/ → 归一化后不重复拼",
            "https://api.anthropic.com/v1/messages",
            KeepAliveEndpoint.chatURL(baseURL: "https://api.anthropic.com/v1/", format: .anthropic)?.absoluteString ?? ""
        )
        checkEqual(
            "国内站带 /v1/ 也不重复拼",
            "https://api.anthropic.cn/v1/messages",
            KeepAliveEndpoint.chatURL(baseURL: "https://api.anthropic.cn/v1/", format: .anthropic)?.absoluteString ?? ""
        )

        print("\n== URL 拼接：模型列表端点 ==")
        checkEqual(
            "OpenAI 模型列表",
            "https://api.openai.com/v1/models",
            KeepAliveEndpoint.modelsURL(baseURL: "https://api.openai.com", format: .openAI)?.absoluteString ?? ""
        )
        checkEqual(
            "Anthropic 模型列表",
            "https://api.anthropic.com/v1/models",
            KeepAliveEndpoint.modelsURL(baseURL: "https://api.anthropic.com", format: .anthropic)?.absoluteString ?? ""
        )
        checkEqual(
            "已带 /v1 的模型列表",
            "https://api.openai.com/v1/models",
            KeepAliveEndpoint.modelsURL(baseURL: "https://api.openai.com/v1", format: .openAI)?.absoluteString ?? ""
        )

        print("\n== URL 拼接：非法输入 ==")
        check("空 baseurl → nil", KeepAliveEndpoint.chatURL(baseURL: "", format: .openAI) == nil)
        check("纯空白 baseurl → nil", KeepAliveEndpoint.chatURL(baseURL: "   ", format: .openAI) == nil)
        check("缺 scheme 的 baseurl → nil",
              KeepAliveEndpoint.chatURL(baseURL: "api.openai.com", format: .openAI) == nil)
        check("空 baseurl 的模型列表 → nil",
              KeepAliveEndpoint.modelsURL(baseURL: "", format: .anthropic) == nil)
        checkEqual("空 baseurl 的归一化结果为空串", "", KeepAliveEndpoint.normalizedBaseURL(""))

        // ------------------------------------------------------- 默认模板
        print("\n== 默认请求模板 ==")
        check("模板非空", !KeepAliveDefaults.defaultRequestTemplate.isEmpty)
        check(
            "模板说清了要什么（不是孤零零一个 ping）",
            KeepAliveDefaults.defaultRequestTemplate.contains("回复")
                && KeepAliveDefaults.defaultRequestTemplate.contains("ping"),
            "实际 \(KeepAliveDefaults.defaultRequestTemplate)"
        )
        check("新任务默认用默认模板",
              KeepAliveTask().requestTemplate == KeepAliveDefaults.defaultRequestTemplate)
        check("新任务默认是 09:00 与 14:00",
              KeepAliveTask().schedule.times.map(\.display) == ["09:00", "14:00"])
        check("新任务默认工作日运行",
              KeepAliveTask().schedule.weekdays == [2, 3, 4, 5, 6])
        check("每天时刻上限是 24",
              KeepAliveDefaults.maxTimesPerDay == 24)

        // --------------------------------------------------- Codable 往返
        print("\n== 任务模型 Codable 往返 ==")
        let original = KeepAliveTask(
            id: UUID(),
            name: "Claude Code",
            baseURL: "https://api.anthropic.com",
            format: .anthropic,
            model: "claude-sonnet-4-5",
            apiKeyRef: "keepalive.1234",
            schedule: KeepAliveSchedule(
                times: [KeepAliveTime(hour: 8, minute: 30), KeepAliveTime(hour: 20, minute: 0)],
                weekdays: [2, 3, 4, 5, 6]
            ),
            requestTemplate: KeepAliveDefaults.defaultRequestTemplate,
            isEnabled: true,
            lastRunAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastResult: "已发送",
            createdAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        do {
            let encoded = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(KeepAliveTask.self, from: encoded)
            check("往返后相等", decoded == original)
            checkEqual("往返后 id 不变", original.id, decoded.id)
            checkEqual("往返后格式不变", KeepAliveFormat.anthropic, decoded.format)
            checkEqual("往返后时刻不变", ["08:30", "20:00"], decoded.schedule.times.map(\.display))
            checkEqual("往返后星期不变", [2, 3, 4, 5, 6], decoded.schedule.weekdays.sorted())
            check("往返后 API Key 引用仍是引用名",
                  decoded.apiKeyRef == "keepalive.1234")
            check("往返后没有出现明文 key",
                  !String(data: encoded, encoding: .utf8)!.contains("sk-"))

            // 列表往返
            let list = [original, KeepAliveTask(name: "第二个")]
            let listData = try JSONEncoder().encode(list)
            let listBack = try JSONDecoder().decode([KeepAliveTask].self, from: listData)
            check("列表往返后数量一致", listBack.count == list.count)
            check("列表往返后内容一致", listBack == list)
        } catch {
            check("Codable 往返不抛错", false, error.localizedDescription)
        }

        // --------------------------------------- 解码必须过归一化
        print("\n== 解码必须过归一化（手改过的存储） ==")
        // 重复时刻 + 非法星期 + 非法时分。
        let dirtySchedule = """
        {"times":[{"hour":25,"minute":70},{"hour":9,"minute":0},{"hour":9,"minute":0}],
         "weekdays":[2,99,0]}
        """
        let dirty = try! JSONDecoder().decode(
            KeepAliveSchedule.self,
            from: Data(dirtySchedule.utf8)
        )
        checkEqual("重复时刻被去掉", 2, dirty.times.count)
        checkEqual(
            "时刻按升序排",
            ["09:00", "23:59"],
            dirty.times.map(\.display)
        )
        checkEqual("非法星期被剔掉", [2], dirty.weekdays.sorted())

        // 非法时分被钳制。
        let clampedTime = try! JSONDecoder().decode(
            KeepAliveTime.self,
            from: Data(#"{"hour":30,"minute":90}"#.utf8)
        )
        checkEqual("小时钳到 23", 23, clampedTime.hour)
        checkEqual("分钟钳到 59", 59, clampedTime.minute)

        // 空数组也要能解出来。
        let emptySchedule = try! JSONDecoder().decode(
            KeepAliveSchedule.self,
            from: Data(#"{"times":[],"weekdays":[]}"#.utf8)
        )
        checkEqual("空时刻", 0, emptySchedule.times.count)
        checkEqual("空星期", 0, emptySchedule.weekdays.count)

        // 缺字段也要能解出来（老存储）。
        let missingFields = try! JSONDecoder().decode(
            KeepAliveSchedule.self,
            from: Data("{}".utf8)
        )
        checkEqual("缺字段 → 空时刻", 0, missingFields.times.count)
        checkEqual("缺字段 → 空星期", 0, missingFields.weekdays.count)

        // ------------------------------------------------------- 归一化副本
        print("\n== 归一化副本 ==")
        var over = KeepAliveTask()
        over.schedule = KeepAliveSchedule(
            times: (0..<50).map { KeepAliveTime(minutesFromMidnight: $0 * 20) },
            weekdays: [1, 2, 3, 4, 5, 6, 7, 99]
        )
        checkEqual(
            "clamped 副本把时刻数量压到上限",
            KeepAliveDefaults.maxTimesPerDay,
            over.clamped.schedule.times.count
        )
        checkEqual(
            "clamped 副本剔掉非法星期",
            [1, 2, 3, 4, 5, 6, 7],
            over.clamped.schedule.weekdays.sorted()
        )
        checkEqual("clamped 副本保留 id", over.id, over.clamped.id)

        var blank = KeepAliveTask()
        blank.requestTemplate = "   "
        checkEqual(
            "clamped 副本把空白模板换成默认模板",
            KeepAliveDefaults.defaultRequestTemplate,
            blank.clamped.requestTemplate
        )

        // -------------------------------------------------------- 汇总
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
