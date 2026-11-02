//
//  test-ui-cleanup.swift
//  DeepSleep
//
//  v1.11.3 界面清理的回归护栏。
//
//  这一版做了两件事，都很容易在后续改动里悄悄退回去：
//
//  1. **删掉机制说明。** 用户原话是「机制说明 AI 味很浓，用户也不会仔细看」。
//     删掉之后就没人再盯着了 —— 下次谁觉得「这里不写清楚用户会不懂」，
//     就又加回来。所以要把「这些页面上不许有说明卡」写成断言。
//
//  2. **删除类操作加二次确认。** 同样，删掉一个二次确认没人会发现，
//     直到用户误删了保活任务、连带丢了钥匙串里的 API Key。
//
//  判据为什么用「字符串出现」而不是解析 Swift AST：Swift 的语法树 API
// 在命令行脚本里用起来笨重，仓库里其它 UI 测试（test-dashboard-layout.swift、
// test-toolbox-layout.swift）也是同一路子 —— 简单、够用、不会自己坏掉。
//

import Foundation

// MARK: - 断言工具

/// 断言计数。用引用而不是全局变量，好让 @main 里读得到。
final class Counters {
    static var passed = 0
    static var failed = 0

    static func check(_ condition: Bool, _ label: String) {
        if condition {
            passed += 1
            print("[通过] \(label)")
        } else {
            failed += 1
            print("[失败] \(label)")
        }
    }

    static func checkContains(_ haystack: String, _ needle: String, _ label: String) {
        check(haystack.contains(needle), "\(label)（期望包含「\(needle)」）")
    }

    static func checkAbsent(_ haystack: String, _ needle: String, _ label: String) {
        check(!haystack.contains(needle), "\(label)（不该出现「\(needle)」）")
    }
}

/// 仓库根目录。本脚本从 scripts/ 目录跑，向上两级是仓库根。
func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // scripts/
        .deletingLastPathComponent()   // 仓库根
}

func load(_ relativePath: String) -> String {
    let url = repoRoot().appendingPathComponent(relativePath)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        print("[失败] 读不到文件：\(relativePath)")
        Counters.failed += 1
        return ""
    }
    return text
}

/// 页面文件列表。清理覆盖面就按这个清单走。
let cleanedPages = [
    "DeepSleep/Views/AlertRulesView.swift",
    "DeepSleep/Views/AutomationView.swift",
    "DeepSleep/Views/ControlView.swift",
    "DeepSleep/Views/ExternalActivityView.swift",
    "DeepSleep/Views/FanControlView.swift",
    "DeepSleep/Views/HangDetectionView.swift",
    "DeepSleep/Views/HostsView.swift",
    "DeepSleep/Views/LsofView.swift",
    "DeepSleep/Views/MonitoringView.swift",
    "DeepSleep/Views/NiceView.swift",
    "DeepSleep/Views/PowerSettingsView.swift",
    "DeepSleep/Views/QuarantineView.swift",
    "DeepSleep/Views/ScheduleView.swift",
    "DeepSleep/Views/ServerModeView.swift",
    "DeepSleep/Views/ShellConfigView.swift",
    "DeepSleep/Views/ThermalView.swift",
    "DeepSleep/Views/UpdateView.swift",
    "DeepSleep/Views/WakeOnLANView.swift",
    "DeepSleep/AIKeepAlive/KeepAliveView.swift"
]

let sources = cleanedPages.map { ($0, load($0)) }
let components = load("DeepSleep/Views/Components.swift")

@main
struct UICleanupTest {
    static func main() {

        // MARK: - 一、说明卡不许回来

        // 「说明」「机制说明」这类标题卡是这一版清掉的东西。
        // 逐个文件查 —— 只要有一个回来就算失败。
        for (path, text) in sources {
            Counters.checkAbsent(text, "title: \"说明\"",
                         "\(path) 没有「说明」卡")
            Counters.checkAbsent(text, "title: \"机制说明\"",
                         "\(path) 没有「机制说明」卡")
            Counters.checkAbsent(text, "title: \"安全设计\"",
                         "\(path) 没有「安全设计」卡")
            Counters.checkAbsent(text, "title: \"权限边界\"",
                         "\(path) 没有「权限边界」卡")
        }

        // MARK: - 二、BulletLine 只剩下确实要留的

        // BulletLine 是「一串说明文字」的排版组件。这一版把绝大多数
        // BulletLine 都删了 —— 剩下的三处（HostsView 两条、ShellConfigView 两条、
        // PowerSettingsView 两条）都是「用户要动手才能解决」的信息，不是机制说明，
        // 而且都已经并进所属的主卡里，不再单独占一张「说明」卡。
        //
        // 判据：带 BulletLine 的文件只能是这三个，且每个文件里不超过 3 条。
        var filesWithBullets: [String: Int] = [:]
        for (path, text) in sources {
            let count = text.components(separatedBy: "BulletLine(").count - 1
            if count > 0 { filesWithBullets[path] = count }
        }
        let allowed = [
            "DeepSleep/Views/HostsView.swift",
            "DeepSleep/Views/ShellConfigView.swift",
            "DeepSleep/Views/PowerSettingsView.swift"
        ]
        for (path, count) in filesWithBullets {
            Counters.check(allowed.contains(path),
                     "\(path) 里还有 BulletLine（\(count) 条）—— 只允许 Hosts / ShellConfig / PowerSettings 三个页面保留")
            Counters.check(count <= 3,
                     "\(path) 的 BulletLine 不超过 3 条（实际 \(count) 条）")
        }
        // 反过来也查一遍：三个允许保留的页面也不该塞更多。
        Counters.check(filesWithBullets.count <= allowed.count,
                 "带 BulletLine 的页面数量没有超过 3 个（实际 \(filesWithBullets.count) 个）")

        // 保留的那几条不许各自占一张卡 —— 卡片标题一旦出现
        // 「注意事项」「生效方式」「提示」，就说明它又被拎出去了。
        for (path, count) in filesWithBullets where count > 0 {
            let text = load(path)
            for title in ["注意事项", "生效方式", "提示"] {
                Counters.checkAbsent(text, "title: \"\(title)\"",
                             "\(path) 没有单独的「\(title)」卡（保留的说明并进了主卡）")
            }
        }

        // MARK: - 三、删除类操作有二次确认

        // 二次确认的载体是 `TlDeleteRequest` + `.deleteConfirmation(...)`。
        // 每接一处删除就要配一处，漏了就等于没保护。
        //
        // 逐个文件查「删除动作是否被包进 TlDeleteRequest」：
        // 判据是文件里出现 TlDeleteRequest，且 `engine.remove(` 之类的
        // 删除调用出现在同一个 perform 闭包里。
        let deleteTargets: [(String, String)] = [
            ("DeepSleep/AIKeepAlive/KeepAliveView.swift", "保活任务"),
            ("DeepSleep/Views/AutomationView.swift", "自动化规则 / 定时命令 / 重启监听"),
            ("DeepSleep/Views/AlertRulesView.swift", "告警规则"),
            ("DeepSleep/Views/QuarantineView.swift", "清除全部"),
            ("DeepSleep/Views/QuickQuitView.swift", "清空名单"),
            ("DeepSleep/Views/LogView.swift", "清空日志")
        ]
        for (path, what) in deleteTargets {
            let text = load(path)
            Counters.checkContains(text, "TlDeleteRequest",
                         "\(path) 的\(what)删除有二次确认")
            Counters.checkContains(text, ".deleteConfirmation(",
                         "\(path) 挂了删除确认弹窗")
        }

        // 通用组件本身要提供确认弹窗，且确认按钮是 destructive 角色 ——
        // 按钮写成普通样式的话，用户不会意识到这是不可逆的。
        Counters.checkContains(components, "struct TlDeleteRequest",
                     "定义了通用的删除确认请求")
        Counters.checkContains(components, "func deleteConfirmation",
                     "定义了通用的删除确认弹窗")
        Counters.checkContains(components, "role: .destructive",
                     "确认按钮用 destructive 样式（用户看得出不可逆）")
        Counters.checkContains(components, "role: .cancel",
                     "确认弹窗有取消按钮")

        // MARK: - 四、不能只剩「删除」，还得能反悔

        // 确认弹窗必须有取消路径。`role: .cancel` 的按钮就是。
        // 少一条就等于逼用户二选一。
        Counters.checkContains(components, "Button(\"取消\"",
                     "确认弹窗的取消按钮有明确的文案")

        // MARK: - 五、被删掉的机制说明原文不许回来

        //
        // 判据用「原文」而不是「长度」：长度会把正常的错误提示、
        // 状态文案也算进来（比如「改了 Hosts 后浏览器 / ping 没变化，
        // 运行 sudo dscacheutil -flushcache 刷新 DNS 缓存。」这种
        // 用户要动手才能解决的引导句），误报太多就没人看这个测试了。
        //
        // 下面是这一版删掉的机制说明里的关键句。它们各自都是纯粹的
        // 「原理 / 边界 / 内部实现」，用户不需要，也没人会读。
        let bannedPhrases: [String] = [
            "这个工具不会做什么",
            "安全设计",
            "权限边界",
            "什么是 Quarantine 属性",
            "nice 值含义",
            "加载顺序与注意事项",
            "这些更新都校验了什么",
            "撤销所有 assertion",
            "不执行外部 shell",
            "getpeereid",
            "UNIX socket",
            "socket 权限",
            "每 3 秒对账",
            "辅助功能权限",
            "读写 /etc/hosts 的权限"
        ]
        for (path, text) in sources {
            for phrase in bannedPhrases {
                Counters.checkAbsent(text, phrase,
                             "\(path) 没有删掉的机制说明原文「\(phrase)」")
            }
        }

        // UpdateView 的更新校验说明卡整块删掉了 —— 那一页只回答
        // 「现在什么版本 / 有没有更新 / 更不更新」。
        Counters.checkAbsent(load("DeepSleep/Views/UpdateView.swift"),
                     "mechanismCard",
                     "更新页没有「这些更新都校验了什么」那张机制说明卡")

        // MARK: - 五之二、留住的东西不许被当成「机制说明」再删一次
        //
        // 这一版删得对，但有几条被误删过 —— 审查发现后补了回来。
        // 它们都属于「用户需要的信息」：缺了，用户遇到对应情况时
        // 不知道该做什么，或者会以为应用算错了。
        //
        // 逐条锁住，免得下次清理时又被当成「多余的话」删掉。
        let mustKeep: [(String, String, String)] = [
            ("DeepSleep/Views/ServerModeView.swift",
             "关掉服务器模式或退出 Deep Sleep 会恢复系统原来的睡眠设置",
             "服务器模式退出时会恢复系统的睡眠设置"),
            ("DeepSleep/AIKeepAlive/KeepAliveView.swift",
             "会记进该服务的用量统计",
             "保活请求会计入服务的用量统计"),
            ("DeepSleep/Views/WakeOnLANView.swift",
             "macOS 防火墙可能把它拦在本机",
             "WOL 提示防火墙可能把包拦在本机"),
            ("DeepSleep/Views/ThermalView.swift",
             "不算进最高温，也不触发 90°C 兜底",
             "校准参考组不参与最高温与兜底判定"),
            ("DeepSleep/Views/AlertRulesView.swift",
             "与「系统监控」页的阈值互不影响，两边都生效",
             "告警规则与系统监控阈值相互独立"),
            ("DeepSleep/Views/ExternalActivityView.swift",
             "不会出现在下面那张表里",
             "争夺电源控制的程序不拦睡眠，因此不在下面那张表里"),
            ("DeepSleep/Views/AlertRulesView.swift",
             "温度阈值可以超过 90°C",
             "温度阈值可以超过 90°C")
        ]
        for (path, needle, what) in mustKeep {
            Counters.checkContains(load(path), needle, "保留了「\(what)」")
        }

        // MARK: - 五之三、界面上的说法不许互相打架
        //
        // 「释放全部」在总览页会连规则维持的一起放掉（代码见
        // `SleepController.releaseAllAssertions()`：它清 `ruleAssertions`）。
        // 所以自动化页不能再说「关掉规则才会释放」—— 那是反的。
        let automation = load("DeepSleep/Views/AutomationView.swift")
        Counters.checkAbsent(automation, "关掉规则才会释放",
                     "自动化页不再说「关掉规则才会释放」（与总览页的「释放全部」矛盾）")

        // 总览页「释放全部」的提示要写明它连规则维持的一起放掉 ——
        // 否则用户在自动化页看到「规则维持的保持项」还在，却不知道
        // 总览页那个按钮会把它们一起清掉。
        Counters.checkContains(load("DeepSleep/Views/DashboardView.swift"),
                     "包括由自动化规则维持的那些",
                     "总览页「释放全部」的提示写明它连规则维持的一起放掉")

        // 用户可见文案里不该出现实现术语。判据精确到只扫字符串字面量：
        // 按整行查会误伤 `controller.activeAssertions` 这种代码 ——
        // 它是接口名，不是用户能看到的字。
        func userFacingLiterals(_ text: String) -> [String] {
            var result: [String] = []
            var inLineComment = false
            for rawLine in text.split(separator: "\n") {
                let line = String(rawLine)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if inLineComment {
                    if trimmed.hasSuffix("*/") { inLineComment = false }
                    continue
                }
                if trimmed.hasPrefix("/*") {
                    inLineComment = !trimmed.hasSuffix("*/")
                    continue
                }
                var current = ""
                var inside = false
                var index = line.startIndex
                while index < line.endIndex {
                    let ch = line[index]
                    if ch == "\\" {
                        // 跳过整个插值表达式。
                        let next = line.index(after: index)
                        if next < line.endIndex && line[next] == "(" {
                            var depth = 0
                            var cursor = next
                            while cursor < line.endIndex {
                                if line[cursor] == "(" { depth += 1 }
                                else if line[cursor] == ")" {
                                    depth -= 1
                                    if depth == 0 {
                                        cursor = line.index(after: cursor)
                                        break
                                    }
                                }
                                cursor = line.index(after: cursor)
                            }
                            index = cursor
                            continue
                        }
                        index = line.index(after: index)
                        if index < line.endIndex { index = line.index(after: index) }
                        continue
                    }
                    if ch == "\"" {
                        if inside {
                            result.append(current)
                            current = ""
                        }
                        inside.toggle()
                    } else if inside {
                        current.append(ch)
                    }
                    index = line.index(after: index)
                }
            }
            return result
        }

        // 这些词是实现细节，不该出现在界面上。
        // 「钥匙串」「root」「cron」「launchd」不在此列 —— 前两个是
        // 用户本来就要打交道的东西，后两个只出现在确实需要说明的地方。
        let jargon = ["assertion", "pmset", "IOPMAssertion", "plist"]
        var jargonOffenders: [String] = []
        for (path, text) in sources {
            for literal in userFacingLiterals(text) {
                let lowered = literal.lowercased()
                for word in jargon {
                    if lowered.contains(word.lowercased()) {
                        jargonOffenders.append("\(path)：\(literal)")
                        break
                    }
                }
            }
        }
        Counters.check(jargonOffenders.isEmpty,
                 "用户可见文案里没有实现术语（发现 \(jargonOffenders.count) 处：\(jargonOffenders.prefix(3).joined(separator: " | "))）")

        // ---------------------------------------------------------------- 结果

        print("")
        if Counters.failed == 0 {
            print("OK: 界面清理符合 v1.11.3 的约定")
            exit(0)
        } else {
            print("FAIL: 界面清理有 \(Counters.failed) 项不符")
            exit(1)
        }
    }
}
