//
//  test-process-guard.swift
//  Deep Sleep 回归测试
//
//  验证「快速退出」的裁决层：保护名单、进程树计算、结果编解码。
//  这一层错了的后果不是功能失效，而是杀掉不该杀的东西 ——
//  所以这里的失败用例比成功用例更重要。
//
//  运行：
//    swiftc Shared/ProcessInventory.swift Shared/ProcessGuard.swift \
//           Shared/TerminationReport.swift scripts/test-process-guard.swift -o /tmp/gt && /tmp/gt
//

import Darwin
import Foundation

@main
struct ProcessGuardTests {

    // MARK: - 构造假进程

    static func fake(pid: pid_t,
                     ppid: pid_t,
                     name: String,
                     path: String = "/Applications/Some.app/Contents/MacOS/Some",
                     bundle: String? = nil) -> RunningProcess {
        RunningProcess(
            pid: pid,
            parentPID: ppid,
            uid: 501,
            name: name,
            executablePath: path,
            bundlePath: ProcessInventory.bundlePath(forExecutablePath: path),
            bundleIdentifier: bundle
        )
    }

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

        // ---------------------------------------------------------- 保护名单

        print("== 保护名单（进程名）==")
        for name in ["launchd", "kernel_task", "WindowServer", "loginwindow", "Dock",
                     "Finder", "SystemUIServer", "ControlCenter", "NotificationCenter",
                     "Spotlight", "powerd", "tccd", "securityd", "cfprefsd", "distnoted",
                     "diskarbitrationd", "opendirectoryd", "mds", "coreaudiod", "bluetoothd",
                     "Deep Sleep", "deepsleep-helper"] {
            // 大小写不敏感：p_comm 在不同系统版本上的大小写并不稳定。
            let process = fake(pid: 9000, ppid: 1, name: name.lowercased())
            check("「\(name)」被拒绝", ProcessGuard.refusalReason(for: process) != nil)
        }

        print("\n== 普通应用与命令行进程不受影响 ==")
        for name in ["Safari", "Xcode", "Google Chrome", "GoodNotes", "bash", "sleep",
                     "python3", "Terminal", "Activity Monitor"] {
            let process = fake(pid: 9001, ppid: 1, name: name)
            let reason = ProcessGuard.refusalReason(for: process)
            check("「\(name)」可以杀", reason == nil, reason ?? "")
        }

        print("\n== 保护名单（bundle id）==")
        for bundle in ["com.apple.finder", "com.apple.dock", "com.apple.WindowServer",
                       "com.apple.SystemUIServer", "com.apple.systempreferences",
                       "com.skyc8266.deepsleep", "com.skyc8266.deepsleep.helper"] {
            let process = fake(pid: 9002, ppid: 1, name: "whatever", bundle: bundle)
            check("bundle \(bundle) 被拒绝", ProcessGuard.refusalReason(for: process) != nil)
        }
        for bundle in ["com.google.Chrome", "com.apple.Safari", "com.tinyspeck.slackmacgap"] {
            let process = fake(pid: 9003, ppid: 1, name: "whatever", bundle: bundle)
            let reason = ProcessGuard.refusalReason(for: process)
            check("bundle \(bundle) 可以杀", reason == nil, reason ?? "")
        }

        print("\n== 无条件拒绝的两种：pid 1 与我自己 ==")
        check("pid 1 被拒绝", ProcessGuard.refusalReason(for: fake(pid: 1, ppid: 0, name: "whatever")) != nil)
        check("pid 0 被拒绝", ProcessGuard.refusalReason(for: fake(pid: 0, ppid: 0, name: "whatever")) != nil)
        check("本进程被拒绝（pid \(getpid())）",
              ProcessGuard.refusalReason(for: fake(pid: getpid(), ppid: 1, name: "test-binary")) != nil)

        print("\n== isProtected 供界面过滤候选 ==")
        check("Finder 不出现在候选里", ProcessGuard.isProtected(bundleIdentifier: "com.apple.finder", name: "Finder"))
        check("Dock 名字即被拦", ProcessGuard.isProtected(bundleIdentifier: "com.example.dock", name: "Dock"))
        check("普通应用出现在候选里",
              !ProcessGuard.isProtected(bundleIdentifier: "com.google.Chrome", name: "Google Chrome"))

        // ---------------------------------------------------------- 进程树

        print("\n== 进程树：被保护进程连同整棵子树一起跳过 ==")
        //  100 MyApp
        //   ├─ 101 MyApp Helper
        //   │    └─ 102 Finder        ← 受保护
        //   │         └─ 103 不应该被杀
        //   └─ 104 MyApp Renderer
        let snapshot = [
            fake(pid: 100, ppid: 1, name: "MyApp"),
            fake(pid: 101, ppid: 100, name: "MyApp Helper"),
            fake(pid: 102, ppid: 101, name: "Finder"),
            fake(pid: 103, ppid: 102, name: "ShouldNotDie"),
            fake(pid: 104, ppid: 100, name: "MyApp Renderer")
        ]
        let plan = ProcessGuard.plan(roots: [100], in: snapshot)
        check("目标数 = 3", plan.targets.count == 3, "\(plan.targets)")
        check("不含受保护的 102", !plan.targets.contains(102))
        check("不含受保护进程的子进程 103", !plan.targets.contains(103))
        check("子进程排在父进程之前",
              plan.targets.firstIndex(of: 101)! < plan.targets.firstIndex(of: 100)!
              && plan.targets.firstIndex(of: 104)! < plan.targets.firstIndex(of: 100)!,
              "\(plan.targets)")
        check("拒绝记录里有 102", plan.refusals.contains { $0.pid == 102 })
        check("跳过的子进程数为 1", plan.skippedDescendantCount == 1, "\(plan.skippedDescendantCount)")

        print("\n== 根进程本身受保护时不杀任何东西 ==")
        let protectedRoot = ProcessGuard.plan(roots: [102, 103], in: snapshot)
        check("目标为空", protectedRoot.targets.isEmpty, "\(protectedRoot.targets)")

        print("\n== 已经退出的进程：如实报告「读不到」，而不是静默忽略 ==")
        let stale = ProcessGuard.plan(roots: [4242], in: snapshot)
        check("目标为空", stale.targets.isEmpty)
        check("产生一条拒绝记录", stale.refusals.count == 1, "\(stale.refusals)")
        check("理由说明「读不到」",
              stale.refusals.first?.reason.contains("无法读取") ?? false,
              stale.refusals.first?.reason ?? "")

        print("\n== 去重：同一棵树被请求两次只算一次 ==")
        let duplicate = ProcessGuard.plan(roots: [100, 100, 101], in: snapshot)
        check("目标数仍为 3", duplicate.targets.count == 3, "\(duplicate.targets)")
        check("目标里没有重复 pid", Set(duplicate.targets).count == duplicate.targets.count)

        // ---------------------------------------------------------- 路径解析

        print("\n== app 束识别 ==")
        check("/Applications/Foo.app 解析正确",
              ProcessInventory.bundlePath(forExecutablePath: "/Applications/Foo.app/Contents/MacOS/Foo")
              == "/Applications/Foo.app")
        check("嵌套 app 取最内层",
              ProcessInventory.bundlePath(
                forExecutablePath: "/Applications/A.app/Contents/Frameworks/B.app/Contents/MacOS/B")
              == "/Applications/A.app/Contents/Frameworks/B.app")
        check("不在 app 里时返回 nil",
              ProcessInventory.bundlePath(forExecutablePath: "/usr/bin/true") == nil)
        check("空路径返回 nil", ProcessInventory.bundlePath(forExecutablePath: "") == nil)

        // ---------------------------------------------------------- 真实快照

        print("\n== 真实进程快照 ==")
        let real = ProcessInventory.snapshot()
        check("快照非空（\(real.count) 个进程）", real.count > 50, "\(real.count)")
        check("快照里能找到自己", real.contains { $0.pid == getpid() })
        let selfProcess = real.first { $0.pid == getpid() }
        check("自己的 uid 是当前用户", selfProcess?.uid == getuid(), "\(String(describing: selfProcess?.uid))")
        check("每个进程都读到了名字", real.allSatisfy { !$0.name.isEmpty })

        // 这条不是断言而是记录一个能力边界：普通权限读不到别的用户（尤其 root）
        // 拥有的进程，所以应用侧的「计划」只能覆盖自己 uid 的进程。
        // 这正是助手侧要用 root 再算一遍的原因，也是「读不到」必须如实上报的原因。
        let rootOwned = real.filter { $0.uid == 0 }.count
        print("  [信息] 以当前权限能读到的 \(real.count) 个进程里，uid=0 的有 \(rootOwned) 个")

        if let finder = real.first(where: { $0.name == "Finder" }) {
            check("真实 Finder 会被拒绝", ProcessGuard.refusalReason(for: finder) != nil)
        } else {
            print("  [跳过] Finder 未在运行，无法用真实进程验证")
        }
        let realRivals = real.filter { $0.pid > 1 && ProcessGuard.refusalReason(for: $0) == nil }
        check("真实快照里绝大多数进程可以杀（\(realRivals.count)/\(real.count)）",
              realRivals.count > real.count / 2,
              "\(realRivals.count)/\(real.count)")

        // ---------------------------------------------------------- 编解码

        print("\n== 结果编解码往返（名字里有分隔符与中文）==")
        var report = TerminationReport()
        report.killed = [.init(pid: 11, name: "Google Chrome Helper (Renderer)"),
                         .init(pid: 12, name: "微信")]
        report.refused = [.init(pid: 13, name: "Finder", reason: "受保护的系统应用「Finder」（com.apple.finder）")]
        report.failed = [.init(pid: 14, name: "root-owned", reason: "Operation not permitted")]
        report.skippedDescendants = 7
        let roundTrip = TerminationReport.decode(report.encode())
        check("killed 往返一致", roundTrip.killed == report.killed, "\(roundTrip.killed)")
        check("refused 往返一致", roundTrip.refused == report.refused, "\(roundTrip.refused)")
        check("failed 往返一致", roundTrip.failed == report.failed, "\(roundTrip.failed)")
        check("skipped 往返一致", roundTrip.skippedDescendants == 7, "\(roundTrip.skippedDescendants)")
        check("摘要含三类计数", roundTrip.summary.contains("已退出 2") && roundTrip.summary.contains("受保护跳过 1"))

        // ---------------------------------------------------------- 真实结束

        print("\n== 真实结束一棵进程树（以当前用户身份）==")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 三个子进程，模拟「应用 + 它拉起来的一串子进程」。
        shell.arguments = ["-c", "sleep 240 & sleep 240 & sleep 240 & wait"]
        do {
            try shell.run()
        } catch {
            print("  [失败] 无法启动测试用进程：\(error)")
            failures += 1
            finish(failures)
        }

        // 等子进程都起来
        Thread.sleep(forTimeInterval: 0.6)
        let tree = ProcessInventory.snapshot()
        let roots = [shell.processIdentifier]
        let kids = ProcessInventory.descendants(of: roots, in: tree)
        check("枚举到 3 个子进程", kids.count == 3, "\(kids)")
        check("顺序里子是父的前面",
              ProcessInventory.orderedForTermination(roots: roots, in: tree).last == shell.processIdentifier)

        let realPlan = ProcessGuard.plan(roots: roots, in: tree)
        check("计划包含 4 个进程", realPlan.targets.count == 4, "\(realPlan.targets)")
        check("计划没有拒绝项", realPlan.refusals.isEmpty, "\(realPlan.refusals)")

        let outcome = ProcessTerminator.terminate(realPlan.targets, in: tree)
        check("全部结束成功（\(outcome.killed.count) 个）", outcome.killed.count == 4, "\(outcome.killed)")
        check("没有失败项", outcome.failed.isEmpty, "\(outcome.failed)")

        // 向内核确认：这些 pid 真的不在了。应用自己的汇报是自述，不是证据。
        var alive: [pid_t] = []
        for pid in realPlan.targets where Darwin.kill(pid, 0) == 0 {
            alive.append(pid)
        }
        check("内核确认目标已消失", alive.isEmpty, "仍存活: \(alive)")

        finish(failures)
    }

    static func finish(_ failures: Int) -> Never {
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
