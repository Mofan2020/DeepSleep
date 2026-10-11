//
//  HealthCheck.swift
//  Deep Sleep
//
//  网关健康检查端点。
//
//  设计：
//  - 不读数据库，避免健康检查本身就成故障源。
//  - providers 数字从 GatewayDatabase.listProviders 数；数据库故障时 providers=0。
//

import Foundation

enum HealthCheck {

    /// 拼一条 200 JSON 响应。body 形如：
    /// {"status":"ok","version":"1.5.0","providers":N}
    static func handleHealthRequest(_ req: HTTPRequest) -> HTTPResponse {
        let providerCount: Int
        do {
            providerCount = try GatewayDatabase.shared.listProviders().count
        } catch {
            providerCount = 0
        }

        let bodyDict: [String: Any] = [
            "status": "ok",
            "version": "1.5.0",
            "providers": providerCount,
        ]
        // JSONSerialization 不会失败（都是简单类型）；失败兜底一个空对象。
        let body: Data
        if let data = try? JSONSerialization.data(
            withJSONObject: bodyDict, options: [.fragmentsAllowed]
        ) {
            body = data
        } else {
            body = Data("{\"status\":\"ok\"}".utf8)
        }

        let headers: [AnyHashable: Any] = [
            "Content-Type": "application/json",
            "Content-Length": body.count,
            "Cache-Control": "no-store",
        ]
        return HTTPResponse(status: 200, headers: headers, data: body)
    }
}
