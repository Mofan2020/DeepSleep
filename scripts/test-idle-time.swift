//
//  test-idle-time.swift
//  Deep Sleep 回归测试
//
//  覆盖服务器模式空闲检测的两条路径：
//
//  1. `IdleTime.systemIdleSeconds()` —— 历史上用 IOHIDSystem 的 HIDIdleTime。
//     **macOS 26 上当本进程持有 noidle 断言（DeepSleep 助手 + 主进程自己）
//     时，powerd 会停止累加 HIDIdleTime**（实测 30 秒不动机器，值在 0~1.5
//     之间反复跳，不会单调递增）。这条路径 v1.6.2 起仅作"诊断 / 后备"用，
//     ServerModeController 不再依赖它。本测试只验证它仍能返回合法数字。
//
//  2. 应用层时间戳（`Date()` 时间差）—— v1.6.2 起 ServerModeController
//     实际使用的空闲计时。CGEvent tap 在每次键盘 / 鼠标事件来时把
//     `lastActivityAt` 重置为 `Date()`，watchdog 比较 `Date() - lastActivityAt`。
//     这条路径用纯 Foundation 测，**不**依赖 CGEvent tap / Accessibility
//     授权，能精确通过。
//
//  运行：
//    swiftc Shared/IdleTime.swift scripts/test-idle-time.swift \
//           -o /tmp/idlet && /tmp/idlet
//
//

import Foundation

@main struct IdleTimeTests {
    static func assertTrue(_ cond: Bool, _ label: String) {
        if cond {
            print("[通过] \(label)")
        } else {
            print("FAIL [\(label)]")
            exit(1)
        }
    }

    /// 复刻 ServerModeController 的应用层时间戳语义：
    /// `lastActivityAt` 由"事件 tap"在每次事件来时重置为 `Date()`，
    /// watchdog 比较 `Date().timeIntervalSince(lastActivityAt)`。
    /// 这里用同步 sleep 模拟"用户不动"。
    private final class MockTapServer {
        var lastActivityAt = Date()
        func fireEvent() { lastActivityAt = Date() }
        func idleSeconds() -> TimeInterval {
            return Date().timeIntervalSince(lastActivityAt)
        }
    }

    static func main() {
        // ========== A. `IdleTime.systemIdleSeconds()` 的合法返回 ==========
        let first = IdleTime.systemIdleSeconds()
        assertTrue(first != nil, "systemIdleSeconds() 返回非 nil")
        guard let first else { return }
        assertTrue(first >= 0, "idle >= 0（first=\(first)）")
        assertTrue(first.isFinite, "idle 有限（first=\(first)）")
        print("[文档] 在持有 noidle 断言的本进程上，systemIdleSeconds() 不保证单调递增 —— "
              + "实测 30 秒不动机器，值在 0~1.5 之间反复跳。"
              + "ServerModeController v1.6.2 已不依赖此 API。")

        // ========== B. 应用层时间戳的精确行为 ==========
        let server = MockTapServer()
        // 1) 初始空闲 = 0
        assertTrue(server.idleSeconds() < 0.05,
                   "刚 fireEvent 后空闲 < 50ms（实测 \(server.idleSeconds())）")

        // 2) 等 1.2 秒后空闲 ≈ 1.2 秒（容许 ±100ms）
        Thread.sleep(forTimeInterval: 1.2)
        let idle1 = server.idleSeconds()
        assertTrue(idle1 >= 1.1 && idle1 < 1.4,
                   "等 1.2 秒后空闲 ≈ 1.2 秒（实测 \(idle1)）")

        // 3) fireEvent 后空闲 ≈ 0
        server.fireEvent()
        let idle2 = server.idleSeconds()
        assertTrue(idle2 < 0.05,
                   "fireEvent 后空闲 < 50ms（实测 \(idle2)）")

        // 4) 多次 fireEvent 不会累加 —— 关键正确性
        //
        // 阈值为什么是 0.3 秒而不是 0.1：idleSeconds() 测的是**全系统**空闲，
        // 不是本进程的。循环里一共睡了 10 × 0.05 = 0.5 秒，即使重置完全正常，
        // 末值也该是「最后一个间隔 0.05 秒 + 系统噪声」，实测 0.11~0.12 秒。
        // 这里要证明的是「没有累加成 0.5 秒」，所以阈值取 0.3 秒 ——
        // 既不会被系统噪声误伤，又真的能抓住累加回归（坏掉时会是 0.5 秒以上）。
        for _ in 0..<10 {
            server.fireEvent()
            Thread.sleep(forTimeInterval: 0.05)
        }
        let idle3 = server.idleSeconds()
        assertTrue(idle3 < 0.3,
                   "连续 10 次 fireEvent 后空闲 < 300ms（实测 \(idle3)）")

        // 5) 长时间不动：5 秒后空闲 ≥ 4.9 秒
        Thread.sleep(forTimeInterval: 5.0)
        let idle5 = server.idleSeconds()
        assertTrue(idle5 >= 4.9,
                   "再等 5 秒后空闲 ≥ 4.9 秒（实测 \(idle5)）")

        print("")
        print("测试结论: 全部通过")
    }
}