//
//  TerminationReport.swift
//  Deep Sleep
//
//  一次强杀的结果，以及它在 socket 上的编解码。**应用与特权助手编译同一份。**
//
//  协议里的 payload 是 `[String: String]`，所以结果必须压成字符串。
//  编解码放在共享代码里而不是两边各写一份：这两个方向必须严格互逆，
//  而「加密和解密各写一遍」是这个项目已经吃过大亏的地方
//  （见 `Shared/PMSetOutput.swift` 与 docs/gotchas.md 第 1 条）。
//
//  进程名可能包含 `|` `,` `:` 等分隔符（中文名、带括号的名字都很常见），
//  因此每个字段单独做百分号编码，不靠「名字里不会有分隔符」这种假设。
//

import Foundation

public struct TerminationReport: Sendable, Equatable {

    public struct Record: Sendable, Equatable {
        public let pid: pid_t
        public let name: String
        public init(pid: pid_t, name: String) {
            self.pid = pid
            self.name = name
        }
    }

    public struct Refusal: Sendable, Equatable {
        public let pid: pid_t
        public let name: String
        public let reason: String
        public init(pid: pid_t, name: String, reason: String) {
            self.pid = pid
            self.name = name
            self.reason = reason
        }
    }

    /// 成功杀掉（或请求时已经不在）的进程。
    public var killed: [Record] = []
    /// 因保护规则被拒绝的进程。
    public var refused: [Refusal] = []
    /// 尝试了但失败的进程，reason 是 errno 的说明。
    public var failed: [Refusal] = []
    /// 因为落在被保护进程的子树里而一并跳过的进程数。
    public var skippedDescendants: Int = 0

    public init(killed: [Record] = [],
                refused: [Refusal] = [],
                failed: [Refusal] = [],
                skippedDescendants: Int = 0) {
        self.killed = killed
        self.refused = refused
        self.failed = failed
        self.skippedDescendants = skippedDescendants
    }

    public var totalAffected: Int { killed.count + refused.count + failed.count }

    /// 合并另一份报告。应用的本地回退路径会按目标逐个执行，逐个合并。
    public mutating func merge(_ other: TerminationReport) {
        killed.append(contentsOf: other.killed)
        refused.append(contentsOf: other.refused)
        failed.append(contentsOf: other.failed)
        skippedDescendants += other.skippedDescendants
    }

    /// 给人看的一句话。UI 与日志共用，避免两处措辞不一致。
    public var summary: String {
        if totalAffected == 0 { return "没有需要退出的进程" }
        var parts = ["已退出 \(killed.count) 个进程"]
        if !refused.isEmpty { parts.append("受保护跳过 \(refused.count) 个") }
        if !failed.isEmpty { parts.append("失败 \(failed.count) 个") }
        return parts.joined(separator: "，")
    }

    public var isClean: Bool { refused.isEmpty && failed.isEmpty }

    // MARK: - 编解码

    public func encode() -> [String: String] {
        [
            "killed": Self.encodeRecords(killed.map { ($0.pid, $0.name, nil) }),
            "refused": Self.encodeRecords(refused.map { ($0.pid, $0.name, $0.reason) }),
            "failed": Self.encodeRecords(failed.map { ($0.pid, $0.name, $0.reason) }),
            "skipped": "\(skippedDescendants)"
        ]
    }

    public static func decode(_ payload: [String: String]) -> TerminationReport {
        TerminationReport(
            killed: decodeRecords(payload["killed"]).map {
                Record(pid: $0.pid, name: $0.name)
            },
            refused: decodeRecords(payload["refused"]).map {
                Refusal(pid: $0.pid, name: $0.name, reason: $0.reason)
            },
            failed: decodeRecords(payload["failed"]).map {
                Refusal(pid: $0.pid, name: $0.name, reason: $0.reason)
            },
            skippedDescendants: payload["skipped"].flatMap { Int($0) } ?? 0
        )
    }

    private static func encodeRecords(_ records: [(pid_t, String, String?)]) -> String {
        records.map { pid, name, reason in
            let fields = [String(pid), escape(name), escape(reason ?? "")]
            return fields.joined(separator: "|")
        }.joined(separator: ",")
    }

    private static func decodeRecords(_ raw: String?) -> [(pid: pid_t, name: String, reason: String)] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").compactMap { entry in
            let fields = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, let pid = pid_t(fields[0]) else { return nil }
            return (pid, unescape(fields[1]), unescape(fields[2]))
        }
    }

    private static let safeCharacters = CharacterSet.alphanumerics

    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: safeCharacters) ?? ""
    }

    private static func unescape(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }
}
