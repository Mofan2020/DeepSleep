//
//  test-keepalive-url.swift
//  Deep Sleep 回归测试
//
//  验证 AI 保活模块里那些「拼错一次就整条链路失效」的东西：
//  - URL 拼接（baseurl 带不带尾斜杠、带不带 /v1、空地址）
//  - 默认请求模板非空且可还原
//  - 任务模型的 Codable 往返
//  - 间隔分钟数的边界钳制
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
        checkEqual("模板内容是 ping", "ping", KeepAliveDefaults.defaultRequestTemplate)
        check("新任务默认用默认模板",
              KeepAliveTask().requestTemplate == KeepAliveDefaults.defaultRequestTemplate)
        check("新任务默认间隔 240 分钟",
              KeepAliveTask().intervalMinutes == 240)
        check("默认间隔在合法区间内",
              KeepAliveDefaults.defaultIntervalMinutes >= KeepAliveDefaults.minIntervalMinutes
                && KeepAliveDefaults.defaultIntervalMinutes <= KeepAliveDefaults.maxIntervalMinutes)

        // --------------------------------------------------- Codable 往返
        print("\n== 任务模型 Codable 往返 ==")
        let original = KeepAliveTask(
            id: UUID(),
            name: "Claude Code",
            baseURL: "https://api.anthropic.com",
            format: .anthropic,
            model: "claude-sonnet-4-5",
            apiKeyRef: "keepalive.1234",
            intervalMinutes: 240,
            requestTemplate: "ping",
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
            checkEqual("往返后间隔不变", 240, decoded.intervalMinutes)
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

        // ------------------------------------------------------- 间隔钳制
        print("\n== 间隔分钟数边界钳制 ==")
        checkEqual("0 → 1", 1, KeepAliveTask.clampedInterval(0))
        checkEqual("-5 → 1", 1, KeepAliveTask.clampedInterval(-5))
        checkEqual("1 → 1", 1, KeepAliveTask.clampedInterval(1))
        checkEqual("240 → 240", 240, KeepAliveTask.clampedInterval(240))
        checkEqual("1440 → 1440", 1440, KeepAliveTask.clampedInterval(1440))
        checkEqual("1441 → 1440", 1440, KeepAliveTask.clampedInterval(1441))
        checkEqual("99999 → 1440", 1440, KeepAliveTask.clampedInterval(99999))

        var over = KeepAliveTask()
        over.intervalMinutes = 5000
        checkEqual("clamped 副本把 5000 压到 1440", 1440, over.clamped.intervalMinutes)
        checkEqual("clamped 副本保留其它字段", over.id, over.clamped.id)

        // ------------------------------------------------------- 下次到期
        print("\n== 下次到期时间 ==")
        var task = KeepAliveTask()
        task.intervalMinutes = 60
        task.createdAt = Date(timeIntervalSince1970: 1_000_000)
        task.lastRunAt = nil
        let firstDue = task.nextDueDate()
        checkEqual("没有上次发送时锚点是创建时间", 1_000_000 + 3600, firstDue.timeIntervalSince1970)

        task.lastRunAt = Date(timeIntervalSince1970: 1_000_500)
        let secondDue = task.nextDueDate()
        checkEqual("有上次发送时锚点是上次发送", 1_000_500 + 3600, secondDue.timeIntervalSince1970)

        // -------------------------------------------------------- 汇总
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
