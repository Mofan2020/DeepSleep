//
//  PMSetOutput.swift
//  Deep Sleep
//
//  `pmset -g` 输出的解析。
//
//  为什么放在 Shared/ 而不是各写一份：app 与特权助手都要读这份输出，
//  而它们原本各有一份几乎相同的解析代码 —— 结果是同一个 bug 存在两处，
//  修一处漏一处。共享一份实现就没有这个问题。
//

import Foundation

enum PMSetOutput {

    /// 解析 `pmset -g` 的输出，得到键值对。
    ///
    /// **分隔符不统一是这个函数存在的唯一理由**，也是最容易踩的坑：
    ///
    /// ```
    /// System-wide power settings:
    ///  SleepDisabled\t\t1        ← TAB 分隔
    /// Currently in use:
    ///  standby              0    ← 空格对齐
    /// ```
    ///
    /// 只按空格切会漏掉 `SleepDisabled`。而对账逻辑正是靠它判断
    /// 「完全禁止睡眠」是否还有效 —— 漏掉之后每次对账都会认为设置被外部改回，
    /// 每 3 秒重写一遍并刷满日志，而系统里的值其实一直是对的。
    static func parse(_ text: String) -> [String: String] {
        var settings: [String: String] = [:]

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // 段落标题（`System-wide power settings:`）只有冒号没有值，跳过。
            guard !line.isEmpty, !line.hasSuffix(":") else { continue }

            // 先把 TAB 归一成空格，再按「首个空白处」切一次，
            // 这样两种分隔符都能正确处理。连续空白由
            // omittingEmptySubsequences 消化掉。
            let normalized = line.replacingOccurrences(of: "\t", with: " ")
            let parts = normalized.split(separator: " ",
                                         maxSplits: 1,
                                         omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }

            var value = parts[1].trimmingCharacters(in: .whitespaces)
            // `sleep 1 (sleep prevented by powerd, ...)` → 只保留数值部分。
            if let paren = value.firstIndex(of: "(") {
                value = String(value[value.startIndex..<paren])
                    .trimmingCharacters(in: .whitespaces)
            }
            settings[String(parts[0])] = value
        }

        return settings
    }

    /// 读取当前系统电源设置。`pmset -g` 是只读的，不需要 root。
    static func readCurrent() -> [String: String] {
        parse(run(["-g"]))
    }

    // MARK: - 执行

    /// 跑一个外部命令并返回标准输出（stdout 与 stderr 合并，
    /// 这样失败原因也能被调用方看到）。
    static func run(_ arguments: [String], executable: String = "/usr/bin/pmset") -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
