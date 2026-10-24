//
//  KeepAliveError.swift
//  Deep Sleep
//
//  AI 保活的错误类型。
//
//  刻意与网关的错误类型（LLMGatewayError）分开 —— 两边互不依赖，
//  网关被移除时保活不用动。
//
//  单独一个文件的原因：测试里会用自己的桩顶替 HTTP 客户端与 Keychain，
//  但错误类型要始终走这份真实代码（桩产生的错误也走它）。
//

import Foundation

/// 保活请求的错误。
enum KeepAliveError: LocalizedError, Equatable {
    case noAPIKey
    case networkError(String)
    case httpStatus(Int, String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:                       return "未配置 API Key"
        case .networkError(let msg):          return "网络错误：\(msg)"
        case .httpStatus(let code, let body): return "HTTP \(code)：\(body)"
        case .decodingError(let msg):         return "解码失败：\(msg)"
        }
    }
}
