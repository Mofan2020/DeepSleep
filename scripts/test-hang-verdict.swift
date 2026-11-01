//
//  test-hang-verdict.swift
//  Deep Sleep 回归测试
//
//  验证「未响应」判据本身：`WindowServerResponsiveness`。
//
//  为什么这个必须测：这条判据是「不误报」的唯一保证。之前用辅助功能去问
//  应用，Telegram 因为辅助功能响应慢被反复误报成卡死。现在改成问
//  WindowServer（活动监视器与「强制退出」窗口的同一份状态），
//  如果符号取不到、或者取到了却永远返回 true，界面上就会变成
//  「所有应用都没响应」这种更离谱的结果。
//
//  这里测三件事：
//   1. 三个符号都取得到；
//   2. 当下正在跑的正常应用，没有一个被判成未响应（误报检查）；
//   3. 不存在的 pid 问不出结果（不能把「问不到」当成「未响应」）。
//
//  真实卡死场景（SIGSTOP 一个 GUI 应用，等约 15 秒系统才标记）不放进自动化
//  测试 —— 光等待就要 15 秒，会拖垮整个回归。那一条在 docs/notes.md 里
//  有手工实测记录。
//
//  运行：
//    swiftc -sdk $(xcrun --show-sdk-path --sdk macosx) \
//           -target arm64-apple-macos26.0 \
//           DeepSleep/Core/HangDetector.swift DeepSleep/Core/HangDetectionConfig.swift \
//           scripts/test-hang-verdict.swift -o /tmp/t_hangverdict && /tmp/t_hangverdict
//

import Foundation
import AppKit

@main
struct HangVerdictTests {

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

        // ---------------------------------------------------- 符号可用性
        print("== 系统判定接口的符号 ==")
        check("三个符号都取到了，判定可用", WindowServerResponsiveness.isAvailable)
        guard WindowServerResponsiveness.isAvailable else {
            print("\n判定接口不可用，后面的检查没有意义。")
            print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
            exit(failures == 0 ? 0 : 1)
        }

        // ---------------------------------------------- 正常应用不许被误报
        print("\n== 误报检查：正常应用应该全部判为「正常」 ==")
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }
        var falsePositives: [String] = []
        var answered = 0
        for app in apps {
            let pid = app.processIdentifier
            guard let verdict = WindowServerResponsiveness.isUnresponsive(pid: pid) else {
                // 没注册到图形系统的应用问不到，不算误报，也不算答案。
                continue
            }
            answered += 1
            if verdict {
                falsePositives.append(app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)")
            }
        }
        print("  问到答复的应用数：\(answered) / \(apps.count)")
        check(
            "没有一个正常应用被判成未响应",
            falsePositives.isEmpty,
            "误报：\(falsePositives.joined(separator: "、"))"
        )
        check("至少有几个应用能问出结果（否则这条检查是空转）", answered > 0)

        // 本应用自己必然正常 —— 这条是最硬的断言：代码就在它自己岛上跑。
        let selfVerdict = WindowServerResponsiveness.isUnresponsive(pid: getpid())
        check(
            "Deep Sleep 自己判为正常",
            selfVerdict == false,
            "实际 \(String(describing: selfVerdict))"
        )

        // -------------------------------------------------- 不存在的 pid
        print("\n== 不存在的进程 ==")
        // 一个几乎不可能存在的 pid：往上限靠。
        let ghost = pid_t(999_999)
        let ghostVerdict = WindowServerResponsiveness.isUnresponsive(pid: ghost)
        check(
            "不存在的 pid 问不出结果（不是「未响应」）",
            ghostVerdict == nil,
            "实际 \(String(describing: ghostVerdict))"
        )

        // ---------------------------------------------------- 批量接口
        print("\n== 批量接口 ==")
        let pids = apps.prefix(5).map(\.processIdentifier)
        let snapshot = WindowServerResponsiveness.snapshot(pids: pids)
        check("批量查询返回的条目数不超过请求数", snapshot.count <= pids.count)
        check(
            "批量结果里没有把任何一个判成未响应",
            snapshot.values.allSatisfy { $0 == false },
            "实际 \(snapshot)"
        )

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
