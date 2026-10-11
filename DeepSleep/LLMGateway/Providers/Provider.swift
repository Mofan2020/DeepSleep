//
//  Provider.swift
//  Deep Sleep
//
//  所有 LLM 平台适配层的接口。
//
//  设计原则：
//  - 每个 Provider 必须独立实现 fetchQuota / send / listModels。
//  - fetchQuota 不抛副作用错误——返回的 QuotaWindow 中所有字段都是 optional，
//    「字段缺失」就是「该平台没有这个窗口」的合法表达。
//  - send 走 sendFormat / receiveFormat 抽象；网关上做 Anthropic↔OpenAI 互转时
//    不需要知道目标 Provider 的内部实现细节。
//

import Foundation

// MARK: - 统一请求 / 响应

/// 网关使用的统一请求结构（不论上游是 Anthropic 还是 OpenAI 协议）。
struct UnifiedRequest: Codable, Hashable {
    var model: String
    var system: String?
    var messages: [UnifiedMessage]
    var maxTokens: Int
    var temperature: Double?
    var topP: Double?
    var stream: Bool
    var tools: [UnifiedTool]?
    var toolChoice: UnifiedToolChoice?
    var stop: [String]?
    var metadata: [String: String]?
    /// 思考深度（MiniMax M3.1-Flash-Preview 必填；M3 / M2 系列可省）。
    /// 取值 `low` / `medium` / `high` / `xhigh` / `max`。
    /// 当平台不识别时 Provider 应静默忽略该字段。
    var thinkingEffort: ThinkingEffort?

    /// 来源格式：UI / 客户端用的是 Anthropic 还是 OpenAI 协议？
    /// Provider 在 send() 内部按 sourceFormat 拼装自己的请求体。
    var sourceFormat: APIFormat

    enum APIFormat: String, Codable { case anthropic, openai }
    enum ThinkingEffort: String, Codable, Hashable {
        case low, medium, high, xhigh, max
    }
}

struct UnifiedMessage: Codable, Hashable {
    var role: String             // "user" | "assistant" | "system"
    var content: [UnifiedContent]
}

enum UnifiedContent: Codable, Hashable {
    case text(String)
    case imageURL(String)
    case imageBase64(mediaType: String, data: String)
    case toolUse(id: String, name: String, input: [String: AnyCodable])
    case toolResult(toolUseId: String, content: String, isError: Bool)
}

struct UnifiedTool: Codable, Hashable {
    var name: String
    var description: String?
    var inputSchema: [String: AnyCodable]
}

enum UnifiedToolChoice: Codable, Hashable {
    case auto
    case any
    case tool(String)
}

struct UnifiedUsage: Codable, Hashable {
    var promptTokens: Int
    var completionTokens: Int
}

struct UnifiedResponse: Codable, Hashable {
    var id: String
    var model: String
    var stopReason: String?
    var usage: UnifiedUsage
    var content: [UnifiedContent]
}

/// 流式 chunk（内部用，对应 Anthropic events 或 OpenAI SSE delta）。
struct UnifiedStreamChunk: Codable, Hashable {
    var index: Int?
    var deltaText: String?
    var thinkingText: String?
    var toolCallDelta: ToolCallDelta?
    var finishReason: String?
    var usage: UnifiedUsage?

    struct ToolCallDelta: Codable, Hashable {
        var index: Int
        var id: String?
        var name: String?
        var argumentsFragment: String?
    }
}

// MARK: - 模型列表

struct ModelInfo: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String           // "claude-3-5-sonnet-20241022"
    var displayName: String?   // UI 显示
    var contextWindow: Int?
    var supportsVision: Bool
    var supportsTools: Bool
}

// MARK: - Provider 协议

protocol LLMProvider: AnyObject {
    /// 平台标识。
    var platform: LLMPlatform { get }

    /// 配置实例（带 API Key 由调用方注入）。
    var config: ProviderConfig { get }

    /// 拉取 quota（实现里调用各家 API）。
    /// 失败时 throw，但实现要尽量做到「字段缺失不报错」。
    func fetchQuota() async throws -> [QuotaWindow]

    /// 发送统一请求。
    /// - Parameters:
    ///   - request: 已由网关统一好的请求。
    ///   - stream: true 时返回 AsyncThrowingStream；false 时返回单个 UnifiedResponse。
    func send(_ request: UnifiedRequest, stream: Bool) async throws -> SendResult

    /// 列出可用模型。
    func listModels() async throws -> [ModelInfo]
}

enum SendResult {
    case single(UnifiedResponse)
    case stream(AsyncThrowingStream<UnifiedStreamChunk, Error>)
}

// MARK: - AnyCodable

/// 通用 JSON 值容器（用于 tools.input_schema 等任意结构）。
struct AnyCodable: Codable, Hashable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull(); return }
        if let v = try? c.decode(Bool.self)   { self.value = v; return }
        if let v = try? c.decode(Int.self)    { self.value = v; return }
        if let v = try? c.decode(Double.self) { self.value = v; return }
        if let v = try? c.decode(String.self) { self.value = v; return }
        if let v = try? c.decode([AnyCodable].self) { self.value = v.map(\.value); return }
        if let v = try? c.decode([String: AnyCodable].self) {
            var dict: [String: Any] = [:]
            for (k, val) in v { dict[k] = val.value }
            self.value = dict; return
        }
        self.value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull:                 try c.encodeNil()
        case let v as Bool:             try c.encode(v)
        case let v as Int:              try c.encode(v)
        case let v as Double:           try c.encode(v)
        case let v as String:           try c.encode(v)
        case let v as [Any]:            try c.encode(v.map(AnyCodable.init))
        case let v as [String: Any]:    try c.encode(v.mapValues(AnyCodable.init))
        default: try c.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // best-effort：通过 JSON 序列化再比较（用于测试/debug 用）。
        let l = try? JSONEncoder().encode(lhs)
        let r = try? JSONEncoder().encode(rhs)
        return l == r
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: value))
    }
}