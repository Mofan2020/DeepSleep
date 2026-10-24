//
//  KeepAliveHTTP.swift
//  Deep Sleep
//
//  AI 保活自己的极简 HTTP 客户端。
//
//  **为什么不复用 LLMGateway 的 HTTPClient**：
//  网关这块功能随时可能被关停或彻底移除（它会在本机开端口，暴露面大，
//  需要用户明确知情才敢开）。保活是独立功能，不该被网关的去留绑架。
//  所以这里自带一套最小实现 —— 保活只需要「POST 一个 JSON、拿状态码和
//  响应体」，不需要流式转发、协议互转那些网关才需要的花活。
//
//  错误类型见 `KeepAliveError.swift`（单独一个文件，好让测试能用桩顶替
//  客户端而错误类型仍走真实代码）。
//

import Foundation

// MARK: - 请求与响应

/// 一个 HTTP 请求。
struct KeepAliveHTTPRequest {
    var url: URL
    var method: String = "GET"
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval = 30
}

/// 一个 HTTP 响应。
struct KeepAliveHTTPResponse {
    var status: Int
    var headers: [AnyHashable: Any]
    var data: Data
}

// MARK: - 客户端

/// 保活专用的 HTTP 客户端。
///
/// 用系统 URLSession，不引第三方库。`ensureSuccess` 把非 2xx 统一映射成
/// `KeepAliveError.httpStatus`，调用方只需要处理一种错误。
final class KeepAliveHTTPClient {

    static let shared = KeepAliveHTTPClient()

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 60
            cfg.waitsForConnectivity = true
            self.session = URLSession(configuration: cfg)
        }
    }

    /// 发一个请求。
    func fetch(_ req: KeepAliveHTTPRequest) async throws -> KeepAliveHTTPResponse {
        var urlReq = URLRequest(url: req.url)
        urlReq.httpMethod = req.method
        urlReq.httpBody = req.body
        urlReq.timeoutInterval = req.timeout
        for (k, v) in req.headers {
            urlReq.setValue(v, forHTTPHeaderField: k)
        }
        do {
            let (data, response) = try await session.data(for: urlReq)
            guard let http = response as? HTTPURLResponse else {
                throw KeepAliveError.networkError("response 不是 HTTPURLResponse")
            }
            return KeepAliveHTTPResponse(
                status: http.statusCode,
                headers: http.allHeaderFields,
                data: data
            )
        } catch let err as KeepAliveError {
            throw err
        } catch let err as URLError {
            throw KeepAliveError.networkError(err.localizedDescription)
        } catch {
            throw KeepAliveError.networkError(String(describing: error))
        }
    }

    /// 非 2xx 转成错误。成功时返回响应体。
    static func ensureSuccess(_ resp: KeepAliveHTTPResponse) throws -> Data {
        guard (200..<300).contains(resp.status) else {
            let body = String(data: resp.data, encoding: .utf8) ?? "<binary>"
            throw KeepAliveError.httpStatus(resp.status, body)
        }
        return resp.data
    }
}
