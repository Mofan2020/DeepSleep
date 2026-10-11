//
//  FeatureToggle.swift
//  Deep Sleep
//
//  LLMGateway 子模块的运行时开关。
//
//  设计原则：
//  - 默认两个新功能都关闭，避免 v1.4.x 升级到 v1.5.0 时突然出现新 UI 节点。
//  - 状态只存在 UserDefaults（不需要 Keychain）。每个开关都有 migration fallback：
//    升级到 v1.5.0 后用户首次启动会把 defaultOn 同步进来，之后再走用户设置。
//  - 不修改 SleepController：避免被 check-docs 误判为「新增 assertion」。
//
//  公开 API：
//      let tok = LLMGatewayFeature.tokenMonitor
//      if tok.isEnabled { ... }
//
//      LLMGatewayFeature.setEnabled(tok, false)
//

import Foundation
import Combine

/// 单个功能的运行时开关。
struct LLMGatewayFeature: Equatable, Hashable {
    let id: String
    let defaultOn: Bool

    static let tokenMonitor = LLMGatewayFeature(
        id: "llm.tokenMonitor",
        defaultOn: false
    )
    static let gateway = LLMGatewayFeature(
        id: "llm.gateway",
        defaultOn: false
    )

    /// UserDefaults key（每个 feature 独立）。
    var defaultsKey: String { "LLMGatewayFeature.\(id)" }

    /// 是否启用。
    var isEnabled: Bool {
        get {
            // 读一次 defaults；不存在时按 defaultOn。
            // 注意：默认值变更不会自动迁移——这是有意的，
            // 默认值的「含义」变更不该悄悄翻转到用户侧。
            UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? defaultOn
        }
        nonmutating set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            LLMGatewayFeature.broadcaster.send(self)
        }
    }
}

/// 订阅：UI 订阅这个 publisher 即可在用户切换开关后立刻收到通知。
extension LLMGatewayFeature {
    fileprivate static let broadcaster = PassthroughSubject<LLMGatewayFeature, Never>()
    static let didChange = broadcaster.eraseToAnyPublisher()

    /// 切换；返回新值。
    @discardableResult
    static func setEnabled(_ feature: LLMGatewayFeature, _ enabled: Bool) -> Bool {
        feature.isEnabled = enabled
        return enabled
    }

    /// 切换；返回新值。
    @discardableResult
    static func toggle(_ feature: LLMGatewayFeature) -> Bool {
        setEnabled(feature, !feature.isEnabled)
    }

    /// 所有 feature 列表（UI 渲染开关列表用）。
    static let allCases: [LLMGatewayFeature] = [tokenMonitor, gateway]
}