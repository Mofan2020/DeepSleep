//
//  ProcessStats.swift
//  Deep Sleep
//
//  一次系统进程采样的快照（PID / 名字 / RSS / CPU% / 启动时间）。
//  **应用与特权助手编译同一份。**
//
//  为什么必须共用：监控的判定逻辑在主应用，原始数据由特权助手抓 ——
//  编码与解码两边各写一份就会漂移，最终表现是「助手报告的进程，UI 找不到」。
//  这与 `Shared/PMSetOutput.swift` / `Shared/TerminationReport.swift` 的
//  共用理由完全相同。
//
//  协议格式与 `TerminationReport` 一致：每个字段百分号编码，字段间用 `|`，
//  记录间用 `,`。进程名里出现的中文、竖线、逗号、空格、换行都靠百分号
//  编码吃下；编码器只允许 `[a-zA-Z0-9]` 之外的字符走编码通道。
//

import Foundation

public struct ProcessStats: Sendable, Equatable {

    /// 一条进程记录。
    public struct Record: Sendable, Equatable {
        public let pid: pid_t
        public let name: String
        public let rssBytes: UInt64
        /// 相对上一采样点的 CPU 占用百分比（0–N×100，N 为逻辑核数）。
        /// 第一次采样永远为 0；这是显式约定，不是「计算不出来」。
        public let cpuPercent: Double
        /// 进程启动时刻的 unix epoch 秒；读不到时为 0。
        public let startTime: Int64

        public init(pid: pid_t,
                    name: String,
                    rssBytes: UInt64,
                    cpuPercent: Double,
                    startTime: Int64) {
            self.pid = pid
            self.name = name
            self.rssBytes = rssBytes
            self.cpuPercent = cpuPercent
            self.startTime = startTime
        }
    }

    public var records: [Record]

    public init(records: [Record] = []) {
        self.records = records
    }

    // MARK: - 编解码

    public func encode() -> [String: String] {
        [
            "records": Self.encodeRecords(records),
            "count": "\(records.count)"
        ]
    }

    public static func decode(_ payload: [String: String]) -> ProcessStats {
        let records = decodeRecords(payload["records"])
        return ProcessStats(records: records)
    }

    private static func encodeRecords(_ records: [Record]) -> String {
        records.map { record in
            let fields = [
                String(record.pid),
                escape(record.name),
                String(record.rssBytes),
                String(record.cpuPercent),
                String(record.startTime)
            ]
            return fields.joined(separator: "|")
        }.joined(separator: ",")
    }

    private static func decodeRecords(_ raw: String?) -> [Record] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",", omittingEmptySubsequences: false).compactMap { entry in
            let fields = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let pid = pid_t(fields[0]) else { return nil }
            return Record(
                pid: pid,
                name: unescape(fields[1]),
                rssBytes: UInt64(fields[2]) ?? 0,
                cpuPercent: Double(fields[3]) ?? 0,
                startTime: Int64(fields[4]) ?? 0
            )
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