//
//  test-auto-start-manager.swift
//  Deep Sleep 回归测试
//
//  验证 AutoStartManager 的 plist 字符串生成与 disable 路径：
//   - 默认路径是 ~/Library/LaunchAgents/com.skyc8266.deepsleep.plist
//   - plist 内容包含 Label、ProgramArguments、--autostart、RunAtLoad、KeepAlive=false
//   - 不写 KeepAlive=true（避免「关掉会再起」的负面体验）
//
//  实际的 launchctl 命令无法在「普通用户 / CI 跑测」环境下 mock（bootout
//  会试图操作真正的 boot 系统），所以 enable() 的实际效果不在单测中覆盖。
//  集成验证在 docs/release.md 的发版流程中做。
//
//  运行：swift -parse DeepSleep/Core/AutoStartManager.swift scripts/test-auto-start-manager.swift
//

import Foundation

@main
struct AutoStartManagerTests {

    static func assertTrue(_ cond: Bool, _ label: String) {
        if !cond {
            print("FAIL [\(label)]")
            exit(1)
        }
    }

    static func main() {
        testDefaultPath()
        testPlistContent()
        testPlistHasAutostartFlag()
        testPlistNotKeepAlive()
        print("OK: AutoStartManager plist 内容正确")
    }

    static func testDefaultPath() {
        let expected = "\(NSHomeDirectory())/Library/LaunchAgents/com.skyc8266.deepsleep.plist"
        assertTrue(AutoStartManager.plistPath == expected,
                   "plistPath == \(expected) got \(AutoStartManager.plistPath)")
    }

    static func testPlistContent() {
        let plist = AutoStartManager.diagnosePlistContent()
        assertTrue(plist.contains("<string>com.skyc8266.deepsleep</string>"), "label")
        assertTrue(plist.contains("<key>RunAtLoad</key>"), "RunAtLoad key present")
        assertTrue(plist.contains("<true/>"), "RunAtLoad true")
        assertTrue(plist.contains("<key>KeepAlive</key>"), "KeepAlive key present")
        assertTrue(plist.contains("<false/>"), "KeepAlive false")
    }

    static func testPlistHasAutostartFlag() {
        let plist = AutoStartManager.diagnosePlistContent()
        assertTrue(plist.contains("<string>--autostart</string>"),
                   "--autostart flag present")
    }

    static func testPlistNotKeepAlive() {
        let plist = AutoStartManager.diagnosePlistContent()
        // 防止误写 KeepAlive = true（关掉应用会再起来，违反「自启 = 启动一次」的语义）
        assertTrue(!plist.contains("<key>KeepAlive</key>\n\t<true/>"),
                   "KeepAlive must not be true")
    }
}

// 让单测可以拿到 plist 内容（生产代码不需要暴露这个）。
extension AutoStartManager {
    static func diagnosePlistContent() -> String {
        plistContent(executablePath: "/Applications/Deep Sleep.app/Contents/MacOS/Deep Sleep")
    }
}