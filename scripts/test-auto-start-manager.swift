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
//  运行：
//    swiftc -parse-as-library DeepSleep/Core/AutoStartManager.swift \
//           scripts/test-auto-start-manager.swift -o /tmp/atest && /tmp/atest
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
        testRepairPlan()
        print("OK: AutoStartManager plist 内容与自启复查判据都正确")
    }

    /// 自启复查的判据。
    ///
    /// 这几条对应的是「开关开着、重启后什么都没发生」：plist 在，launchd
    /// 里却没有这个任务（或者任务被 disabled 挡住）。判错一次，用户就得
    /// 自己发现自启是假的。
    static func testRepairPlan() {
        // 没开自启：什么都不做。
        var plan = AutoStartManager.plan(plistEnabled: false, registered: false,
                                         registeredProgram: nil, currentProgram: "/a")
        assertTrue(plan.isEmpty, "没开自启时不该动任何东西")

        // 开了、已注册、路径一致：什么都不做。
        plan = AutoStartManager.plan(plistEnabled: true, registered: true,
                                     registeredProgram: "/Applications/X.app/Contents/MacOS/X",
                                     currentProgram: "/Applications/X.app/Contents/MacOS/X")
        assertTrue(plan.isEmpty, "一切正常时不该重启任务")

        // 开了，但 launchd 里没有这个任务：要重新注册（这是那个 bug 本体）。
        plan = AutoStartManager.plan(plistEnabled: true, registered: false,
                                     registeredProgram: "/a", currentProgram: "/a")
        assertTrue(plan.reregister && !plan.rewrite, "任务没注册时必须重新注册")

        // 路径变了（app 挪过位置 / 更新过）：先重写 plist，再注册。
        plan = AutoStartManager.plan(plistEnabled: true, registered: true,
                                     registeredProgram: "/old/X.app/Contents/MacOS/X",
                                     currentProgram: "/Applications/X.app/Contents/MacOS/X")
        assertTrue(plan.rewrite && plan.reregister, "路径变了必须重写 plist 并重新注册")
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