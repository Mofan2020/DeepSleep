//
//  KeepAliveModels.swift
//  Deep Sleep
//
//  AI 保活：定时向订阅制 AI 服务发一条超短请求，把「按最后一次使用起算的
//  滚动窗口」拉成近似固定窗口。
//
//  背景：Claude Code / MiniMax / Codex / Gemini / DeepSeek 这类订阅服务普遍
//  有「N 小时滚动使用窗口」—— 窗口从你上一次使用开始计时，闲置到点就重置
//  额度。实际用起来就是：明明没怎么用，额度却因为窗口到期被白白重置掉。
//  定时发一条极短的请求能把窗口续上，滚动窗口就变成近似固定窗口。
//
//  本文件只放「纯数据 + 纯函数」，不碰网络、不碰 Keychain、不碰 UI ——
//  这样 scripts/test-keepalive-url.swift 可以单独编译它做回归测试。
//
//  安全约定：API Key 不出现在这个文件里，也不出现在任何会被持久化的地方。
//  任务只保存 Keychain 的 account 名（apiKeyRef）。
//

import Foundation

// MARK: - 协议格式

/// 保活请求用哪种协议格式。
enum KeepAliveFormat: String, Codable, CaseIterable, Hashable {
    case openAI = "openai"
    case anthropic = "anthropic"

    /// UI 标题。
    var title: String {
        switch self {
        case .openAI:    return "OpenAI 格式"
        case .anthropic: return "Anthropic 格式"
        }
    }

    /// UI 副标题：一句话说清请求长什么样。
    var detail: String {
        switch self {
        case .openAI:
            return "Authorization: Bearer <key>，端点 /v1/chat/completions"
        case .anthropic:
            return "x-api-key: <key> + anthropic-version，端点 /v1/messages"
        }
    }
}

// MARK: - 默认值

/// 保活相关的默认常量。用户改乱了模板要能一键还原，所以模板内容必须是常量。
enum KeepAliveDefaults {

    /// 发送间隔的最小值（分钟）。
    static let minIntervalMinutes = 1

    /// 发送间隔的最大值（分钟）。1440 = 一天一次。
    static let maxIntervalMinutes = 1440

    /// 默认发送间隔（分钟）。240 = 4 小时，落在常见 5 小时窗口到期之前。
    static let defaultIntervalMinutes = 240

    /// 默认请求内容模板。一条极短的请求即可，token 消耗越少越好。
    static let defaultRequestTemplate = "ping"
}

// MARK: - 任务模型

/// 一个保活任务。
struct KeepAliveTask: Codable, Identifiable, Equatable, Hashable {

    var id: UUID
    /// 用户起的名字，只用于界面与日志。
    var name: String
    /// 服务端地址，例如 https://api.openai.com 。末尾有没有 /v1 都认。
    var baseURL: String
    /// 请求格式。
    var format: KeepAliveFormat
    /// 模型名。
    var model: String
    /// Keychain 的 account 名（形如 `keepalive.<uuid>`），**不是** key 本身。
    var apiKeyRef: String
    /// 发送间隔（分钟）。
    var intervalMinutes: Int
    /// 请求内容模板。允许用户自定义。
    var requestTemplate: String
    /// 是否启用。
    var isEnabled: Bool
    /// 上次发送时间。
    var lastRunAt: Date?
    /// 上次结果摘要（成功 / 失败原因）。脱敏后才允许写进来。
    var lastResult: String?
    /// 创建时间。任务第一次发送的计时起点用它。
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        baseURL: String = "",
        format: KeepAliveFormat = .openAI,
        model: String = "",
        apiKeyRef: String = "",
        intervalMinutes: Int = KeepAliveDefaults.defaultIntervalMinutes,
        requestTemplate: String = KeepAliveDefaults.defaultRequestTemplate,
        isEnabled: Bool = true,
        lastRunAt: Date? = nil,
        lastResult: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.format = format
        self.model = model
        self.apiKeyRef = apiKeyRef
        self.intervalMinutes = intervalMinutes
        self.requestTemplate = requestTemplate
        self.isEnabled = isEnabled
        self.lastRunAt = lastRunAt
        self.lastResult = lastResult
        self.createdAt = createdAt
    }

    /// 间隔钳制到合法区间。UI 与持久化入口都要过这一道，
    /// 否则手改 UserDefaults 能塞进 0（会变成「一直发」）。
    static func clampedInterval(_ minutes: Int) -> Int {
        min(max(minutes, KeepAliveDefaults.minIntervalMinutes),
            KeepAliveDefaults.maxIntervalMinutes)
    }

    /// 钳制后的副本。
    var clamped: KeepAliveTask {
        var copy = self
        copy.intervalMinutes = Self.clampedInterval(intervalMinutes)
        return copy
    }

    /// 下次该发送的时间。锚点是「上次发送」，没有就用「创建时间」——
    /// 新建的任务不会在创建瞬间就发一条出去。
    ///
    /// 长时间没跑（应用退出过）时这个时间会落在过去，重启后第一次 tick
    /// 会立刻补发一条 —— 这是想要的行为：窗口本来就该被续上。
    func nextDueDate() -> Date {
        let anchor = lastRunAt ?? createdAt
        return anchor.addingTimeInterval(TimeInterval(Self.clampedInterval(intervalMinutes) * 60))
    }

    /// 界面上的间隔文案。
    var intervalDescription: String {
        "\(Self.clampedInterval(intervalMinutes)) 分钟"
    }
}

// MARK: - URL 拼接

/// 把 baseurl 与目标路径拼成最终 URL。
///
/// 规则（OpenAI 与 Anthropic 共用同一套归一化）：
///   - 去掉 baseurl 末尾的 `/`；
///   - baseurl 已以 `/v1` 或 `/v1/` 结尾时不再补 `v1`；
///   - 其余情况补上 `/v1`。
///
/// 于是：
///   - `https://api.openai.com`      → `https://api.openai.com/v1/chat/completions`
///   - `https://api.openai.com/v1`   → `https://api.openai.com/v1/chat/completions`
///   - `https://api.anthropic.com`   → `https://api.anthropic.com/v1/messages`
///
/// baseurl 不合法（空、缺 scheme）时返回 nil，调用方负责报错。
enum KeepAliveEndpoint {

    /// 归一化 baseurl：去尾斜杠 + 补 `/v1`。
    /// 不合法时返回空字符串。
    static func normalizedBaseURL(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.count > 1 && text.hasSuffix("/") {
            text.removeLast()
        }
        guard !text.isEmpty else { return "" }
        let lowered = text.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else {
            return ""
        }
        // 大小写不敏感地判断是否已带 /v1，避免用户写成 /V1 时被拼成 /V1/v1。
        if lowered.hasSuffix("/v1") { return text }
        return text + "/v1"
    }

    /// 拼 URL。`path` 不带首尾斜杠。
    static func url(baseURL: String, path: String) -> URL? {
        let base = normalizedBaseURL(baseURL)
        guard !base.isEmpty else { return nil }
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let full = cleanPath.isEmpty ? base : base + "/" + cleanPath
        return URL(string: full)
    }

    /// 保活请求的端点。
    static func chatURL(baseURL: String, format: KeepAliveFormat) -> URL? {
        switch format {
        case .openAI:
            return url(baseURL: baseURL, path: "chat/completions")
        case .anthropic:
            return url(baseURL: baseURL, path: "messages")
        }
    }

    /// 模型列表的端点。
    static func modelsURL(baseURL: String, format: KeepAliveFormat) -> URL? {
        url(baseURL: baseURL, path: "models")
    }
}
