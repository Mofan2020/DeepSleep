//
//  FanModels.swift
//  Deep Sleep
//
//  风扇状态与温度快照的数据模型 + 编解码。
//  **应用与特权助手编译同一份**（放在 Shared/ 目录，两个 target 都包含它）。
//
//  编码沿用 ProcessStats / TerminationReport 的既有约定：
//  百分号编码 + 字段间 `|` + 记录间 `,`。不走 JSON ——
//  helper 与应用各自只依赖 Foundation，关键路径上不引入 JSON 解析器。
//
//  为什么数据模型要共用：风扇写入是「应用决定、助手执行」的两段式，
// 判定策略在应用侧、执行在助手侧。两边如果各写一份模型，字段一漂移
// 就会出现「助手报告了风扇，UI 显示不出来」这类静默错误。
//
//  字段契约见 docs/protocol-contract-v1.9.md。
//

import Foundation

/// 风扇控制相关的共享常量。
public enum FanControl {

    /// 租约秒数：助手在这么久没收到同风扇的新指令就把该风扇交回系统自动控制。
    ///
    /// 为什么必须有租约：手动模式下风扇转速不再由 SMC 决定，
    /// 而是由「谁写的」决定。如果写风扇的进程死了而手动模式还留着，
    /// 风扇就会永久停在一个（可能很低的）转速 —— 等于把散热交给一个
    /// 已经不存在的进程。租约让助手能在应用消失后自动收回控制权。
    public static let leaseSeconds = 15

    /// 助手侧心跳周期（秒）：检查租约是否到期。
    public static let heartbeatSeconds = 5

    /// 强制最大转速的温度阈值（°C）。
    ///
    /// 任意一个传感器的读数达到或超过它，就立刻把所有风扇拉到最大，
    /// 压过用户设置的任何模式与规则。这是用户明确要求的硬底线。
    public static let emergencyTemperatureCelsius = 90.0

    /// 写目标转速时的安全下限（相对该风扇的 minRPM）。
    ///
    /// SMC.md §2.6.1 指出：目标 RPM 低于该机型的 F0Mn 时，
    /// 部分机型会拒绝执行。留 5% 余量，避免踩在那条边界上。
    public static let minRpmSafetyRatio = 0.95

    /// 紧急兜底解除前的冷却时间（秒）。
    ///
    /// 温度掉到阈值以下就立刻恢复原模式的话，机器在阈值附近抖动时
    /// 风扇会反复启停 —— 听起来像在喘气，实际也增加噪音和机械磨损。
    /// 冷却期内保持最大转速，等温度真正稳下来再交还控制权。
    public static let emergencyCooldownSeconds = 60.0

    /// 风扇连续写不进多久算「持续改不动」（秒）。
    ///
    /// 超过这个时间还改不动，就不再继续修改它的转速，交回系统控制。
    /// 定 60 秒的理由：SMC 写入偶发失败很常见（机器刚醒、SMC 重置、
    /// 扩展坞热插拔），这些重试一次就好；连续一分钟还不行，说明不是抖动，
    /// 是这台机器/这个风扇真的不接受我们的写。
    public static let stallThresholdSeconds: TimeInterval = 60.0

    /// 「还在持续失败」的宽限窗口（秒）。
    ///
    /// 最近一次失败超过这个时间，就认为已经不在持续失败了 —— 比如用户
    /// 把规则关掉之后，那个失败记录不该在 60 秒后自己升级成「交还系统」。
    public static let stallActivityGraceSeconds: TimeInterval = 30.0

    /// 免责声明版本号。正文有实质变化时 +1，老用户需要重新同意。
    public static let disclaimerVersion = 1
}

/// 一个风扇的实时状态。
public struct FanState: Sendable, Equatable {

    /// 单个风扇的状态。
    public struct Fan: Sendable, Equatable {
        /// 风扇序号（从 0 起）。
        public let index: Int
        /// 显示名。读不到 SMC 里的名字时回落成 "Fan N"。
        public let name: String
        /// 当前实际转速（RPM）。
        public let currentRPM: Int
        /// 该机型允许的最低转速。写目标值时不得低于它。
        public let minRPM: Int
        /// 该机型允许的最高转速。紧急兜底时写它。
        public let maxRPM: Int
        /// 当前是否处于手动模式（手动模式下转速由外部指定）。
        public let isManual: Bool

        public init(index: Int, name: String, currentRPM: Int,
                    minRPM: Int, maxRPM: Int, isManual: Bool) {
            self.index = index
            self.name = name
            self.currentRPM = currentRPM
            self.minRPM = minRPM
            self.maxRPM = maxRPM
            self.isManual = isManual
        }
    }

    public let fans: [Fan]
    /// 读取时刻（unix epoch 秒）。
    public let timestamp: TimeInterval
    /// 连续写不进、已被助手判定为「停止修改转速」的风扇序号。
    public let stalledFans: [Int]
    /// 连「交回系统控制」都失败的风扇序号 —— 严重问题，必须警告用户。
    public let releaseFailedFans: [Int]

    public init(fans: [Fan],
                timestamp: TimeInterval = Date().timeIntervalSince1970,
                stalledFans: [Int] = [],
                releaseFailedFans: [Int] = []) {
        self.fans = fans
        self.timestamp = timestamp
        self.stalledFans = stalledFans
        self.releaseFailedFans = releaseFailedFans
    }

    /// 转速区间合法的风扇才允许被写。
    ///
    /// 区间反常（min > max、两者都是 0、max 小于 200）说明 SMC 没给出有效值，
    /// 这种情况下写转速是在盲写 —— 宁可拒绝。
    public func writableFan(at index: Int) -> Fan? {
        guard let fan = fans.first(where: { $0.index == index }) else { return nil }
        guard fan.minRPM > 0, fan.maxRPM > fan.minRPM else { return nil }
        return fan
    }

    // MARK: - 编解码

    public func encode() -> [String: String] {
        [
            "fans": Self.encodeFans(fans),
            "count": "\(fans.count)",
            "timestamp": String(timestamp),
            "stalled": stalledFans.map(String.init).joined(separator: ","),
            "releaseFailed": releaseFailedFans.map(String.init).joined(separator: ",")
        ]
    }

    public static func decode(_ payload: [String: String]) -> FanState {
        FanState(
            fans: decodeFans(payload["fans"]),
            timestamp: payload["timestamp"].flatMap { TimeInterval($0) }
                ?? Date().timeIntervalSince1970,
            stalledFans: decodeIndexList(payload["stalled"]),
            releaseFailedFans: decodeIndexList(payload["releaseFailed"])
        )
    }

    /// 解一行逗号分隔的风扇序号。空串 → 空数组。
    private static func decodeIndexList(_ raw: String?) -> [Int] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").compactMap { Int($0) }
    }

    private static func encodeFans(_ fans: [Fan]) -> String {
        fans.map { fan in
            [
                String(fan.index),
                escape(fan.name),
                String(fan.currentRPM),
                String(fan.minRPM),
                String(fan.maxRPM),
                fan.isManual ? "1" : "0"
            ].joined(separator: "|")
        }.joined(separator: ",")
    }

    private static func decodeFans(_ raw: String?) -> [Fan] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",", omittingEmptySubsequences: false).compactMap { entry in
            let fields = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, let index = Int(fields[0]) else { return nil }
            return Fan(
                index: index,
                name: unescape(fields[1]),
                currentRPM: Int(fields[2]) ?? 0,
                minRPM: Int(fields[3]) ?? 0,
                maxRPM: Int(fields[4]) ?? 0,
                isManual: fields[5] == "1"
            )
        }
    }
}

/// 一次温度采样。
public struct TemperatureSnapshot: Sendable, Equatable {

    /// 单个传感器的读数。
    public struct Reading: Sendable, Equatable {
        /// 传感器标识。IOHID 的 Product 名，例如 "PMU tdie1"。
        public let sensorID: String
        /// 摄氏度。
        public let celsius: Double

        public init(sensorID: String, celsius: Double) {
            self.sensorID = sensorID
            self.celsius = celsius
        }
    }

    public let readings: [Reading]
    /// 读取时刻（unix epoch 秒）。
    public let timestamp: TimeInterval

    public init(readings: [Reading], timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.readings = readings
        self.timestamp = timestamp
    }

    /// 最高读数。没有任何读数时为 nil。
    public var maxCelsius: Double? {
        readings.map(\.celsius).max()
    }

    /// 是否触发了紧急兜底（任一传感器 ≥ 阈值）。
    public var triggersEmergency: Bool {
        readings.contains { $0.celsius >= FanControl.emergencyTemperatureCelsius }
    }

    // MARK: - 编解码

    public func encode() -> [String: String] {
        [
            "readings": Self.encodeReadings(readings),
            "count": "\(readings.count)",
            "timestamp": String(timestamp)
        ]
    }

    public static func decode(_ payload: [String: String]) -> TemperatureSnapshot {
        TemperatureSnapshot(
            readings: decodeReadings(payload["readings"]),
            timestamp: payload["timestamp"].flatMap { TimeInterval($0) }
                ?? Date().timeIntervalSince1970
        )
    }

    private static func encodeReadings(_ readings: [Reading]) -> String {
        readings.map { reading in
            [escape(reading.sensorID), String(format: "%.2f", reading.celsius)]
                .joined(separator: "|")
        }.joined(separator: ",")
    }

    private static func decodeReadings(_ raw: String?) -> [Reading] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",", omittingEmptySubsequences: false).compactMap { entry in
            let fields = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, let celsius = Double(fields[1]) else { return nil }
            return Reading(sensorID: unescape(fields[0]), celsius: celsius)
        }
    }
}

// MARK: - 转义

/// 百分号编码。与 ProcessStats 的实现保持同一套规则。
///
/// 传感器名里会出现空格与中文（"gas gauge battery"、将来可能有中文别名），
/// 编码器只允许 `[a-zA-Z0-9]` 之外的字符走编码通道。
func escape(_ value: String) -> String {
    var out = ""
    out.reserveCapacity(value.count)
    for character in value {
        if character.isASCII && (character.isLetter || character.isNumber) {
            out.append(character)
        } else {
            for byte in String(character).utf8 {
                out.append("%")
                out.append(String(format: "%02X", byte))
            }
        }
    }
    return out
}

/// 百分号解码。
func unescape(_ value: String) -> String {
    var bytes: [UInt8] = []
    var iterator = Array(value).makeIterator()
    var pending: [Character] = []
    while let character = iterator.next() {
        if character == "%" {
            var hex = ""
            for _ in 0..<2 {
                guard let next = iterator.next() else { break }
                hex.append(next)
            }
            if hex.count == 2, let byte = UInt8(hex, radix: 16) {
                bytes.append(byte)
            } else {
                // 不是合法的转义序列：按字面处理。
                bytes.append(contentsOf: Array(("%" + hex).utf8))
            }
        } else {
            bytes.append(contentsOf: Array(String(character).utf8))
        }
    }
    pending.removeAll()
    return String(decoding: bytes, as: UTF8.self)
}
