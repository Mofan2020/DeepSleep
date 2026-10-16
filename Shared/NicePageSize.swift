//
//  NicePageSize.swift
//  Shared
//
//  进程优先级（nice）页面每页进程数的范围常量 + 钳制工具。
//
//  为什么放 Shared：MonitorConfig.nicePageSize 校验 + UI 限制共用同一份，
//  避免应用改 10~30 助手改 5~50 出现"clamp 范围漂移"。
//

import Foundation

/// 进程优先级（nice）页的每页数量上下限与钳制。
public enum NicePageSize {
    /// 用户可设的最小值。太小分页没意义（视觉上不如不翻）。
    public static let minValue: Int = 10
    /// 用户可设的最大值。太大单页滚动又会出现卡顿，正是这条改造要避免的退化。
    public static let maxValue: Int = 30
    /// 用户没改过时的默认值。
    public static let defaultValue: Int = 20

    /// 把任意输入钳到合法范围。供 MonitorConfig.init / UI Stepper / CLI 共用。
    public static func clamp(_ raw: Int) -> Int {
        if raw < minValue { return minValue }
        if raw > maxValue { return maxValue }
        return raw
    }

    /// UI 字符串（"10 – 30，默认 20"），给副标题用。
    public static let description: String = "\(minValue) – \(maxValue)，默认 \(defaultValue)"
}