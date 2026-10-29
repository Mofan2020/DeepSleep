//
//  FanMode.swift
//  Deep Sleep
//
//  一个风扇的运行模式。
//
//  单独一个文件是为了能单测：FanController.swift 依赖助手客户端与温度监控，
//  没法单独编译，把类型拆出来之后「模式」这一层可以脱离整个应用验证。
//

import Foundation

enum FanMode: Codable, Equatable {
    /// 交给系统（写 F<n>Md = 0）
    case automatic
    /// 固定转速
    case fixed(rpm: Int)
    /// 按温度线性调速：作用在 `targetFan` 上，温度区间 [minTempC, maxTempC]
    /// 线性映射到该风扇的 [minRPM, maxRPM]。
    case rule(targetFan: Int, minTempC: Double, maxTempC: Double)

    /// 界面显示名。
    var displayName: String {
        switch self {
        case .automatic:      return "交给系统"
        case .fixed(let rpm): return "固定 \(rpm) RPM"
        case .rule(let fan, let lo, let hi):
            return String(format: "规则：风扇 %d，%.0f–%.0f°C", fan, lo, hi)
        }
    }
}
