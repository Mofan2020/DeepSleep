//
//  test-pmset-parse.swift
//  Deep Sleep 回归测试
//
//  验证 PMSetOutput.parse 能处理 `pmset -g` 的两种分隔符。
//  这个测试的存在理由：解析只按空格切分时，TAB 分隔的 SleepDisabled
//  会整行被丢掉，导致对账永远误判「设置被外部改回」。
//
//  运行：swiftc Shared/PMSetOutput.swift scripts/test-pmset-parse.swift -o /tmp/pmtest && /tmp/pmtest
//

import Foundation

@main
struct PMSetParseTests {

    static func main() {
        // 真实 `pmset -g` 输出的结构：两个段落，分隔符不一致。
        let sample = [
            "System-wide power settings:",
            " SleepDisabled\t\t1",
            "Currently in use:",
            " standby              0",
            " sleep                1 (sleep prevented by Deep Sleep, powerd)",
            " displaysleep         0",
            " hibernatefile        /var/vm/sleepimage",
            " lowpowermode         0"
        ].joined(separator: "\n")

        let parsed = PMSetOutput.parse(sample)

        var failures = 0
        func check(_ name: String, _ condition: Bool, _ actual: String = "") {
            if condition {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)" + (actual.isEmpty ? "" : " —— 实际值: \(actual)"))
                failures += 1
            }
        }

        check("TAB 分隔的 SleepDisabled 能读到（本次 bug 的核心）",
              parsed["SleepDisabled"] == "1", parsed["SleepDisabled"] ?? "nil")
        check("空格对齐的键能读到",
              parsed["standby"] == "0", parsed["standby"] ?? "nil")
        check("带括号说明的值被截断成数值",
              parsed["sleep"] == "1", parsed["sleep"] ?? "nil")
        check("路径类值保持原样",
              parsed["hibernatefile"] == "/var/vm/sleepimage", parsed["hibernatefile"] ?? "nil")
        check("段落标题不被当成键",
              parsed["System-wide power settings"] == nil)
        check("第二个段落标题也不被当成键",
              parsed["Currently in use"] == nil)

        // 再对一次真实系统输出 —— 只有这个才证明在生产数据上有效。
        print("\n  真实系统读数:")
        let live = PMSetOutput.readCurrent()
        check("在真实 pmset -g 输出上能读到 SleepDisabled",
              live["SleepDisabled"] != nil, "读不到该键")
        for key in ["SleepDisabled", "sleep", "displaysleep", "hibernatemode"] {
            print("    \(key) = \(live[key] ?? "nil")")
        }

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
