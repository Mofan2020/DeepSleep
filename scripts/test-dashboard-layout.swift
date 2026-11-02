//
//  test-dashboard-layout.swift
//  DeepSleep
//
//  仪表盘结构的回归护栏。
//
//  为什么需要它：仪表盘是用户第一眼看到的页面，也是这一版重做得最狠的
//  地方。它的视觉结构（环形仪表 + 卡片网格 + 状态条）靠肉眼检查是不行的 ——
//  改坏了没人会发现，直到发版。
//
//  这里检查的是**源码结构**而不是渲染结果：不依赖 GUI、不需要跑起来，
//  编译一次就能验。检查项都是「这一版的仪表盘刻意做成这样」的决定，
//  有人要改，得先想清楚并同时改掉这里的断言。
//
//  判据为什么用「字符串出现」而不是解析 Swift AST：Swift 的语法树 API
//  在命令行脚本里用起来笨重，而这个仓库的其它 UI 测试
//  （test-toolbox-layout.swift）也是同一路子 —— 简单、够用、不会自己坏掉。
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

let dashboard = load("DeepSleep/Views/DashboardView.swift")
let designSystem = load("DeepSleep/Views/DesignSystem.swift")

@main
struct DashboardLayoutTest {
    static func main() {
        // MARK: - 一、环形仪表

        Counters.check(!dashboard.isEmpty, "读到了 DashboardView.swift")

        // 环形仪表：原生 Gauge 的圆形样式。
        // 为什么必须是 accessoryCircularCapacity 而不是自己画 Circle().trim()：
        // 手画的环跟系统其它地方的表盘对不上，而且中心文字的位置/字号得自己调。
        // 原生样式自带中心标签容器，行为也随系统设置走。
        Counters.checkContains(dashboard, ".gaugeStyle(.accessoryCircularCapacity)",
                      "顶部状态卡用原生圆形仪表样式")

        // 仪表的数值必须是「生效项 / 全部项」这个真实比例，不是装饰。
        Counters.checkContains(dashboard, "AssertionKind.allCases.count",
                      "环形仪表的填充比例按全部保持项数算")

        // 中心标签要显示数量，而不是只放个图标。
        Counters.checkContains(dashboard, "controller.activeAssertions.count",
                      "环形仪表中心显示生效项数量")

        // 状态必须颜色 + 文字双编码：环是颜色，StatusPill 是文字。
        Counters.checkContains(dashboard, "StatusPill(text: gaugeCaption",
                      "环形仪表旁有文字状态词（颜色之外的第二重编码）")

        // MARK: - 二、保持清醒改成卡片网格

        Counters.checkContains(dashboard, "assertionGrid", "有独立的保持项网格区")
        Counters.checkContains(dashboard, "LazyVGrid", "保持项用网格排布（两列，一屏看全）")
        Counters.checkContains(dashboard, "AssertionCard(kind: kind)", "网格里放的是新的卡片组件")
        Counters.checkContains(dashboard, "struct AssertionCard", "定义了 AssertionCard 组件")

        // 卡片必须自己带开关 —— 不能为了好看把开关删了。
        Counters.checkContains(dashboard, "controller.setAssertion(kind, enabled: newValue)",
                      "卡片里的开关仍然能切换保持项")

        // 状态标签合并成一个胶囊：四个胶囊比一行文字噪声大。
        Counters.checkContains(dashboard, "parts.joined(separator: \" · \")",
                      "状态标记合并成一个胶囊")

        // 卡片必须自己带状态词（开着 / 没开着）。
        Counters.checkContains(dashboard, "生效中", "卡片有「生效中 / 未启用」状态词")

        // MARK: - 三、底部两栏

        Counters.checkContains(dashboard, "bottomRow", "有底部并排区")
        Counters.checkContains(dashboard, "电源", "底部包含电源")
        Counters.checkContains(dashboard, "自动化", "底部包含自动化")
        Counters.checkContains(dashboard, "完全控制", "底部包含完全控制")

        // 环境项用统一的组件，别在三个地方各写一遍。
        Counters.checkContains(dashboard, "envItem(", "环境状态用统一的 envItem 组件")

        // 环境状态与最近事件必须**并排**。
        // 为什么锁这条：原来这两块各占一整行，纵向要滚三屏才到头。
        // 「一屏览全局」是这一版的要求，并排是它的直接后果。
        let bottomSection = dashboard
            .components(separatedBy: "private var bottomRow")
            .last?
            .components(separatedBy: "// MARK: - 顶部状态卡")
            .first ?? ""
        Counters.checkContains(bottomSection, "HStack(alignment: .top",
                      "底部两块并排放（不各占一整行）")
        Counters.checkContains(bottomSection, "最近事件", "底部右侧是最近事件")

        // MARK: - 四、设计系统合规

        // 间距与圆角一律走令牌，不能写字面量。
        // 允许的两个例外：`spacing: 0`（列表行之间不要间距）与
        // 圆点的 `frame(width: 6, height: 6)`（一个装饰性小圆点，不是布局尺寸）。
        let literalSpacing = dashboard
            .split(separator: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { return false }
                // .padding(12) / .padding(12, 8) 这类
                // 注意：正则里不写转义的左括号 —— 写成 "(" 的字面量形式，
                // 免得文档检查器把它当成「被转义的 Swift 插值」报出来。
                if trimmed.range(of: "[.]padding[(][[:space:]]*[0-9]+([[:space:]]*,[[:space:]]*[0-9]+)*[[:space:]]*[)]", options: .regularExpression) != nil {
                    return true
                }
                // .cornerRadius(8) 这类
                if trimmed.range(of: "[.]cornerRadius[(][[:space:]]*[0-9]+", options: .regularExpression) != nil {
                    return true
                }
                return false
            }
        Counters.check(literalSpacing.isEmpty,
              "仪表盘里没有字面量间距/圆角（发现 \(literalSpacing.count) 处：\(literalSpacing.prefix(3).joined(separator: " | "))）")

        // 仪表的直径也应该是令牌，不是写死在页面里的数字。
        Counters.checkContains(designSystem, "gaugeDiameter", "仪表直径是设计系统里的令牌")
        Counters.checkContains(dashboard, "DS.Metric.gaugeDiameter", "页面用的是令牌而不是字面量直径")

        // MARK: - 五、状态不许只靠颜色

        // 页面里凡是给状态上色的地方，旁边都要有文字。
        // 这条查得粗一点：确认页面里用到了 StatusPill / Tag 这类
        // 「自带文字」的状态组件，而不是只画一个 ColoredCircle。
        Counters.checkContains(dashboard, "StatusPill", "状态用自带文字的胶囊组件表达")
        Counters.checkContains(dashboard, "Tag(text:", "附加标记用自带文字的标签组件表达")

        // MARK: - 六、没把业务语义改掉

        // 主操作与倒计时逻辑必须还在（这一版只改显示）。
        Counters.checkContains(dashboard, "controller.sleepNow()", "「立即睡眠」的动作还在")
        Counters.checkContains(dashboard, "controller.releaseAllAssertions()", "「释放全部保持」的动作还在")
        Counters.checkContains(dashboard, "controller.startCountdown(minutes:", "倒计时的动作还在")
        Counters.checkContains(dashboard, "controller.cancelCountdown()", "取消倒计时的动作还在")

        // MARK: - 七、主操作并进顶部状态卡
        //
        // 为什么锁这条：主操作是这一页最该被点到的东西。用户不该先滚过
        // 一屏说明才看到「立即睡眠」。原来主操作单独占一整块，
        // 现在它在顶部状态卡的右栏里。
        Counters.checkContains(dashboard, "private var rightColumn", "顶部状态卡有右栏")
        let heroSection = dashboard
            .components(separatedBy: "struct StatusHeroCard")
            .last?
            .components(separatedBy: "// MARK: - 保持项卡片")
            .first ?? ""
        Counters.checkContains(heroSection, "rightColumn", "主操作放在状态卡的右栏里")
        Counters.checkContains(heroSection, "立即睡眠", "状态卡右栏有「立即睡眠」")

        // MARK: - 八、倒计时是一个菜单，不再单摆一行控件
        //
        // 为什么锁这条：原来「倒计时睡眠」+ 时长选择器 + 开始 + 取消
        // 四个控件占一整行。现在点开菜单选时长直接开始，进行中才出现取消。
        Counters.checkContains(heroSection, "Menu {", "倒计时入口是菜单")
        Counters.checkContains(heroSection, "分钟后睡眠", "菜单里直接选时长并开始")

        // 「释放全部」只在真的有保持项时才出现 —— 平时不占位置。
        Counters.checkContains(heroSection, "if !controller.activeAssertions.isEmpty",
                      "「释放全部」只在有保持项时出现")

        // MARK: - 九、页面上不许有机制说明
        //
        // 用户反馈：「机制说明 AI 味很浓，用户也不会仔细看」。
        // 仪表盘这一页只回答「现在怎么样 / 我该点什么」。
        //
        // 判据用两条具体的：一是不能再引用 AssertionKind.subtitle
        //（那是四项保持能力各自的原理说明）；二是用户可见文案里
        // 不该出现 assertion 这种实现术语。
        Counters.check(!dashboard.contains("kind.subtitle"),
              "卡片不再显示保持项的原理说明")
        Counters.check(!dashboard.contains("kind.description"),
              "卡片不再显示保持项的原理说明")
        //
        // 注意判据要精确：**只看字符串字面量**。按整行查会误伤
        // `controller.activeAssertions` 这种代码 —— 它是接口名，
        // 不是用户能看到的文案。
        var userFacingQuotes: [String] = []
        var inLineComment = false
        for rawLine in dashboard.split(separator: "\n") {
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
            // 取这一行里所有双引号包起来的内容（跳过转义引号）。
            var current = ""
            var inside = false
            var index = line.startIndex
            while index < line.endIndex {
                let ch = line[index]
                if ch == "\\" {
                    // 跳过整个插值表达式 `\( ... )`。
                    //
                    // 不跳过的话，插值里的代码会被当成文案内容收进来 ——
                    // 比如 `Text("生效 \(controller.activeAssertions.count) 项")`
                    // 会把 `controller.activeAssertions.count` 当成用户能看到的字。
                    let next = line.index(after: index)
                    if next < line.endIndex && line[next] == "(" {
                        var depth = 0
                        var cursor = next
                        while cursor < line.endIndex {
                            if line[cursor] == "(" {
                                depth += 1
                            } else if line[cursor] == ")" {
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
                        userFacingQuotes.append(current)
                        current = ""
                    }
                    inside.toggle()
                } else if inside {
                    current.append(ch)
                }
                index = line.index(after: index)
            }
        }
        let offending = userFacingQuotes.filter { $0.lowercased().contains("assertion") }
        Counters.check(offending.isEmpty,
              "用户可见文案里没有 assertion 这种实现术语（发现 \(offending.count) 处：\(offending.prefix(2))）")

        // 四项保持能力都要在网格里，不能少一项。
        let assertionGridSection = dashboard
            .components(separatedBy: "private var assertionGrid")
            .last?
            .components(separatedBy: "// MARK: - 底部两栏")
            .first ?? ""
        Counters.checkContains(assertionGridSection, "ForEach(AssertionKind.allCases)",
                      "网格遍历全部保持项（四项都在）")

        // ---------------------------------------------------------------- 结果

        print("")
        if Counters.failed == 0 {
            print("OK: 仪表盘结构符合 v1.11.3 的设计")
            exit(0)
        } else {
            print("FAIL: 仪表盘结构有 \(Counters.failed) 项不符")
            exit(1)
        }

    }
}
