//
//  QuotaModels.swift
//  Deep Sleep
//
//  LLM Gateway 用到的所有持久化与传输模型。
//
//  设计目标：
//  - 一个 Provider 实体存「账号级别」配置（key alias、平台、计费模式、添加时间）。
//  - QuotaWindow 是某 Provider 在某时刻拉到的窗口快照（5h / 周 / 按量余额）。
//  - UsageRecord 是网关转发一条请求的账目。
//  - 全部 Codable，方便 SQLite 之外做 JSON 备份 / 调试日志。
//

import Foundation

// MARK: - 平台

/// 支持的 LLM 平台。`rawValue` 是稳定的英文标识（写入 SQLite 的字符串）。
enum LLMPlatform: String, Codable, CaseIterable, Hashable {
    case anthropicGlobal = "anthropic-global"
    case anthropicCN = "anthropic-cn"
    case openai = "openai"
    case minimaxGlobal = "MiniMax-global"
    case minimaxCN = "MiniMax-cn"
    case deepseek = "deepseek"
    case zhipu = "zhipu"
    case dashScope = "dashscope"
    case moonshot = "moonshot"
    case doubao = "doubao"
    case qianfan = "qianfan"
    case gemini = "gemini"
    case grok = "grok"
    case mistral = "mistral"
    case cohere = "cohere"
    case ollama = "ollama"

    /// UI 标题（中文）。
    var title: String {
        switch self {
        case .anthropicGlobal: return "Anthropic（海外）"
        case .anthropicCN:     return "Anthropic（国内）"
        case .openai:          return "OpenAI"
        case .minimaxGlobal:   return "MiniMax"
        case .minimaxCN:       return "MiniMax"
        case .deepseek:        return "DeepSeek"
        case .zhipu:           return "智谱 GLM"
        case .dashScope:       return "通义千问 DashScope"
        case .moonshot:        return "Kimi / Moonshot"
        case .doubao:          return "字节豆包"
        case .qianfan:         return "百度千帆"
        case .gemini:          return "Google Gemini"
        case .grok:            return "xAI Grok"
        case .mistral:         return "Mistral"
        case .cohere:          return "Cohere"
        case .ollama:          return "Ollama / 本地 llama.cpp"
        }
    }

    /// 是否需要区域（仅 MiniMax 区分海外/国内）。
    var needsRegion: Bool { self == .minimaxGlobal || self == .minimaxCN }

    /// 是否需要计费模式（按量 vs 订阅/Coding Plan）。
    var needsBillingMode: Bool {
        switch self {
        case .anthropicGlobal, .anthropicCN, .openai,
             .minimaxGlobal, .minimaxCN, .moonshot, .gemini:
            return true
        default:
            return false
        }
    }

    /// 是否需要 API Key（Ollama 本地不需要）。
    var needsAPIKey: Bool { self != .ollama }
}

/// 计费模式：决定 UI 拉取哪些 quota 字段。
enum BillingMode: String, Codable, CaseIterable, Hashable {
    case payAsYouGo  // 按量，余额 = 剩余金额
    case subscription // 订阅，5h 窗口 + 周窗口
    case codingPlan   // Coding Plan：5h + 周窗口（订阅变种）
    case unlimited    // 不消耗配额（本地/无）
}

// MARK: - Provider 配置

/// 用户在 UI 里配置的一条 Provider 账号。API Key 不在这里——Keychain 单独存。
struct ProviderConfig: Codable, Identifiable, Hashable {
    var id: UUID
    var platform: LLMPlatform
    var displayName: String    // 用户起的别名（如「工作 / 私人」）
    var billingMode: BillingMode
    var apiKeyRef: String     // Keychain account 名（不是 key 本身）
    var enabled: Bool
    var addedAt: Date
    var notes: String?

    init(
        id: UUID = UUID(),
        platform: LLMPlatform,
        displayName: String,
        billingMode: BillingMode = .payAsYouGo,
        apiKeyRef: String,
        enabled: Bool = true,
        addedAt: Date = Date(),
        notes: String? = nil
    ) {
        self.id = id
        self.platform = platform
        self.displayName = displayName
        self.billingMode = billingMode
        self.apiKeyRef = apiKeyRef
        self.enabled = enabled
        self.addedAt = addedAt
        self.notes = notes
    }
}

// MARK: - 配额窗口

/// 一个 Provider 在某时刻拉到的窗口。
/// 不存在的字段（某 Provider 没有 5h 窗口就 nil）显式存 optional。
struct QuotaWindow: Codable, Identifiable, Hashable {
    var id: UUID { UUID() }  // 每次快照都新生成；不做主键
    var providerId: UUID
    var capturedAt: Date

    // 5h 窗口（订阅/Coding Plan）
    var fiveHourUsed: Double?
    var fiveHourTotal: Double?
    var fiveHourResetAt: Date?

    // 周窗口
    var weeklyUsed: Double?
    var weeklyTotal: Double?
    var weeklyResetAt: Date?

    // 按量余额
    var balanceAmount: Double?     // 余额
    var balanceCurrency: String?   // "USD" / "CNY"

    // 状态位（MiniMax 的 current_interval_status 字段）
    var windowStatus: WindowStatus

    enum WindowStatus: String, Codable, Hashable {
        case unknown
        case normal    // 1
        case exhausted // 2
        case unlimited // 3
    }

    /// 已用百分比（0~100+），用于进度条；缺字段返回 nil。
    var fiveHourPercent: Double? {
        guard let u = fiveHourUsed, let t = fiveHourTotal, t > 0 else { return nil }
        return min(max(u / t * 100, 0), 100)
    }

    var weeklyPercent: Double? {
        guard let u = weeklyUsed, let t = weeklyTotal, t > 0 else { return nil }
        return min(max(u / t * 100, 0), 100)
    }
}

// MARK: - 用量记录

/// 网关转发一条请求的账目。
struct UsageRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var providerId: UUID
    var model: String
    var timestamp: Date
    var promptTokens: Int
    var completionTokens: Int
    var latencyMs: Int
    var statusCode: Int
    var sourceFormat: String    // "anthropic" | "openai"
    var targetFormat: String    // "anthropic" | "openai"

    init(
        id: UUID = UUID(),
        providerId: UUID,
        model: String,
        timestamp: Date = Date(),
        promptTokens: Int,
        completionTokens: Int,
        latencyMs: Int,
        statusCode: Int,
        sourceFormat: String,
        targetFormat: String
    ) {
        self.id = id
        self.providerId = providerId
        self.model = model
        self.timestamp = timestamp
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.latencyMs = latencyMs
        self.statusCode = statusCode
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
    }
}

// MARK: - 网关配置

struct GatewayConfig: Codable, Hashable {
    var port: Int                  // 默认 15999
    var bindAddress: String        // 默认 "127.0.0.1"
    var requireAuth: Bool          // 默认 false（仅本地信任）
    var authToken: String?         // 当 requireAuth=true 时必填
    var logRequests: Bool          // 写 SQLite

    static let `default` = GatewayConfig(
        port: 15999,
        bindAddress: "127.0.0.1",
        requireAuth: false,
        authToken: nil,
        logRequests: true
    )
}

// MARK: - 通用错误

enum LLMGatewayError: LocalizedError, Equatable {
    case noAPIKey
    case invalidAPIKey(String)
    case networkError(String)
    case httpStatus(Int, String)
    case decodingError(String)
    case authFailed(String)
    case unsupportedProvider(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:                       return "未配置 API Key"
        case .invalidAPIKey(let platform):     return "[\(platform)] API Key 无效"
        case .networkError(let msg):           return "网络错误：\(msg)"
        case .httpStatus(let code, let body):  return "HTTP \(code)：\(body)"
        case .decodingError(let msg):          return "解码失败：\(msg)"
        case .authFailed(let msg):             return "鉴权失败：\(msg)"
        case .unsupportedProvider(let msg):    return "不支持的 Provider：\(msg)"
        }
    }
}