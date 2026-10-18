//
//  DiskUsage.swift
//  Deep Sleep
//
//  读取根卷「总量 + 已用量」，UI 「系统状态」卡用。
//
//  用 Foundation 的 URL resourceValues 而不是 statvfs / sysctlbyname ——
//  前者一行写完且 Swift 直接拿 .volumeTotalCapacityKey / .volumeAvailableCapacityKey，
//  后者要解 C 接口。盘使用率只显示根卷；其他卷（外接盘 / 时间机器）不展开，
//  Deep Sleep 主流程用不到。
//
//  失败一律返回 .empty —— UI 上显示「—」即可，不报错。
//

import Foundation

enum DiskUsage {

    struct Sample: Sendable, Equatable {
        let totalBytes: UInt64
        let availableBytes: UInt64
        let updatedAt: Date

        var usedBytes: UInt64 { totalBytes >= availableBytes ? totalBytes - availableBytes : 0 }
        var usedFraction: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(usedBytes) / Double(totalBytes)
        }

        static let empty = Sample(totalBytes: 0, availableBytes: 0, updatedAt: .distantPast)

        var isEmpty: Bool { totalBytes == 0 }
    }

    /// 读根卷用量。失败 → .empty。
    static func current() -> Sample {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity else {
            return .empty
        }
        return Sample(
            totalBytes: UInt64(total),
            availableBytes: UInt64(available),
            updatedAt: Date()
        )
    }
}
