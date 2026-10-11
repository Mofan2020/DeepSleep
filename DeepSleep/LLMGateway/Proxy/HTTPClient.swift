//
//  HTTPClient.swift
//  Deep Sleep
//
//  各 Provider 共用的极简 HTTP 客户端。
//
//  设计：
//  - 基于 URLSession（系统自带）；不用第三方。
//  - 自动把 throw URLSession 错误 → LLMGatewayError。
//  - 一个方法 fetch(HTTPRequest) → (Data, HTTPURLResponse)。
//  - 不内置重试：QuotaPoller 自己做。
//

import Foundation

struct HTTPRequest {
    var url: URL
    var method: String = "GET"
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval = 30

    /// 提供方便构造 JSON POST 的快捷方式。
    static func jsonPOST(
        url: URL,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval = 30
    ) -> HTTPRequest {
        var h = headers
        h["Content-Type"] = "application/json"
        return HTTPRequest(url: url, method: "POST", headers: h, body: body, timeout: timeout)
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [AnyHashable: Any]
    var data: Data
}

final class HTTPClient {

    static let shared = HTTPClient()
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

    /// 同步 fetch。
    func fetch(_ req: HTTPRequest) async throws -> HTTPResponse {
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
                throw LLMGatewayError.networkError("response 不是 HTTPURLResponse")
            }
            return HTTPResponse(status: http.statusCode, headers: http.allHeaderFields, data: data)
        } catch let err as LLMGatewayError {
            throw err
        } catch let err as URLError {
            throw LLMGatewayError.networkError(err.localizedDescription)
        } catch {
            throw LLMGatewayError.networkError(String(describing: error))
        }
    }

    /// 流式 fetch。返回 (AsyncThrowingStream<Data, Error>, status)。
    /// 注意：status 必须在 stream 消费前确定；调用方读第一个 chunk 之前先 await status。
    func stream(_ req: HTTPRequest) async throws -> (Int, AsyncThrowingStream<Data, Error>) {
        var urlReq = URLRequest(url: req.url)
        urlReq.httpMethod = req.method
        urlReq.httpBody = req.body
        urlReq.timeoutInterval = req.timeout
        for (k, v) in req.headers {
            urlReq.setValue(v, forHTTPHeaderField: k)
        }
        do {
            let (bytes, response) = try await session.bytes(for: urlReq)
            guard let http = response as? HTTPURLResponse else {
                throw LLMGatewayError.networkError("response 不是 HTTPURLResponse")
            }
            let status = http.statusCode
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                let task = Task {
                    do {
                        var buffer = Data()
                        for try await line in bytes.lines {
                            if let l = line.data(using: .utf8) {
                                buffer.append(l)
                                buffer.append(0x0A)
                            }
                        }
                        continuation.yield(buffer)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return (status, stream)
        } catch let err as LLMGatewayError {
            throw err
        } catch let err as URLError {
            throw LLMGatewayError.networkError(err.localizedDescription)
        } catch {
            throw LLMGatewayError.networkError(String(describing: error))
        }
    }

    /// 把 HTTP 错误统一映射成 .httpStatus。
    static func ensureSuccess(_ resp: HTTPResponse) throws -> Data {
        guard (200..<300).contains(resp.status) else {
            let body = String(data: resp.data, encoding: .utf8) ?? "<binary>"
            throw LLMGatewayError.httpStatus(resp.status, body)
        }
        return resp.data
    }
}