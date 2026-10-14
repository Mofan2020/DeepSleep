//
//  test-idle-time.swift
//  Deep Sleep 回归测试
//
//  验证 Shared/IdleTime.systemIdleSeconds() 在本机返回合法数字、随时间单调递增。
//
//  这层错了的后果是「服务器模式空闲计时」永远不动 / 永远在跳 ——
//  属于「无声错误」，所以必须独立单测。
//
//  运行：
//    swiftc Shared/IdleTime.swift scripts/test-idle-time.swift \
//           -o /tmp/idlet && /tmp/idlet
//
//  注：本测试依赖 `IdleTime` 的实际 API 可用 —— 测试直接走 Shared。
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

    static func main() {
        // 1. 读一次 —— 必须返回非 nil 的数字
        let first = IdleTime.systemIdleSeconds()
        assertTrue(first != nil, "systemIdleSeconds() 返回非 nil")
        guard let first else { return }
        assertTrue(first >= 0, "idle >= 0（first=\(first)）")

        // 2. 立即再读 —— 应当 ≥ first（不会有「未来」事件）
        let second = IdleTime.systemIdleSeconds() ?? 0
        assertTrue(second >= first, "second >= first（second=\(second), first=\(first)）")

        // 3. 等 1.2 秒 —— idle 必须增加 ≥ 1 秒
        Thread.sleep(forTimeInterval: 1.2)
        let third = IdleTime.systemIdleSeconds() ?? 0
        assertTrue(third >= first + 1.0,
                   "等 1.2 秒后 idle 至少 +1（third=\(third), first=\(first)）")

        // 4. 等 0.2 秒再读 —— 增加应当 < 0.5（防止误差爆炸）
        Thread.sleep(forTimeInterval: 0.2)
        let fourth = IdleTime.systemIdleSeconds() ?? 0
        assertTrue(fourth - third < 0.5,
                   "200ms 内增量 < 0.5 秒（避免测量误差爆炸）")

        print("")
        print("测试结论: 全部通过")
    }
}
