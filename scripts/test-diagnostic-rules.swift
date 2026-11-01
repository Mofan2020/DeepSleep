//
//  test-diagnostic-rules.swift
//  Deep Sleep
//
//  设备诊断**判定层**的自测。测的是真实源码 Shared/DiagnosticModel.swift。
//
//  这一层是纯逻辑（只依赖 Foundation），所以这里既不启应用、也不连特权助手、
//  更不碰真机状态 —— 全部靠构造「事实」来驱动。
//
//  运行： swiftc -parse-as-library Shared/DiagnosticModel.swift \
//                    scripts/test-diagnostic-rules.swift -o /tmp/t_diag && /tmp/t_diag
//

import Foundation

@main
struct DiagnosticRuleTests {

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

        /// 浮点比较。直接用 == 比 Double 会在精度末位上随机失败。
        func checkClose(_ name: String, _ lhs: Double, _ rhs: Double, tolerance: Double = 0.001) {
            if abs(lhs - rhs) <= tolerance {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)：期望 \(rhs)（±\(tolerance)），实际 \(lhs)")
                failures += 1
            }
        }

        /// 按 id 找一项。
        func item(_ report: DiagnosticReport, _ id: String) -> DiagnosticItem? {
            for section in report.sections {
                if let found = section.items.first(where: { $0.id == id }) { return found }
            }
            return nil
        }

        // MARK: - 严重度排序

        print("\n== 严重度排序 ==")

        check("info < warning", DiagnosticSeverity.info < DiagnosticSeverity.warning)
        check("warning < critical", DiagnosticSeverity.warning < DiagnosticSeverity.critical)
        check("info < critical", DiagnosticSeverity.info < DiagnosticSeverity.critical)
        checkEqual("critical 的原始值最大", DiagnosticSeverity.critical.rawValue, 2)

        // Comparable 是升序（info 最轻）。界面上的展示顺序由
        // DiagnosticSection.problems 单独按降序排 —— 这两件事别搞混。
        let sorted: [DiagnosticSeverity] = [.critical, .info, .warning].sorted()
        checkEqual("升序排序：info → warning → critical", sorted, [.info, .warning, .critical])
        let descending: [DiagnosticSeverity] = [.critical, .info, .warning].sorted(by: >)
        checkEqual("降序排序：critical 在前", descending, [.critical, .warning, .info])

        checkEqual("中文标签：正常", DiagnosticSeverity.info.label, "正常")
        checkEqual("中文标签：注意", DiagnosticSeverity.warning.label, "注意")
        checkEqual("中文标签：严重", DiagnosticSeverity.critical.label, "严重")

        // 分组内问题项按严重度排序，正常项在后。
        let mixed = DiagnosticSection(id: "s", title: "组", icon: "cpu", items: [
            DiagnosticItem(id: "a", title: "正常项", value: "v", severity: .info),
            DiagnosticItem(id: "b", title: "轻微", value: "v", severity: .warning),
            DiagnosticItem(id: "c", title: "严重", value: "v", severity: .critical)
        ])
        checkEqual("问题项里 critical 排最前", mixed.problems.map(\.id), ["c", "b"])
        checkEqual("正常项单独归类", mixed.normalItems.map(\.id), ["a"])
        checkEqual("展示顺序 = 问题在前正常在后", mixed.displayItems.map(\.id), ["c", "b", "a"])

        // MARK: - 坏事实产出问题项

        print("\n== 坏事实 → 问题项 ==")

        var bad = DiagnosticFacts()
        bad.swapUsedPercent = .value(92)
        bad.volumes = .value([
            DiagnosticVolumeFact(name: "系统卷（Macintosh HD）",
                                 mountPoint: "/",
                                 totalBytes: 500_000_000_000,
                                 freeBytes: 15_000_000_000)   // 剩 3%
        ])
        bad.sipEnabled = .value(false)
        bad.memoryUsedPercent = .value(95)
        bad.hottestTemperatureCelsius = .value(95)
        bad.loadAverage = .value([16.0, 15.0, 9.0])
        bad.cpuCores = .value(8)
        bad.gatekeeperEnabled = .value(false)
        bad.fileVaultEnabled = .value(false)
        bad.firewallEnabled = .value(false)
        bad.battery = .value(DiagnosticBatteryFact(cycleCount: 700,
                                                    currentCapacityPercent: 80,
                                                    fullChargeCapacity: 3500,
                                                    designCapacity: 5000,
                                                    temperatureCelsius: 30))
        bad.uptimeSeconds = .value(40 * 86400)
        bad.powerAssertions = .value([
            "生效的断言类型：PreventSystemSleep",
            "PreventSystemSleep · some.app（pid 1234）"
        ])

        let badReport = DiagnosticEvaluator.evaluate(bad, generatedAt: Date(timeIntervalSince1970: 0))

        checkEqual("交换空间 92% 是严重", item(badReport, "hw.swap")?.severity, .critical)
        check("交换空间 92% 带建议",
              !(item(badReport, "hw.swap")?.suggestion ?? "").isEmpty,
              item(badReport, "hw.swap")?.suggestion ?? "")
        checkEqual("根卷剩 3% 是严重", item(badReport, "storage.volume.0")?.severity, .critical)
        check("根卷剩 3% 的建议提到清理",
              (item(badReport, "storage.volume.0")?.suggestion ?? "").contains("清理"),
              item(badReport, "storage.volume.0")?.suggestion ?? "")
        checkEqual("SIP 关闭是严重", item(badReport, "sec.sip")?.severity, .critical)
        check("SIP 关闭的建议提到恢复模式",
              (item(badReport, "sec.sip")?.suggestion ?? "").contains("恢复"),
              item(badReport, "sec.sip")?.suggestion ?? "")
        checkEqual("内存 95% 是严重", item(badReport, "hw.memory_usage")?.severity, .critical)
        checkEqual("温度 95°C 是严重", item(badReport, "hw.temperature")?.severity, .critical)
        checkEqual("Gatekeeper 关闭是需要注意", item(badReport, "sec.gatekeeper")?.severity, .warning)
        checkEqual("FileVault 关闭是需要注意", item(badReport, "sec.filevault")?.severity, .warning)
        checkEqual("防火墙关闭是需要注意", item(badReport, "sec.firewall")?.severity, .warning)
        checkEqual("电池健康 70% 是需要注意", item(badReport, "storage.battery")?.severity, .warning)
        checkEqual("开机 40 天是需要注意", item(badReport, "sw.uptime")?.severity, .warning)
        checkEqual("负载 16 / 8 核是需要注意", item(badReport, "proc.load")?.severity, .warning)

        checkEqual("电源断言带 PreventSystemSleep 时是需要注意",
                   item(badReport, "sec.assertions")?.severity, .warning)

        check("所有问题项都有非空建议", badReport.allItems
            .filter { $0.severity != .info }
            .allSatisfy { !($0.suggestion ?? "").isEmpty })
        check("问题项数量 > 0", badReport.problemCount > 0, "实际 \(badReport.problemCount)")

        // MARK: - 正常事实不产问题项

        print("\n== 正常事实 → 无问题 ==")

        var good = DiagnosticFacts()
        good.modelName = .value("Mac14,7")
        good.chipName = .value("Apple M2")
        good.cpuCores = .value(8)
        good.memoryBytes = .value(8_589_934_592)
        good.hottestTemperatureCelsius = .value(45.5)
        good.memoryUsedPercent = .value(40)
        good.swapUsedPercent = .value(5)
        good.volumes = .value([
            DiagnosticVolumeFact(name: "系统卷（Macintosh HD）",
                                 mountPoint: "/",
                                 totalBytes: 500_000_000_000,
                                 freeBytes: 250_000_000_000)
        ])
        good.battery = .value(DiagnosticBatteryFact(cycleCount: 194,
                                                    currentCapacityPercent: 92,
                                                    fullChargeCapacity: 4313,
                                                    designCapacity: 5103,
                                                    temperatureCelsius: 31.9))
        good.osVersion = .value("27.2")
        good.osBuild = .value("26B118")
        good.kernelVersion = .value("27.2.0")
        good.uptimeSeconds = .value(3 * 86400)
        good.consoleUser = .value("mofan")
        good.currentUser = .value("mofan")
        good.hostName = .value("MacBook Pro")
        good.sipEnabled = .value(true)
        good.gatekeeperEnabled = .value(true)
        good.fileVaultEnabled = .value(true)
        good.firewallEnabled = .value(true)
        good.proxyEnabled = .value(false)
        good.powerAssertions = .value(["生效的断言类型：PreventUserIdleDisplaySleep"])
        good.energySettings = .value("电池：系统睡眠 1 分钟 · 显示器 2 分钟")
        good.launchAgentsCount = .value(12)
        good.launchDaemonsCount = .value(11)
        good.quarantinedFileCount = .value(3)
        good.loadAverage = .value([1.2, 1.0, 0.9])
        good.topMemoryProcesses = .value([
            DiagnosticProcessFact(pid: 100, name: "Safari", rssBytes: 400_000_000)
        ])

        let goodReport = DiagnosticEvaluator.evaluate(good, generatedAt: Date(timeIntervalSince1970: 0))

        checkEqual("正常事实不产问题项", goodReport.problemCount, 0)
        checkEqual("严重项数为 0", goodReport.criticalCount, 0)
        checkEqual("注意项数为 0", goodReport.warningCount, 0)
        check("总结里写明全部正常", goodReport.summary.contains("全部正常"), goodReport.summary)
        checkEqual("顶部结论是「未发现需要注意的问题」", goodReport.headline, "未发现需要注意的问题")
        check("正常项仍然全部列出来（不藏数据）",
              goodReport.allItems.count >= 20, "实际 \(goodReport.allItems.count)")
        check("正常项不带建议",
              goodReport.allItems.filter { $0.severity == .info }
                  .allSatisfy { $0.suggestion == nil })

        // 断言里含 Deep Sleep 自己的助手时，措辞要跟着变 ——
        // 不能叫用户去退出自己正在用的应用。
        var ownHelper = good
        ownHelper.powerAssertions = .value([
            "生效的断言类型：PreventSystemSleep",
            "PreventSystemSleep · com.skyc8266.deepsleep.helper（pid 42385）"
        ])
        let ownReport = DiagnosticEvaluator.evaluate(ownHelper, generatedAt: Date(timeIntervalSince1970: 0))
        check("含自身助手时仍然是需要注意",
              item(ownReport, "sec.assertions")?.severity == .warning)
        check("含自身助手时措辞提到「属正常行为」",
              (item(ownReport, "sec.assertions")?.suggestion ?? "").contains("属正常行为"),
              item(ownReport, "sec.assertions")?.suggestion ?? "")

        // MARK: - 读不到的事实

        print("\n== 读不到的事实 ==")

        var missing = DiagnosticFacts()
        missing.modelName = .unavailable(reason: "sysctl 不可用")
        missing.volumes = .unavailable(reason: "没有权限")
        missing.swapUsedPercent = .unavailable(reason: "超时")
        let missingReport = DiagnosticEvaluator.evaluate(missing, generatedAt: Date(timeIntervalSince1970: 0))

        check("读不到的事实不会变成问题项",
              missingReport.allItems.filter { $0.severity != .info }.isEmpty)
        check("读不到时值里写明原因",
              (item(missingReport, "hw.identity")?.value ?? "").contains("无法读取"),
              item(missingReport, "hw.identity")?.value ?? "")
        check("读不到的原因带上了",
              (item(missingReport, "storage.volumes")?.value ?? "").contains("没有权限"),
              item(missingReport, "storage.volumes")?.value ?? "")
        check("完全没采集时报告仍有内容", !missingReport.sections.isEmpty)
        check("完全没采集时总结仍是人话",
              !missingReport.summary.isEmpty, missingReport.summary)

        // MARK: - 汇总计数

        print("\n== 汇总计数 ==")

        checkEqual("问题总数 = 严重 + 注意",
                  badReport.problemCount,
                  badReport.criticalCount + badReport.warningCount)
        check("总结里含问题计数",
              badReport.summary.contains("\(badReport.problemCount)"),
              badReport.summary)
        check("总结里含严重项数",
              badReport.summary.contains("\(badReport.criticalCount)"),
              badReport.summary)
        checkEqual("全部条目数 = 各组之和",
                  badReport.allItems.count,
                  badReport.sections.reduce(0) { $0 + $1.items.count })
        check("顶部结论含问题数",
              badReport.headline.contains("\(badReport.problemCount)"),
              badReport.headline)

        // MARK: - 报告全文

        print("\n== 报告全文 ==")

        let text = badReport.plainText
        check("全文含标题", text.contains("Deep Sleep 设备诊断报告"))
        check("全文含生成时间", text.contains("生成时间"))
        check("全文含结论", text.contains("结论"))
        check("全文含分组名", text.contains("【硬件】"))
        check("全文含处理建议", text.contains("处理建议"))
        check("全文含严重度标签", text.contains("严重"))
        check("全文非空", text.count > 200, "长度 \(text.count)")

        // MARK: - 存档

        print("\n== 存档 ==")

        let archived = DiagnosticReportArchive.encode(badReport)
        check("报告能编码成存档", archived != nil)
        if let archived {
            let restored = DiagnosticReportArchive.decode(archived)
            check("存档能解码回来", restored != nil)
            checkEqual("解码后分组数一致", restored?.sections.count ?? -1, badReport.sections.count)
            checkEqual("解码后问题数一致", restored?.problemCount ?? -1, badReport.problemCount)
            checkEqual("解码后全文一致", restored?.plainText ?? "", badReport.plainText)
        }
        check("损坏的存档解不出来", DiagnosticReportArchive.decode(Data([0x00, 0x01, 0x02])) == nil)
        check("空存档解不出来", DiagnosticReportArchive.decode(Data()) == nil)
        check("非 JSON 的存档解不出来",
              DiagnosticReportArchive.decode("这不是 JSON".data(using: .utf8)!) == nil)

        // 缺字段的存档：解码要回落默认值，不能整个炸掉。
        let partial = """
        {"generatedAt": 1000, "sections": [{"id": "x", "title": "半截的组", "items": \
        [{"id": "y", "title": "半截的项"}]}], "summary": "半截"}
        """
        if let data = partial.data(using: .utf8),
           let decoded = DiagnosticReportArchive.decode(data) {
            checkEqual("缺字段时分组仍解出来", decoded.sections.count, 1)
            checkEqual("缺字段时条目仍解出来", decoded.sections.first?.items.count ?? -1, 1)
            checkEqual("缺字段时严重度回落成正常",
                       decoded.sections.first?.items.first?.severity ?? .critical, .info)
            checkEqual("缺字段时值回落成空串",
                       decoded.sections.first?.items.first?.value ?? "x", "")
            check("缺字段时建议回落成 nil",
                  decoded.sections.first?.items.first?.suggestion == nil,
                  decoded.sections.first?.items.first?.suggestion ?? "<nil>")
        } else {
            check("缺字段的存档能解码", false)
        }

        // MARK: - 工具函数

        print("\n== 工具函数 ==")

        checkEqual("字节格式化（1024 进制）", DiagnosticEvaluator.formatBytes(1_073_741_824), "1.0 GB")
        checkEqual("字节格式化（内存容量）", DiagnosticEvaluator.formatBytes(8_589_934_592), "8.0 GB")
        checkEqual("字节格式化（字节档不显示小数）", DiagnosticEvaluator.formatBytes(512), "512 B")
        checkEqual("时长格式化（天）", DiagnosticEvaluator.formatDuration(3 * 86400 + 3600 * 2 + 60 * 5),
                   "3 天 2 小时 5 分")
        checkEqual("时长格式化（小时）", DiagnosticEvaluator.formatDuration(3600 * 5 + 60 * 12),
                   "5 小时 12 分")
        checkEqual("时长格式化（分钟）", DiagnosticEvaluator.formatDuration(125), "2 分")
        checkClose("电池健康度算法", DiagnosticBatteryFact(cycleCount: 1, currentCapacityPercent: 50,
                                                            fullChargeCapacity: 4309, designCapacity: 5103,
                                                            temperatureCelsius: nil).healthPercent ?? 0,
                   4309.0 / 5103.0 * 100)
        check("电池缺设计容量时健康度为 nil",
              DiagnosticBatteryFact(cycleCount: 1, currentCapacityPercent: 50,
                                   fullChargeCapacity: 4309, designCapacity: nil,
                                   temperatureCelsius: nil).healthPercent == nil)
        checkClose("卷剩余空间百分比",
                   DiagnosticVolumeFact(name: "x", mountPoint: "/", totalBytes: 100, freeBytes: 25).freePercent ?? 0,
                   25.0)
        check("卷总量为 0 时百分比为 nil",
              DiagnosticVolumeFact(name: "x", mountPoint: "/", totalBytes: 0, freeBytes: 0).freePercent == nil)

        // MARK: - 事实类型

        print("\n== 事实类型 ==")

        check("值型事实有值", DiagnosticFact.value(42).value == 42)
        check("值型事实没有失败原因", DiagnosticFact.value(42).reason == nil)
        check("不可用事实没有值", DiagnosticFact<String>.unavailable(reason: "坏了").value == nil)
        checkEqual("不可用事实保留原因", DiagnosticFact<String>.unavailable(reason: "坏了").reason, "坏了")
        check("不可用事实不算可用", !DiagnosticFact<String>.unavailable(reason: "坏了").isAvailable)
        check("值型事实算可用", DiagnosticFact.value(42).isAvailable)

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
