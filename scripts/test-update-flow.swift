//
//  test-update-flow.swift
//  DeepSleep 回归测试
//
//  验证自动更新链路里的**纯逻辑**部分：
//    · 「检查完了 / 校验完了，下一步该做什么」的判定；
//    · 版本号比较（沿用 SemanticVersion 的规则，方向不能反）；
//    · 要不要提权；
//    · 结果文件的解析（上一轮更新到底成没成）；
//    · 更新器脚本本身：语法合法、会把结果写下来、失败会回滚。
//
//  全部离线：不连网、不装东西、不碰真实的应用目录。
//  脚本的替换流程是在 /tmp 下的假目录里真跑一遍的 —— 用的是假的 .app，
//  替换的是假目录，`open` 打开不了它（没有可执行文件），不会弹任何东西。
//
//  运行：
//  swiftc -parse-as-library Shared/Version.swift DeepSleep/Core/UpdateFlow.swift \
//      scripts/test-update-flow.swift -o /tmp/t_updateflow && /tmp/t_updateflow
//

import Foundation

@main
struct UpdateFlowTests {

    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ actual: String = "") {
        if condition {
            print("  [通过] \(name)")
        } else {
            print("  [失败] \(name)" + (actual.isEmpty ? "" : " —— 实际: \(actual)"))
            failures += 1
        }
    }

    static func main() {
        testCheckDecision()
        testVerificationDecision()
        testInstallMethod()
        testResultParsing()
        testLastOutcome()
        testScriptText()
        testScriptRuns()

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 检查之后的判定

    static func testCheckDecision() {
        print("== 检查结果 → 下一步 ==")

        check("版本更高 → 去下载",
              UpdateFlow.action(afterCheck: "1.11.0", releaseVersion: "1.11.1")
                == .download(version: "1.11.1"))
        check("同版本 → 什么都不做（不能反复装同一个版本）",
              UpdateFlow.action(afterCheck: "1.11.0", releaseVersion: "1.11.0")
                == .none)
        check("更旧的版本 → 什么都不做（不能降级）",
              UpdateFlow.action(afterCheck: "1.11.0", releaseVersion: "1.10.0")
                == .none)
        check("版本号解析不了 → 什么都不做",
              UpdateFlow.action(afterCheck: "1.11.0", releaseVersion: "banana")
                == .none)
        check("\"1.10.0\" 比 \"1.9.0\" 新（数字段比较，不是字符串比较）",
              UpdateFlow.action(afterCheck: "1.9.0", releaseVersion: "1.10.0")
                == .download(version: "1.10.0"))

        // 关键回归：以前自动检查在这之前就 return 了，包根本没下过。
        // 现在「发现新版本」之后的动作只能是下载，不存在「停在发现」这个出口。
        for release in ["1.11.1", "1.12.0", "2.0.0"] {
            let action = UpdateFlow.action(afterCheck: "1.11.0", releaseVersion: release)
            check("发现 \(release) 之后必定进入下载",
                  action == .download(version: release), "\(action)")
        }
    }

    // MARK: - 校验之后的判定

    static func testVerificationDecision() {
        print("\n== 校验通过之后 → 下一步 ==")

        check("开着「装之前先问我一句」→ 等用户确认",
              UpdateFlow.action(afterVerification: "1.11.1", asksBeforeInstalling: true)
                == .awaitConfirmation(version: "1.11.1"))
        check("关着「装之前先问我一句」→ 直接装",
              UpdateFlow.action(afterVerification: "1.11.1", asksBeforeInstalling: false)
                == .install(version: "1.11.1"))
    }

    // MARK: - 提权

    static func testInstallMethod() {
        print("\n== 要不要提权 ==")

        check("目标目录可写 → 直接换",
              UpdateFlow.installMethod(targetDirectoryWritable: true) == .direct)
        check("目标目录不可写（/Applications）→ 需要管理员权限",
              UpdateFlow.installMethod(targetDirectoryWritable: false) == .elevated)
    }

    // MARK: - 结果文件

    static func testResultParsing() {
        print("\n== 结果文件解析 ==")

        let ok = UpdateFlow.InstallResult.parse(
            "status=success\nversion=1.11.1\nmessage=已更新到 1.11.1\n")
        check("成功结果解析得出来", ok?.status == .success)
        check("成功结果带着版本号", ok?.version == "1.11.1")
        check("成功结果带着说明", ok?.message == "已更新到 1.11.1")

        let bad = UpdateFlow.InstallResult.parse(
            "status=failure\nversion=1.11.1\nmessage=无法移动旧版本（可能需要管理员权限）：Permission denied\n")
        check("失败结果解析得出来", bad?.status == .failure)
        check("失败原因原样保留",
              bad?.message.contains("需要管理员权限") == true)

        check("没有 status → 认不出来（宁可显示不知道，也不猜）",
              UpdateFlow.InstallResult.parse("version=1.11.1\nmessage=hi\n") == nil)
        check("空文件 → 认不出来", UpdateFlow.InstallResult.parse("") == nil)
        check("乱内容 → 认不出来", UpdateFlow.InstallResult.parse("hello world") == nil)
        check("status 值不认识 → 认不出来",
              UpdateFlow.InstallResult.parse("status=maybe\n") == nil)

        // 说明里带等号时不能被截断 —— 错误信息里常有路径和参数。
        let withEquals = UpdateFlow.InstallResult.parse(
            "status=failure\nmessage=命令失败: mv -f a=b\n")
        check("说明里有等号也不截断", withEquals?.message == "命令失败: mv -f a=b",
              withEquals?.message ?? "nil")

        // 结果文件是逐行键值，末尾没有换行也要认得出来。
        let noTrailingNewline = UpdateFlow.InstallResult.parse(
            "status=success\nversion=1.11.1")
        check("最后一行没有换行也认得出来", noTrailingNewline?.version == "1.11.1")
    }

    // MARK: - 上一次结果的显示形态

    static func testLastOutcome() {
        print("\n== 上一次更新结果的显示 ==")

        check("没装过时状态词是「未装过」",
              UpdateFlow.LastOutcome.never.statusText == "未装过")
        check("成功状态词是「成功」",
              UpdateFlow.LastOutcome.success(version: "1.11.1", message: "").statusText == "成功")
        check("失败状态词是「失败」",
              UpdateFlow.LastOutcome.failure(version: nil, message: "").statusText == "失败")

        let summary = UpdateFlow.LastOutcome.success(version: "1.11.1", message: "已更新到 1.11.1").summary
        check("成功摘要带版本号", summary.contains("1.11.1"), summary)
        check("成功摘要写明「成功」", summary.contains("成功"), summary)

        let failure = UpdateFlow.LastOutcome.failure(version: nil, message: "装不上").summary
        check("失败摘要写明「失败」", failure.contains("失败"), failure)
        check("失败摘要带上原因", failure.contains("装不上"), failure)

        // 结果文件 → 显示形态的转换
        let parsed = UpdateFlow.InstallResult.parse("status=failure\nmessage=需要管理员权限\n")
        check("结果文件能转成显示形态",
              parsed.map { UpdateFlow.LastOutcome($0) } == .failure(version: nil,
                                                                message: "需要管理员权限"))
    }

    // MARK: - 脚本文本

    static func testScriptText() {
        print("\n== 更新器脚本的内容 ==")

        let script = UpdateFlow.updaterScript(
            target: "/Applications/Deep Sleep.app",
            source: "/tmp/work/New.app",
            workDirectory: "/tmp/work",
            pid: 4242,
            resultPath: "/tmp/result.txt",
            version: "1.11.1")

        check("脚本带着结果文件路径", script.contains("/tmp/result.txt"))
        check("脚本带着新版本号", script.contains("1.11.1"))
        check("脚本会写结果状态", script.contains("status="))
        check("脚本会等应用退出", script.contains("kill -0"))
        check("脚本失败时把旧的放回原位", script.contains("\"$OLD\" \"$TARGET\""))
        check("脚本不会先删掉旧应用", !script.contains("rm -rf \"$TARGET\""))
        check("脚本里的目标路径被正确引用", script.contains("'/Applications/Deep Sleep.app'"))

        // 不传结果路径时（--update-script 打印用的那份）脚本依然合法。
        let noResult = UpdateFlow.updaterScript(
            target: "/tmp/Target.app",
            source: "/tmp/New.app",
            workDirectory: "/tmp",
            pid: 1,
            resultPath: "",
            version: "")
        check("不传结果路径时脚本不写结果", noResult.contains("RESULT=''"))
    }

    // MARK: - 脚本真跑一遍

    static func testScriptRuns() {
        print("\n== 更新器脚本实跑（假目录）==")

        guard let deadPID = findDeadPID() else {
            check("找一个已经退出的进程号", false, "找不到")
            return
        }

        // 场景一：替换成功。
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let work = root + "/work"
        let targetDir = root + "/target"
        let sourceApp = work + "/New.app"
        let targetApp = targetDir + "/Target.app"
        let result = root + "/result.txt"

        try? FileManager.default.createDirectory(atPath: sourceApp,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: targetApp,
                                                 withIntermediateDirectories: true)
        try? "新版本".write(toFile: sourceApp + "/marker.txt",
                            atomically: true, encoding: .utf8)
        try? "旧版本".write(toFile: targetApp + "/marker.txt",
                            atomically: true, encoding: .utf8)

        let scriptPath = work + "/updater.sh"
        let script = UpdateFlow.updaterScript(
            target: targetApp,
            source: sourceApp,
            workDirectory: work,
            pid: deadPID,
            resultPath: result,
            version: "1.11.1")
        write(script: script, to: scriptPath)

        check("生成的脚本语法合法", shellSyntaxOK(scriptPath))
        runShell(scriptPath)

        let replaced = (try? String(contentsOfFile: targetApp + "/marker.txt",
                                    encoding: .utf8)) ?? ""
        check("旧应用被换成了新版本", replaced.contains("新版本"), replaced)
        check("旧版本没有被留在原处",
              !FileManager.default.fileExists(atPath: targetApp + "/updating"))

        let text = (try? String(contentsOfFile: result, encoding: .utf8)) ?? ""
        let parsed = UpdateFlow.InstallResult.parse(text)
        check("脚本把成功写进了结果文件", parsed?.status == .success, text)
        check("结果文件里带着版本号", parsed?.version == "1.11.1", text)

        // 场景二：目标目录不可写 —— 替换必须失败，而且必须说清楚。
        if getuid() == 0 {
            print("  [跳过] 目标目录不可写的场景（当前是 root，权限拦不住它）")
        } else {
            let root2 = makeTempRoot()
            defer { try? FileManager.default.removeItem(atPath: root2) }

            let work2 = root2 + "/work"
            let targetDir2 = root2 + "/target"
            let sourceApp2 = work2 + "/New.app"
            let targetApp2 = targetDir2 + "/Target.app"
            let result2 = root2 + "/result.txt"

            try? FileManager.default.createDirectory(atPath: sourceApp2,
                                                     withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: targetApp2,
                                                     withIntermediateDirectories: true)
            try? "新版本".write(toFile: sourceApp2 + "/marker.txt",
                                atomically: true, encoding: .utf8)
            try? "旧版本".write(toFile: targetApp2 + "/marker.txt",
                                atomically: true, encoding: .utf8)

            let scriptPath2 = work2 + "/updater.sh"
            let script2 = UpdateFlow.updaterScript(
                target: targetApp2,
                source: sourceApp2,
                workDirectory: work2,
                pid: deadPID,
                resultPath: result2,
                version: "1.11.1")
            write(script: script2, to: scriptPath2)

            // 把目标目录变成只读 —— 当前的普通用户就写不进去了。
            try? FileManager.default.setAttributes([.posixPermissions: 0o500],
                                                   ofItemAtPath: targetDir2)
            runShell(scriptPath2)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: targetDir2)

            let stillOld = (try? String(contentsOfFile: targetApp2 + "/marker.txt",
                                        encoding: .utf8)) ?? ""
            check("换不动的时候旧版本原样还在", stillOld.contains("旧版本"), stillOld)

            let text2 = (try? String(contentsOfFile: result2, encoding: .utf8)) ?? ""
            let parsed2 = UpdateFlow.InstallResult.parse(text2)
            check("换不动的时候结果文件写的是失败", parsed2?.status == .failure, text2)
            check("失败原因里点明可能要管理员权限",
                  parsed2?.message.contains("管理员权限") == true, parsed2?.message ?? "")
        }
    }

    // MARK: - 工具

    static func makeTempRoot() -> String {
        let path = NSTemporaryDirectory() + "ds-update-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: path,
                                                 withIntermediateDirectories: true)
        return path
    }

    /// 找一个已经不存在的进程号 —— 脚本会立刻跳过「等应用退出」那一段。
    static func findDeadPID() -> Int32? {
        for candidate in stride(from: 999_000, to: 999_100, by: 1) {
            if kill(pid_t(candidate), 0) != 0 { return Int32(candidate) }
        }
        return nil
    }

    static func write(script: String, to path: String) {
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: path)
    }

    /// `sh -n` 只做语法检查，不执行任何东西。
    static func shellSyntaxOK(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func runShell(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return }
        process.waitUntilExit()
    }
}
