//
//  ProviderRegistry.swift
//  Deep Sleep
//
//  Provider 实例的工厂 / 注册表。
//
//  设计：
//  - 单例：调用方用 ProviderRegistry.shared.makeProvider(for: cfg, apiKey:)
//    拿到实现。
//  - 内部按 LLMPlatform 分发到对应适配层。
//  - 每次调用都返回新实例：Provider 持有可变状态（如 quota 轮询间隔），
//    不能跨账号共享。
//  - 通过动态查找子类的形式（NSClassFromString）而不是直接引用具体类型，
//    这样单独禁用某个 Provider 文件也不会让其它 Provider 编译失败。
//

import Foundation

final class ProviderRegistry {

    static let shared = ProviderRegistry()

    private init() {}

    /// 真实平台基础 URL。
    /// 注意：plan 里写的 platform.minimax.com 域名是错的；
    /// 真实平台域名是 platform.minimaxi.com，国内为 api.minimaxi.com。
    private func baseURL(for platform: LLMPlatform) -> String {
        switch platform {
        case .anthropicGlobal:  return "https://api.anthropic.com"
        case .anthropicCN:      return "https://api.anthropic.cn"
        case .openai:           return "https://api.openai.com"
        case .minimaxGlobal:    return "https://api.minimax.io"
        case .minimaxCN:        return "https://api.minimaxi.com"
        case .deepseek:         return "https://api.deepseek.com"
        case .zhipu:            return "https://open.bigmodel.cn"
        case .dashScope:        return "https://dashscope.aliyuncs.com"
        case .moonshot:         return "https://api.moonshot.cn"
        case .doubao:           return "https://ark.cn-beijing.volces.com"
        case .qianfan:          return "https://qianfan.baidubce.com"
        case .gemini:           return "https://generativelanguage.googleapis.com"
        case .grok:             return "https://api.x.ai"
        case .mistral:          return "https://api.mistral.ai"
        case .cohere:           return "https://api.cohere.ai"
        case .ollama:           return "http://127.0.0.1:11434"
        }
    }

    /// 拿一个 Provider 实例；调用方负责持有。
    /// `apiKey` 由调用方从 KeychainStore 读出注入。
    ///
    /// 这里通过 NSClassFromString 反射创建实例，避免在编译期对每个 Provider 类
    /// 形成强依赖。前提：每个 Provider 都实现了
    ///     init(config: ProviderConfig, apiKey: String, baseURL: String)
    /// 形式的三参数构造器（只要文件被编进二进制）。
    func makeProvider(for config: ProviderConfig, apiKey: String) -> LLMProvider {
        let base = baseURL(for: config.platform)
        let className = className(for: config.platform)
        guard
            let cls = NSClassFromString(className) as? NSObject.Type,
            let prov = (cls as? LLMProviderInit.Type)?.init(
                config: config, apiKey: apiKey, baseURL: base
            )
        else {
            return FallbackProvider(config: config, platform: config.platform)
        }
        return prov
    }

    /// 平台 → Swift 类名。
    /// 注意：与 Providers/<Name>Provider.swift 文件中的 @objC-less 类名匹配。
    private func className(for platform: LLMPlatform) -> String {
        switch platform {
        case .anthropicGlobal, .anthropicCN: return "AnthropicProvider"
        case .openai:                         return "OpenAIProvider"
        case .minimaxGlobal, .minimaxCN:      return "MiniMaxProvider"
        case .deepseek:                       return "DeepSeekProvider"
        case .zhipu:                          return "ZhipuProvider"
        case .dashScope:                      return "DashScopeProvider"
        case .moonshot:                       return "MoonshotProvider"
        case .doubao:                         return "DoubaoProvider"
        case .qianfan:                        return "QianfanProvider"
        case .gemini:                         return "GeminiProvider"
        case .grok:                           return "GrokProvider"
        case .mistral:                        return "MistralProvider"
        case .cohere:                         return "CohereProvider"
        case .ollama:                         return "OllamaProvider"
        }
    }
}

/// 所有 Provider 都必须实现这个 init——用 protocol 给编译器一个类型擦除接口。
protocol LLMProviderInit: LLMProvider {
    init(config: ProviderConfig, apiKey: String, baseURL: String)
}

/// 兜底 Provider：平台类还没实现时显示「不支持」。
private final class FallbackProvider: NSObject, LLMProvider {
    let platform: LLMPlatform
    let config: ProviderConfig
    init(config: ProviderConfig, platform: LLMPlatform) {
        self.platform = platform
        self.config = config
    }
    func fetchQuota() async throws -> [QuotaWindow] {
        throw LLMGatewayError.unsupportedProvider("平台 \(platform.title) 暂未实现")
    }
    func send(_ request: UnifiedRequest, stream: Bool) async throws -> SendResult {
        throw LLMGatewayError.unsupportedProvider("平台 \(platform.title) 暂未实现")
    }
    func listModels() async throws -> [ModelInfo] { [] }
}