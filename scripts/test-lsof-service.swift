//
//  test-lsof-service.swift
//  DeepSleep
//
//  LsofService 的解析与校验自测。
//  测的是真实源码 DeepSleep/Core/LsofService.swift。
//
//  为什么这层要单独测：lsof 输出格式是本工具唯一的外部契约。
//  一旦解析错位，表现是**静默错误** —— 界面上少几条、多几条，
//  用户看到的是一份「看起来挺正常」的列表，不会知道漏了东西。
//  格式回归（换 lsof 版本、改字段集）也只会在这里被挡住。
//
//  运行： bash scripts/run-all-tests.sh
//

import Foundation

@main
struct LsofServiceTests {

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

        func checkEqual<T: Equatable>(_ name: String, _ lhs: T, _ rhs: T) {
            if lhs == rhs {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)：期望 \(rhs)，实际 \(lhs)")
                failures += 1
            }
        }

        // MARK: - -F pcuftn 机器格式

        print("\n== -F pcuftn 机器格式 ==")

        // 实测样本：rapportd 一个进程两个 fd。
        let fieldSample = """
        p1171
        crapportd
        u501
        f11
        tIPv6
        n*:52631
        f13
        tIPv4
        n*:49217
        """

        let parsed = LsofService.parseFieldOutput(fieldSample)
        checkEqual("样本解析出 2 条记录", parsed.count, 2)

        if parsed.count == 2 {
            checkEqual("第一条的 pid", parsed[0].pid, 1171)
            checkEqual("第一条的进程名", parsed[0].command, "rapportd")
            checkEqual("第一条的用户", parsed[0].user, "501")
            checkEqual("第一条的 fd", parsed[0].fd, "11")
            checkEqual("第一条的类型", parsed[0].type, "IPv6")
            checkEqual("第一条的名称", parsed[0].name, "*:52631")

            checkEqual("第二条的 pid", parsed[1].pid, 1171)
            checkEqual("第二条的进程名", parsed[1].command, "rapportd")
            checkEqual("第二条的用户", parsed[1].user, "501")
            checkEqual("第二条的 fd", parsed[1].fd, "13")
            checkEqual("第二条的类型", parsed[1].type, "IPv4")
            checkEqual("第二条的名称", parsed[1].name, "*:49217")
        }

        // MARK: - 多个进程切分

        print("\n== 多个进程连续出现 ==")

        let multiProcess = """
        p1171
        crapportd
        u501
        f11
        tIPv6
        n*:52631
        p1603
        cWeChat
        u501
        f173
        tIPv4
        n127.0.0.1:14013
        p1892
        cpython3.14
        u501
        f13
        tIPv4
        n127.0.0.1:9119
        """

        let multi = LsofService.parseFieldOutput(multiProcess)
        checkEqual("三个进程切出三条记录", multi.count, 3)
        if multi.count == 3 {
            checkEqual("第 1 个是 rapportd", multi[0].command, "rapportd")
            checkEqual("第 2 个是 WeChat", multi[1].command, "WeChat")
            checkEqual("第 3 个是 python3.14", multi[2].command, "python3.14")
            checkEqual("第 2 个进程的 pid", multi[1].pid, 1603)
            checkEqual("第 3 个进程的 pid", multi[2].pid, 1892)
            checkEqual("第 3 个进程的 fd", multi[2].fd, "13")
            checkEqual("第 3 个进程的名称", multi[2].name, "127.0.0.1:9119")
        }

        // MARK: - 同一进程多个 fd

        print("\n== 同一进程多个 fd ==")

        let twoFDs = LsofService.parseFieldOutput(fieldSample)
        checkEqual("同一进程两个 fd 出两条记录", twoFDs.count, 2)
        if twoFDs.count == 2 {
            check("两条记录 fd 不同", twoFDs[0].fd != twoFDs[1].fd,
                  "\(twoFDs[0].fd) / \(twoFDs[1].fd)")
            check("两条记录 pid 相同", twoFDs[0].pid == twoFDs[1].pid)
            check("两条记录进程名相同", twoFDs[0].command == twoFDs[1].command)
            check("两条记录 id 不相同", twoFDs[0].id != twoFDs[1].id)
        }

        // 同一段内容重复喂两次 —— id 去重后条数不该翻倍。
        let duplicated = LsofService.parseFieldOutput(fieldSample + "\n" + fieldSample)
        checkEqual("重复内容不产生重复记录", duplicated.count, 2)
        checkEqual("重复内容后 id 仍然唯一", Set(duplicated.map(\.id)).count, duplicated.count)

        // MARK: - L / P 字段

        print("\n== L（登录名）与 P（协议）字段 ==")

        let withLogin = """
        p1171
        crapportd
        u501
        Lmofan
        f11
        tIPv6
        PTCP
        n*:52631
        """
        let loginParsed = LsofService.parseFieldOutput(withLogin)
        checkEqual("带 L 字段出一条记录", loginParsed.count, 1)
        if let first = loginParsed.first {
            checkEqual("L 字段优先于 uid", first.user, "mofan")
            checkEqual("P 字段解析成协议", first.protocolName ?? "", "TCP")
        }

        // 没有 L 字段时退回 uid。
        let noLogin = LsofService.parseFieldOutput(fieldSample)
        checkEqual("没有 L 字段时用户是 uid", noLogin.first?.user ?? "", "501")

        // MARK: - 空输出

        print("\n== 空输出 ==")

        checkEqual("空字符串返回空数组", LsofService.parseFieldOutput("").count, 0)
        checkEqual("只有换行返回空数组", LsofService.parseFieldOutput("\n\n\n").count, 0)
        checkEqual("空输出走 parse 同样返回空数组", LsofService.parse("").count, 0)

        // MARK: - 人类可读表格格式

        print("\n== 人类可读表格格式 ==")

        // 真实 lsof 输出抓的样本（网络查询的表头 + 两行）。
        let tableSample = """
        COMMAND     PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        rapportd   1171 mofan   11u  IPv6 0xa221b14cde988dc3      0t0  TCP *:52641 (LISTEN)
        rapportd   1171 mofan   13u  IPv4 0xbc3ff29a7c358865      0t0  TCP *:49217 (LISTEN)
        """

        let tableParsed = LsofService.parseTableOutput(tableSample)
        checkEqual("表格解析出两条记录", tableParsed.count, 2)
        if tableParsed.count == 2 {
            checkEqual("表格第 1 条的进程名", tableParsed[0].command, "rapportd")
            checkEqual("表格第 1 条的 pid", tableParsed[0].pid, 1171)
            checkEqual("表格第 1 条的用户", tableParsed[0].user, "mofan")
            checkEqual("表格第 1 条的 fd（去掉访问模式后缀）", tableParsed[0].fd, "11")
            checkEqual("表格第 1 条的类型", tableParsed[0].type, "IPv6")
            checkEqual("表格第 1 条的名称", tableParsed[0].name, "*:52641 (LISTEN)")

            checkEqual("表格第 2 条的 pid", tableParsed[1].pid, 1171)
            checkEqual("表格第 2 条的 fd", tableParsed[1].fd, "13")
            checkEqual("表格第 2 条的类型", tableParsed[1].type, "IPv4")
            checkEqual("表格第 2 条的名称", tableParsed[1].name, "*:49217 (LISTEN)")
        }

        // 文件列表的表头更宽（列数多一列），NAME 列的偏移不一样。
        // 真实 lsof 输出抓的样本。
        let fileTableSample = """
        COMMAND     PID  USER   FD      TYPE             DEVICE     SIZE/OFF                NODE NAME
        ThemeWidg   142 mofan  cwd       DIR               1,13          736                   2 /
        ThemeWidg   142 mofan  txt       REG               1,13       537312 1152921500312152144 /System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/ThemeWidgetControlViewService.xpc/Contents/MacOS/ThemeWidgetControlViewService
        """

        let fileParsed = LsofService.parseTableOutput(fileTableSample)
        checkEqual("文件表格解析出两条记录", fileParsed.count, 2)
        if fileParsed.count == 2 {
            checkEqual("文件表格第 1 条的进程名", fileParsed[0].command, "ThemeWidg")
            checkEqual("文件表格第 1 条的 pid", fileParsed[0].pid, 142)
            checkEqual("文件表格第 1 条的 fd", fileParsed[0].fd, "cwd")
            checkEqual("文件表格第 1 条的类型", fileParsed[0].type, "DIR")
            checkEqual("文件表格第 1 条的名称", fileParsed[0].name, "/")

            checkEqual("文件表格第 2 条的 fd", fileParsed[1].fd, "txt")
            checkEqual("文件表格第 2 条的类型", fileParsed[1].type, "REG")
            check("文件表格第 2 条的名称是完整路径",
                  fileParsed[1].name.hasSuffix("ThemeWidgetControlViewService"),
                  fileParsed[1].name)
        }

        // 表头行不能被当成数据行。
        check("表头不会被解析成记录", !LsofService.parseTableOutput(tableSample)
            .contains { $0.command == "COMMAND" })

        // parse 自动识别格式：表格走表格分支，机器格式走机器分支。
        checkEqual("parse 自动识别表格格式", LsofService.parse(tableSample).count, 2)
        checkEqual("parse 自动识别机器格式", LsofService.parse(fieldSample).count, 2)

        // MARK: - 端口校验

        print("\n== 端口校验 ==")

        check("端口 0 被拒", !LsofService.isValidPort(0))
        check("端口 65536 被拒", !LsofService.isValidPort(65536))
        check("负端口被拒", !LsofService.isValidPort(-1))
        check("端口 1 有效", LsofService.isValidPort(1))
        check("端口 65535 有效", LsofService.isValidPort(65535))
        check("端口 8080 有效", LsofService.isValidPort(8080))

        check("文本 \"0\" 解析失败", LsofService.parsePortText("0") == nil)
        check("文本 \"65536\" 解析失败", LsofService.parsePortText("65536") == nil)
        check("文本 \"-1\" 解析失败", LsofService.parsePortText("-1") == nil)
        check("文本 \"abc\" 解析失败", LsofService.parsePortText("abc") == nil)
        check("文本 \"80a\" 解析失败", LsofService.parsePortText("80a") == nil)
        check("文本 \"\" 解析失败", LsofService.parsePortText("") == nil)
        checkEqual("文本 \"8080\" 解析成 8080", LsofService.parsePortText("8080") ?? -1, 8080)
        checkEqual("文本 \" 443 \" 忽略空格后解析成 443", LsofService.parsePortText(" 443 ") ?? -1, 443)

        // MARK: - PID 与路径校验

        print("\n== PID 与路径校验 ==")

        check("PID 0 被拒", !LsofService.isValidPID(0))
        check("负 PID 被拒", !LsofService.isValidPID(-3))
        check("PID 501 有效", LsofService.isValidPID(501))
        check("文本 \"abc\" 不是 PID", LsofService.parsePIDText("abc") == nil)
        checkEqual("文本 \"501\" 解析成 PID", LsofService.parsePIDText("501") ?? -1, 501)

        check("空路径无效", !LsofService.isValidPath(""))
        check("普通路径有效", LsofService.isValidPath("/tmp"))

        // MARK: - 退出码语义
        //
        // lsof 在混合查询（`-iTCP:port -iUDP:port`）时，只要有一个分支
        // 没匹配上就返回退出码 1，但另一个分支的结果照常输出到 stdout。
        // 实测「TCP 有、UDP 没有」时：退出码 1、stderr 空、stdout 有 9 行
        // 有效记录 —— 早期版本在这里直接返回空列表，把有结果的查询报成
        // 「没有占用」。
        print("\n== 退出码语义 ==")

        let mixedOutput = """
        p1171
        crapportd
        u501
        f13
        tIPv4
        n*:49217
        f14
        tIPv6
        n*:49217

        """
        // 退出码 1 + stdout 有内容 → 照样解析出来
        do {
            let entries = try LsofService.interpret(
                LsofService.RunResult(status: 1, stdout: mixedOutput, stderr: ""))
            checkEqual("退出码 1 但 stdout 有内容时照样解析出记录", entries.count, 2)
            check("解析出的记录有 PID", entries.first?.pid ?? 0 > 0)
            check("解析出的记录有进程名", entries.first?.command == "rapportd")
        } catch {
            check("退出码 1 但 stdout 有内容时能解析", false, error.localizedDescription)
        }

        // 退出码 1 + stdout 空 + stderr 空 → 「没有占用」，不是错误
        do {
            let entries = try LsofService.interpret(
                LsofService.RunResult(status: 1, stdout: "", stderr: ""))
            checkEqual("退出码 1 且什么都没有时返回空列表（不是错误）", entries.count, 0)
        } catch {
            check("退出码 1 且什么都没有时不该报错", false, error.localizedDescription)
        }

        // 退出码非 0 + stderr 有内容 → 真错误，要抛出来
        var threw = false
        var message = ""
        do {
            _ = try LsofService.interpret(
                LsofService.RunResult(status: 1, stdout: "",
                                     stderr: "lsof: status error on /tmp\nlsof 4.99.0\n"))
        } catch {
            threw = true
            message = error.localizedDescription
        }
        check("退出码非 0 且 stderr 有内容时报错", threw)
        check("错误文案取 stderr 第一行（不含版本横幅）",
              message.contains("status error") && !message.contains("4.99.0"),
              message)

        // MARK: - 错误文案
        print("\n== 错误文案 ==")

        // 只实现 CustomStringConvertible 的话，localizedDescription 给的是
        // 系统那句 "The operation couldn't be completed."，用户看不到原因。
        let errors: [LsofService.LsofError] = [
            .invalidPort(99999),
            .invalidPID(-1),
            .invalidPath(""),
            .pathNotFound("/不存在"),
            .timedOut(10),
            .launchFailed("no such file"),
            .commandFailed("boom")
        ]
        for error in errors {
            let localized = error.localizedDescription
            check("错误文案不是系统默认文案：\(error)",
                  !localized.contains("couldn’t be completed")
                    && !localized.contains("couldn't be completed"),
                  localized)
            check("错误文案有实际内容：\(error)", !localized.isEmpty, localized)
        }

        // MARK: - 常量

        print("\n== 常量 ==")

        checkEqual("lsof 路径固定", LsofService.executablePath, "/usr/sbin/lsof")
        checkEqual("端口上界", LsofService.portRange.upperBound, 65535)
        checkEqual("端口下界", LsofService.portRange.lowerBound, 1)

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
