//
//  KeepAliveClient.swift
//  Deep Sleep
//
//  AI 保活请求的实际发送者：两种协议各一套。
//
//  复用 LLMGateway 的 HTTPClient（URLSession 封装），不自己再造一个网络层。
//  HTTPClient.ensureSuccess 负责把非 2xx 统一映射成 LLMGatewayError.httpStatus。
//
//  安全约定：
//  - API Key 只出现在 HTTP header 里，绝不写进日志、错误信息或返回值；
//  - 出错时返回的是服务端响应体（服务端一般不会回显 key），但仍做一次兜底脱敏。
//

import Foundation

/// 保活请求的结果。
struct KeepAliveSendResult {
    /// 是否成功。
    var succeeded: Bool
    /// 简短摘要（可写进日志）。成功时是「已发送」，失败时是原因。
    var summary: String
}

/// 拉模型列表的结果。
struct KeepAliveModelListResult {
    /// 模型 id 列表。
    var models: [String]
    /// 简短摘要。
    var summary: String
}

/// 保活请求客户端。
struct KeepAliveClient {

    /// 保活请求的 token 上限。固定 1 —— 目的只是把窗口续上，不是拿输出。
    static let maxTokens = 1

    /// 请求超时（秒）。
    static let timeout: TimeInterval = 30

    // MARK: - 发保活请求

    /// 发一条超短请求。
    /// - Parameters:
    ///   - task: 任务配置。
    ///   - apiKey: 从 Keychain 读出来的 key。
    static func send(_ task: KeepAliveTask, apiKey: String) async -> KeepAliveSendResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return KeepAliveSendResult(succeeded: false, summary: "未配置 API Key")
        }
        guard let url = KeepAliveEndpoint.chatURL(baseURL: task.baseURL, format: task.format) else {
            return KeepAliveSendResult(succeeded: false, summary: "地址无效")
        }
        guard !task.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return KeepAliveSendResult(succeeded: false, summary: "未配置模型名")
        }

        let template = task.requestTemplate.isEmpty
            ? KeepAliveDefaults.defaultRequestTemplate
            : task.requestTemplate

        do {
            let body = try encodeBody(task: task, content: template)
            let request = makeRequest(url: url, task: task, apiKey: trimmedKey, body: body)
            let response = try await HTTPClient.shared.fetch(request)
            _ = try HTTPClient.ensureSuccess(response)
            return KeepAliveSendResult(succeeded: true, summary: "已发送")
        } catch let error as LLMGatewayError {
            return KeepAliveSendResult(succeeded: false, summary: describe(error, apiKey: trimmedKey))
        } catch {
            return KeepAliveSendResult(
                succeeded: false,
                summary: redact(error.localizedDescription, apiKey: trimmedKey)
            )
        }
    }

    // MARK: - 拉模型列表

    /// 拉取服务端可用的模型列表。
    static func listModels(baseURL: String, format: KeepAliveFormat, apiKey: String) async -> KeepAliveModelListResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return KeepAliveModelListResult(models: [], summary: "未配置 API Key")
        }
        guard let url = KeepAliveEndpoint.modelsURL(baseURL: baseURL, format: format) else {
            return KeepAliveModelListResult(models: [], summary: "地址无效")
        }

        var request = HTTPRequest(url: url, method: "GET", timeout: timeout)
        switch format {
        case .openAI:
            request.headers["Authorization"] = "Bearer \(trimmedKey)"
        case .anthropic:
            request.headers["x-api-key"] = trimmedKey
            request.headers["anthropic-version"] = "2023-06-01"
        }

        do {
            let response = try await HTTPClient.shared.fetch(request)
            let data = try HTTPClient.ensureSuccess(response)
            let models = try decodeModelIDs(data)
            if models.isEmpty {
                return KeepAliveModelListResult(models: [], summary: "服务端返回了空列表")
            }
            return KeepAliveModelListResult(models: models, summary: "拉到 \(models.count) 个模型")
        } catch let error as LLMGatewayError {
            return KeepAliveModelListResult(
                models: [],
                summary: describe(error, apiKey: trimmedKey)
            )
        } catch {
            return KeepAliveModelListResult(
                models: [],
                summary: redact(error.localizedDescription, apiKey: trimmedKey)
            )
        }
    }

    // MARK: - 内部

    /// 组装请求体。两种协议的字段名不同，但语义一致。
    private static func encodeBody(task: KeepAliveTask, content: String) throws -> Data {
        let model = task.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let dict: [String: Any]
        switch task.format {
        case .openAI:
            dict = [
                "model": model,
                "messages": [["role": "user", "content": content]],
                "max_tokens": maxTokens,
                "stream": false,
            ]
        case .anthropic:
            dict = [
                "model": model,
                "max_tokens": maxTokens,
                "messages": [["role": "user", "content": content]],
            ]
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    /// 组装请求头。
    private static func makeRequest(
        url: URL,
        task: KeepAliveTask,
        apiKey: String,
        body: Data
    ) -> HTTPRequest {
        var request = HTTPRequest(url: url, method: "POST", body: body, timeout: timeout)
        switch task.format {
        case .openAI:
            request.headers["Authorization"] = "Bearer \(apiKey)"
            request.headers["Content-Type"] = "application/json"
        case .anthropic:
            request.headers["x-api-key"] = apiKey
            request.headers["anthropic-version"] = "2023-06-01"
            request.headers["content-type"] = "application/json"
        }
        return request
    }

    /// 解析 `{"data": [{"id": "..."}]}`。容忍字段缺失。
    private static func decodeModelIDs(_ data: Data) throws -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw LLMGatewayError.decodingError("响应不是 JSON 对象")
        }
        // 有的服务端把列表放在 data，有的直接放 models。
        let rawList = (dict["data"] as? [[String: Any]]) ?? (dict["models"] as? [[String: Any]]) ?? []
        var seen = Set<String>()
        var result: [String] = []
        for item in rawList {
            guard let id = item["id"] as? String else { continue }
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || seen.contains(trimmed) { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    /// 把错误转成一句话。响应体可能很长，截断；并做 key 兜底脱敏。
    private static func describe(_ error: LLMGatewayError, apiKey: String) -> String {
        switch error {
        case .noAPIKey:
            return "未配置 API Key"
        case .invalidAPIKey(let platform):
            return "[\(platform)] API Key 无效"
        case .networkError(let msg):
            return "网络错误：\(redact(msg, apiKey: apiKey))"
        case .httpStatus(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
            return "HTTP \(code)：\(redact(snippet, apiKey: apiKey))"
        case .decodingError(let msg):
            return "解码失败：\(redact(msg, apiKey: apiKey))"
        case .authFailed(let msg):
            return "鉴权失败：\(redact(msg, apiKey: apiKey))"
        case .unsupportedProvider(let msg):
            return "不支持的 Provider：\(msg)"
        }
    }

    /// 把 key 从文本里抹掉。服务端一般不回显 key，但这是最后一道防线。
    static func redact(_ text: String, apiKey: String) -> String {
        guard !apiKey.isEmpty else { return text }
        return text.replacingOccurrences(of: apiKey, with: "***")
    }
}
