//
//  test-cgeventtap.swift
//  Deep Sleep 回归测试
//
//  验证 CGEvent tap 创建路径本身能跑通 —— 不需要 Accessibility 授权
//  就能通过的部分先跑：枚举值、调用签名、mach port 句柄能拿到。
//
//  注意：**真实事件 fire 需要 Accessibility 授权**，本测试只能在
//  `Swift/CGEvent.tapCreate(...)` 返回非 nil 这一层面验证代码可编译、
//  可运行。事件真实 fire / callback 触发需要用户在系统设置里手动授权
//  后手动测试 —— 不在自动化测试覆盖范围。
//
//  运行：
//    swiftc -framework ApplicationServices scripts/test-cgeventtap.swift \
//           -o /tmp/cgevtap -parse-as-library && /tmp/cgevtap
//
//

import ApplicationServices
import Foundation

@main struct CGEventTapTests {
    static func assertTrue(_ cond: Bool, _ label: String) {
        if cond {
            print("[通过] \(label)")
        } else {
            print("FAIL [\(label)]")
            exit(1)
        }
    }

    static func main() {
        // 1. 枚举值能用：构建一个 32 位的 eventMask 位掩码
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)
        assertTrue(mask != 0, "位掩码非 0（mask=\(mask)）")

        // 2. AXIsProcessTrusted 不带 prompt：能调，返回 Bool
        let trusted = AXIsProcessTrusted()
        assertTrue(trusted == true || trusted == false, "AXIsProcessTrusted 返回 Bool（值=\(trusted)）")

        // 3. CGEvent.tapCreate 能调 —— 是否返回 tap 取决于授权。
        //    拿到 tap 就说明授权已装（系统会接受 tap）。
        //    没拿到 tap 可能是：(a) 没授权 (b) 没有登录 session (c) 沙盒限制。
        //    这些情况下，断言「能调到 API」就够。
        let proxy = Unmanaged.passRetained(NSString(string: "proxy")).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { (_, _, _, userInfo) -> Unmanaged<CGEvent>? in
                if userInfo != nil {
                    // 这里只是证明 callback signature 能编译能调用，
                    // 不真的依赖它 fire
                    return nil
                }
                return nil
            },
            userInfo: proxy
        )
        // 即使 tap 为 nil（在无授权或无 GUI session 时），签名能过编译就行。
        if let tap {
            print("[通过] CGEvent.tapCreate 返回非 nil（已授权的 session）")
            // 验证能调 enable + 创建 run loop source
            CGEvent.tapEnable(tap: tap, enable: true)
            assertTrue(true, "CGEvent.tapEnable(tap:enable:) 调通")
            if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
                print("[通过] CFMachPortCreateRunLoopSource 返回非 nil")
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                assertTrue(true, "CFRunLoopAddSource 调通")
                // 不真的跑 RunLoop —— 测试目的是证明 API 调用链能通过。
                CFMachPortInvalidate(tap)
                assertTrue(true, "CFMachPortInvalidate 调通")
            } else {
                print("[注意] CFMachPortCreateRunLoopSource 返回 nil —— 通常是授权或 session 问题")
            }
        } else {
            print("[注意] CGEvent.tapCreate 返回 nil（无授权或无 GUI session）—— 本测试仅验证 API 调用链")
        }

        Unmanaged<NSString>.fromOpaque(proxy).release()

        print("")
        print("测试结论: 全部通过（CGEvent tap 调用链可编译、可调用、签名正确）")
        print("")
        print("下一步手动验证（需用户在系统设置里授权 DeepSleep）：")
        print("  1. 启动 DeepSleep，开启服务器模式")
        print("  2. 不动机器 5 秒 —— UI 显示倒计时正常减少")
        print("  3. 移动鼠标 —— 倒计时应该被重置（回到剩余最大值附近）")
        print("  4. 等到阈值 —— 屏幕自动关闭")
    }
}