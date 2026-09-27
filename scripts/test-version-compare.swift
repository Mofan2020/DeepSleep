//
//  test-version-compare.swift
//  Deep Sleep 回归测试
//
//  验证 SemanticVersion 的比较规则 —— 自动更新的判断全压在这上面，
//  比错方向就是「永远在更新」。
//
//  运行：swiftc Shared/Version.swift scripts/test-version-compare.swift -o /tmp/vtest && /tmp/vtest
//

import Foundation

@main
struct VersionCompareTests {

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

        print("== 数字段比较（字符串比较会在这里出错）==")
        check("\"1.10.0\" 比 \"1.9.0\" 新",
              SemanticVersion.isUpgrade(from: "1.9.0", to: "1.10.0"))
        check("\"1.10.0\" 不比 \"1.10.0\" 新（相等不更新）",
              !SemanticVersion.isUpgrade(from: "1.10.0", to: "1.10.0"))
        check("\"1.9.0\" 不比 \"1.10.0\" 新（不降级）",
              !SemanticVersion.isUpgrade(from: "1.10.0", to: "1.9.0"))
        check("\"2.0.0\" 比 \"1.99.99\" 新",
              SemanticVersion.isUpgrade(from: "1.99.99", to: "2.0.0"))

        print("\n== 段数不同按零补齐 ==")
        check("\"1.1\" 与 \"1.1.0\" 相等", SemanticVersion.compare("1.1", "1.1.0") == 0)
        check("\"1.1\" → \"1.1.1\" 是新版本", SemanticVersion.isUpgrade(from: "1.1", to: "1.1.1"))
        check("\"1\" → \"1.0.1\" 是新版本", SemanticVersion.isUpgrade(from: "1", to: "1.0.1"))

        print("\n== 带 v 前缀与预发布后缀 ==")
        check("\"v1.2.0\" 能解析", SemanticVersion.parse("v1.2.0") != nil)
        check("\"v1.2.0\" 比 \"1.1.9\" 新", SemanticVersion.isUpgrade(from: "1.1.9", to: "v1.2.0"))
        check("\"1.2.0-beta.1\" 与 \"1.2.0\" 视为相等",
              SemanticVersion.compare("1.2.0-beta.1", "1.2.0") == 0)

        print("\n== 无法解析时必须放弃更新（这是防循环的关键）==")
        for bad in ["", "   ", "v", "abc", "1.x", "1..2", "1.", "-1.0.0", "x.y.z"] {
            let parsed = SemanticVersion.parse(bad)
            check("parse(\"\(bad)\") 返回 nil", parsed == nil, String(describing: parsed))
            check("用 \"\(bad)\" 作候选时不更新",
                  !SemanticVersion.isUpgrade(from: "1.0.0", to: bad))
            check("用 \"\(bad)\" 作当前版本时不更新",
                  !SemanticVersion.isUpgrade(from: bad, to: "9.9.9"))
        }

        print("\n== 自我一致性：never downgrade / never equal-install ==")
        // 同版本反复比较必须始终为 false，否则就是「每次启动都更新」的循环。
        for _ in 0..<3 {
            check("同版本反复判断仍为不更新",
                  !SemanticVersion.isUpgrade(from: "1.1.0", to: "1.1.0"))
        }

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
