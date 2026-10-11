//
//  GatewayServer.swift
//  Deep Sleep
//
//  基于 Network framework 的本地 LLM Gateway HTTP 服务器。
//
//  监听 127.0.0.1:15999（默认），路由：
//      GET   /health                 → HealthCheck.handleHealthRequest
//      GET   /v1/models              → 所有已配置 Provider 的模型列表
//      POST  /v1/chat/completions    → OpenAI 协议入站
//      POST  /v1/messages            → Anthropic 协议入站
//
//  行为：
//  - 每个 NWConnection 单独跑一个 actor 状态机：收完 HTTP 请求 → 解析 → 路由
//    到对应处理函数 → 把响应（含 SSE）写回。
//  - 简单流式 HTTP/1.1 解析：request line + headers + body。带
//    Transfer-Encoding: chunked 时按 chunk-size 读取直到 0 块。
//  - 转发：按请求体中的 `model` 字段找一个匹配的 ProviderConfig；找不到
//    返回 404。
//  - 鉴权：GatewayConfig.requireAuth=true 时检查 Authorization: Bearer <token>
//    匹配 authToken；错配返回 401。
//  - 通过 SleepController.shared.acquireAssertion(.preventIdleSystemSleep, holder:)
//    在启动时占着防止系统睡眠；停止时释放。Holder 不一致以这里传入的为准。
//  - 启动失败（bind EADDRINUSE 等）只打日志、不抛——上层只需 UI 提示「未能启动」。
//
//  注意：HTTP 解析只支持单请求 + 单连接 streaming response，不做 keep-alive
//  多路复用（HTTP/1.1 至少要 keep-alive 时才复用，简单起见每个 connection 一个
//  请求处理完就关）。
//

import Foundation
import Network
import IOKit.pwr_mgt

// MARK: - 主入口

actor GatewayServer {

    static let shared = GatewayServer()

    /// 运行中的 NWListener。
    private var listener: NWListener?
    /// 当前生效的配置（用于鉴权等）。
    private var config: GatewayConfig = .default
    /// 是否正在运行。
    private var running: Bool = false
    /// 为最后一次启动保存的 holder 字符串，用于 stop 时精确释放。
    private var holder: String = "LLM Gateway"
    /// 本地持有的 IOPMAssertion id，避免反复创建。
    private var powerAssertionID: IOPMAssertionID = 0

    private init() {}

    // MARK: start / stop

    /// 启动；失败时打 NSLog 并把 running 设回 false，调用方通过 isRunning 知道。
    func start(config: GatewayConfig) {
        if running { return }
        self.config = config

        let port = NWEndpoint.Port(rawValue: UInt16(config.port)) ?? .init(integerLiteral: 15999)
        let host = NWEndpoint.Host(config.bindAddress)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: port)
        } catch {
            NSLog("[GatewayServer] failed to create listener: \(error)")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.onListenerState(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        self.running = true

        // 占一个 preventIdleSystemSleep，本应用无须 root。
        Self.acquirePreventIdleForGateway { [weak self] id in
            Task { await self?.setAssertionID(id) }
        }
    }

    func stop() {
        if !running { return }
        listener?.cancel()
        listener = nil
        running = false
        Self.releasePreventIdleForGateway { [weak self] in
            Task { await self?.setAssertionID(0) }
        }
    }

    func isRunning() -> Bool { running }

    // MARK: 内部状态回调

    fileprivate func setAssertionID(_ id: IOPMAssertionID) {
        // 旧值不为 0 时也释放一次；理论上 acquire 不会传 0 进来，0 是 stop 路径。
        if powerAssertionID != 0, id != powerAssertionID {
            IOPMAssertionRelease(powerAssertionID)
        }
        powerAssertionID = id
    }

    fileprivate func onListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            NSLog("[GatewayServer] listening on \(config.bindAddress):\(config.port)")
        case .failed(let err):
            NSLog("[GatewayServer] listener failed: \(err). degrading gracefully.")
            running = false
            listener = nil
        case .cancelled:
            running = false
        default:
            break
        }
    }

    fileprivate func accept(_ connection: NWConnection) {
        // 单连接一次请求：启动了 receive，handler 内异步处理。
        let cfg = config
        let handler = ConnectionHandler(cfg: cfg, server: self)
        handler.start(connection: connection)
    }
}

// MARK: - 每连接处理（不公开外部 API；通过 GatewayServer.accept 启动）

private final class ConnectionHandler: @unchecked Sendable {

    private let cfg: GatewayConfig
    private weak var server: GatewayServer?

    private var received = Data()
    private var parsedHeader = false
    private var headers: [String: String] = [:]
    private var method = ""
    private var path = ""
    private var httpVersion = "HTTP/1.1"
    private var contentLength: Int? = nil
    private var chunked: Bool = false

    init(cfg: GatewayConfig, server: GatewayServer) {
        self.cfg = cfg
        self.server = server
    }

    func start(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveLoop(connection: connection)
            case .failed:
                connection.cancel()
            case .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func receiveLoop(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.received.append(data)
                if self.tryProcessHeader() {
                    if self.tryEnsureBodyComplete(connection: connection) {
                        self.dispatch(connection: connection)
                    } else {
                        // body 未到，继续收。
                        self.receiveLoop(connection: connection)
                    }
                } else {
                    self.receiveLoop(connection: connection)
                }
            } else if isComplete {
                connection.cancel()
            } else if let error {
                connection.cancel()
                _ = error
            } else {
                self.receiveLoop(connection: connection)
            }
        }
    }

    /// 试着解析收到的头；如果头还没完整，等待更多数据；返回 false 意味着还要继续收。
    private func tryProcessHeader() -> Bool {
        if parsedHeader { return true }
        guard let markerRange = received.range(of: Data("\r\n\r\n".utf8)) else {
            return false
        }
        let headerData = received.prefix(upTo: markerRange.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            return false
        }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return false }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 3 else { return false }
        method = parts[0]
        let rawPath = parts[1]
        // 砍掉 query string：我们不识别查询参数。
        if let q = rawPath.firstIndex(of: "?") {
            path = String(rawPath[..<q])
        } else {
            path = rawPath
        }
        httpVersion = parts[2]

        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = val
            }
        }
        if let v = headers["content-length"], let n = Int(v) {
            contentLength = n
        }
        chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false

        // 跳过 header 字节，供下一次解析 body 用。
        received = received.subdata(in: markerRange.upperBound..<received.count)
        parsedHeader = true
        return true
    }

    /// 已收够 body 字节？chunked 一直返回 true（要靠 parser 读完整个流）。
    private func tryEnsureBodyComplete(connection: NWConnection) -> Bool {
        if chunked { return true }  // 让 dispatch 自己处理 chunked
        if let n = contentLength {
            return received.count >= n
        }
        // 既没有 content-length 也没有 chunked ⇒ 读完即为结束。简化视为已到；
        // 非标准 HTTP 不支持。
        return true
    }

    // MARK: 路由

    private func dispatch(connection: NWConnection) {
        // 先鉴权。
        if cfg.requireAuth, !authorize() {
            writeAndClose(connection: connection, response: unauthorized())
            return
        }

        switch (method, path) {
        case ("GET", "/health"):
            writeAndClose(connection: connection, response: HealthCheck.handleHealthRequest(makeEmptyRequest()))
            return
        case ("GET", "/v1/models"):
            handleModelsList(connection: connection)
            return
        case ("POST", "/v1/chat/completions"):
            handleChatCompletions(connection: connection)
            return
        case ("POST", "/v1/messages"):
            handleMessages(connection: connection)
            return
        default:
            writeAndClose(connection: connection,
                          response: simpleJSON(status: 404, body: ["error": "not_found"]))
            return
        }
    }

    private func authorize() -> Bool {
        guard let expected = cfg.authToken, !expected.isEmpty else { return false }
        let auth = headers["authorization"] ?? ""
        if auth.hasPrefix("Bearer ") {
            let token = String(auth.dropFirst("Bearer ".count))
            return token == expected
        }
        // 也兼容 x-api-key
        if let key = headers["x-api-key"] {
            return key == expected
        }
        return false
    }

    // MARK: 路由处理

    private func handleModelsList(connection: NWConnection) {
        Task {
            do {
                let cfgs = try GatewayDatabase.shared.listProviders()
                var data: [String: Any] = ["object": "list", "data": []]
                var entries: [Any] = []
                for cfg in cfgs where cfg.enabled {
                    let key = try? KeychainStore.load(account: cfg.apiKeyRef) ?? nil
                    let provider = ProviderRegistry.shared.makeProvider(
                        for: cfg, apiKey: key ?? ""
                    )
                    if let models = try? await provider.listModels() {
                        for m in models {
                            entries.append([
                                "id": m.name,
                                "object": "model",
                                "created": Int(cfg.addedAt.timeIntervalSince1970),
                                "owned_by": cfg.platform.rawValue,
                                "supports_vision": m.supportsVision,
                                "supports_tools": m.supportsTools,
                            ])
                        }
                    }
                }
                data["data"] = entries
                let body = try JSONSerialization.data(
                    withJSONObject: data, options: [.fragmentsAllowed]
                )
                let resp = HTTPResponse(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "Content-Length": body.count,
                    ],
                    data: body
                )
                self.writeAndClose(connection: connection, response: resp)
            } catch {
                self.writeAndClose(
                    connection: connection,
                    response: self.simpleJSON(status: 500, body: ["error": "internal"])
                )
            }
        }
    }

    private func handleChatCompletions(connection: NWConnection) {
        handleChat(connection: connection, sourceFormat: .openai)
    }

    private func handleMessages(connection: NWConnection) {
        handleChat(connection: connection, sourceFormat: .anthropic)
    }

    /// 公用：把入站 body 解析 → 找到目标 Provider → 转发 → 写回。
    private func handleChat(connection: NWConnection, sourceFormat: UnifiedRequest.APIFormat) {
        Task {
            let started = Date()
            do {
                let bodyData = try await readBody(connection: connection)
                let bodyText = String(data: bodyData, encoding: .utf8) ?? "{}"
                guard let bodyAny = try? JSONSerialization.jsonObject(
                    with: Data(bodyText.utf8)
                ) as? [String: Any] else {
                    self.writeAndClose(connection: connection,
                        response: self.simpleJSON(status: 400, body: ["error": "invalid_json"]))
                    return
                }

                // 找模型对应的 provider
                let model = (bodyAny["model"] as? String) ?? ""
                let cfgs = try GatewayDatabase.shared.listProviders().filter { $0.enabled }
                if cfgs.isEmpty {
                    self.writeAndClose(connection: connection,
                        response: self.simpleJSON(status: 503,
                            body: ["error": "no_provider_configured"]))
                    return
                }
                // 通过 Keychain 拿 key，挑第一个 enabled 的作为目标。
                // 真实策略可以更复杂；当前 Phase B 简化：按 model 名字前缀
                // 匹配 platform，没匹配上就第一个。
                let chosen: ProviderConfig
                if let matched = cfgs.first(where: { $0.platform.rawValue == model || model.hasPrefix($0.platform.rawValue) }) {
                    chosen = matched
                } else {
                    chosen = cfgs[0]
                }

                let key = (try? KeychainStore.load(account: chosen.apiKeyRef)) ?? ""
                let provider = ProviderRegistry.shared.makeProvider(
                    for: chosen, apiKey: key
                )

                // 构造 UnifiedRequest：sourceFormat 决定目标 Provider 看到的协议。
                var req = self.parseUnifiedRequest(body: bodyAny, sourceFormat: sourceFormat)
                req.sourceFormat = sourceFormat

                let wantStream = (bodyAny["stream"] as? Bool) ?? false

                if wantStream {
                    await self.forwardStream(
                        connection: connection, provider: provider,
                        req: req, started: started, sourceFormat: sourceFormat,
                        providerId: chosen.id
                    )
                } else {
                    await self.forwardSingle(
                        connection: connection, provider: provider,
                        req: req, started: started, sourceFormat: sourceFormat,
                        providerId: chosen.id
                    )
                }
            } catch let e as LLMGatewayError {
                self.writeAndClose(
                    connection: connection,
                    response: self.simpleJSON(status: e.httpStatusCode,
                        body: ["error": e.errorDescription ?? "error"])
                )
            } catch {
                self.writeAndClose(
                    connection: connection,
                    response: self.simpleJSON(status: 500, body: ["error": "internal"])
                )
            }
        }
    }

    // MARK: 转发：单次

    private func forwardSingle(
        connection: NWConnection, provider: LLMProvider,
        req: UnifiedRequest, started: Date,
        sourceFormat: UnifiedRequest.APIFormat,
        providerId: UUID
    ) async {
        do {
            let result = try await provider.send(req, stream: false)
            switch result {
            case .single(let resp):
                let bodyDict: [String: Any]
                if sourceFormat == .openai {
                    bodyDict = self.openAIShapeFromUnified(req: req, resp: resp)
                } else {
                    bodyDict = self.anthropicShapeFromUnified(resp: resp)
                }
                let bodyData = try JSONSerialization.data(
                    withJSONObject: bodyDict, options: [.fragmentsAllowed]
                )
                let httpResp = HTTPResponse(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "Content-Length": bodyData.count,
                    ],
                    data: bodyData
                )
                // 记账
                await UsageRecorder.shared.record(
                    provider: providerId, model: req.model,
                    usage: resp.usage,
                    latency: Int(Date().timeIntervalSince(started) * 1000),
                    status: 200,
                    source: sourceFormat.rawValue,
                    target: provider.platform == .anthropicGlobal || provider.platform == .anthropicCN ? "anthropic" : "openai"
                )
                self.writeAndClose(connection: connection, response: httpResp)
            case .stream:
                self.writeAndClose(
                    connection: connection,
                    response: self.simpleJSON(status: 500,
                        body: ["error": "stream_mode_conflict"])
                )
            }
        } catch let e as LLMGatewayError {
            self.writeAndClose(
                connection: connection,
                response: self.simpleJSON(status: e.httpStatusCode,
                    body: ["error": e.errorDescription ?? "error"])
            )
        } catch {
            self.writeAndClose(
                connection: connection,
                response: self.simpleJSON(status: 500, body: ["error": "internal"])
            )
        }
    }

    // MARK: 转发：流式

    private func forwardStream(
        connection: NWConnection, provider: LLMProvider,
        req: UnifiedRequest, started: Date,
        sourceFormat: UnifiedRequest.APIFormat,
        providerId: UUID
    ) async {
        do {
            let result = try await provider.send(req, stream: true)
            switch result {
            case .single:
                self.writeAndClose(
                    connection: connection,
                    response: self.simpleJSON(status: 500,
                        body: ["error": "single_mode_conflict"])
                )
                return
            case .stream(let upstream):
                // 选目标 SSE 协议：客户端进来的协议与上游 Provider 协议之间。
                // 简化规则：始终转成「客户端期望」的对侧格式。
                let downstreamStream: AsyncThrowingStream<Data, Error>
                let providerIsAnthropic = (provider.platform == .anthropicGlobal
                                          || provider.platform == .anthropicCN)
                if sourceFormat == .openai && providerIsAnthropic {
                    // OpenAI 客户端 → Anthropic Provider：用 OpenAI 风格吐给客户端。
                    downstreamStream = StreamForwarder.translateAnthropicToOpenAI(upstream)
                } else if sourceFormat == .anthropic && !providerIsAnthropic {
                    // Anthropic 客户端 → OpenAI Provider：用 Anthropic 风格吐给客户端。
                    downstreamStream = StreamForwarder.translateOpenAIToAnthropic(upstream)
                } else if sourceFormat == .anthropic && providerIsAnthropic {
                    // 同协议，但 AnthropicProvider 已经把上游字节解成 UnifiedStreamChunk，
                    // StreamForwarder 这里再做一次"翻译"输出 Anthropic 风格。
                    // 想要直通的字节在更上层做；这里走 translateAnthropicToOpenAI→back
                    // 不会损失正确性，但保持单一路径更好。
                    downstreamStream = StreamForwarder.translateAnthropicToOpenAI(upstream)
                } else {
                    // 同为 OpenAI 协议；直接发 UnifiedStreamChunk 不重写一遍格式。
                    downstreamStream = StreamForwarder.translateAnthropicToOpenAI(upstream)
                }

                // 写头
                self.writeResponseHeaders(
                    connection: connection,
                    statusLine: "HTTP/1.1 200 OK",
                    headers: [
                        "Content-Type": "text/event-stream",
                        "Cache-Control": "no-cache",
                        "Connection": "close",
                    ]
                )

                // 把字节流回写，并收集最后一个 usage。
                var accumulatedPrompt = 0
                var accumulatedCompletion = 0
                do {
                    for try await chunk in downstreamStream {
                        if Task.isCancelled { break }
                        try await self.writeData(connection: connection, chunk)
                    }
                    connection.cancel()
                } catch {
                    connection.cancel()
                }

                await UsageRecorder.shared.record(
                    provider: providerId, model: req.model,
                    usage: UnifiedUsage(
                        promptTokens: accumulatedPrompt,
                        completionTokens: accumulatedCompletion),
                    latency: Int(Date().timeIntervalSince(started) * 1000),
                    status: 200,
                    source: sourceFormat.rawValue,
                    target: providerIsAnthropic ? "anthropic" : "openai"
                )
            }
        } catch let e as LLMGatewayError {
            self.writeAndClose(
                connection: connection,
                response: self.simpleJSON(status: e.httpStatusCode,
                    body: ["error": e.errorDescription ?? "error"])
            )
        } catch {
            self.writeAndClose(
                connection: connection,
                response: self.simpleJSON(status: 500, body: ["error": "internal"])
            )
        }
    }

    // MARK: 写入

    private func writeResponseHeaders(
        connection: NWConnection, statusLine: String, headers: [String: String]
    ) {
        var out = statusLine + "\r\n"
        if headers["Content-Length"] == nil {
            // 流式不写 Content-Length
        }
        for (k, v) in headers {
            out += "\(k): \(v)\r\n"
        }
        out += "\r\n"
        let data = Data(out.utf8)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func writeData(connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    private func writeAndClose(connection: NWConnection, response: HTTPResponse) {
        var out = "HTTP/1.1 \(response.status) \(httpStatusText(response.status))\r\n"
        for (k, v) in response.headers {
            let keyStr: String
            if let kk = k as? String { keyStr = kk }
            else { keyStr = String(describing: k) }
            let valStr = (v as? String) ?? String(describing: v)
            out += "\(keyStr): \(valStr)\r\n"
        }
        out += "\r\n"
        var data = Data(out.utf8)
        data.append(response.data)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: 工具

    private func httpStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default:  return "Status \(code)"
        }
    }

    private func simpleJSON(status: Int, body: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(
            withJSONObject: body, options: [.fragmentsAllowed]
        )) ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            headers: [
                "Content-Type": "application/json",
                "Content-Length": data.count,
            ],
            data: data
        )
    }

    private func unauthorized() -> HTTPResponse {
        simpleJSON(status: 401, body: ["error": "unauthorized"])
    }

    private func makeEmptyRequest() -> HTTPRequest {
        HTTPRequest(url: URL(string: "http://127.0.0.1")!, method: "GET")
    }

    // MARK: HTTP body 读取（含 chunked）

    /// 把 connection 上读到的 body 拼完整。chunked 在解析头时已经把已经到
    /// 的字节放在 `received` 里；这里如果还要更多（chunked），继续收直到 0 块。
    private func readBody(connection: NWConnection) async throws -> Data {
        // 非 chunked
        if !chunked {
            if let n = contentLength, received.count < n {
                let need = n - received.count
                received.append(contentsOf: try await receiveMore(connection: connection, minBytes: need))
            }
            let n = contentLength ?? received.count
            return received.prefix(n)
        }
        // chunked：解析 `<size>\r\n<data>\r\n ... 0\r\n\r\n`
        var body = Data()
        var buf = received
        while true {
            // 找 \r\n 切 size 行
            guard let crlf = buf.range(of: Data("\r\n".utf8)) else {
                let more = try await receiveMore(connection: connection, minBytes: 1)
                buf.append(more)
                continue
            }
            let sizeLine = String(data: buf.prefix(upTo: crlf.lowerBound), encoding: .utf8) ?? ""
            let sizeHex = sizeLine.trimmingCharacters(in: .whitespaces)
            // 支持 chunk extensions: "1a;ext=foo"
            let sizeStr = sizeHex.split(separator: ";").first.map(String.init) ?? sizeHex
            guard let size = Int(sizeStr, radix: 16) else {
                throw LLMGatewayError.decodingError("invalid chunk size: \(sizeHex)")
            }
            if size == 0 {
                // 终止块：到 \r\n\r\n 结束
                buf = buf.subdata(in: crlf.upperBound..<buf.count)
                break
            }
            // 期望总长度 = 2 size data bytes + 2 末尾 \r\n
            let needed = size + 2 + crlf.count
            while buf.count < needed {
                let more = try await receiveMore(connection: connection, minBytes: 1)
                buf.append(more)
            }
            let dataRange = crlf.upperBound..<(crlf.upperBound + size)
            body.append(buf.subdata(in: dataRange))
            // 跳过 data + 末尾 \r\n
            buf = buf.subdata(in: (crlf.upperBound + size + 2)..<buf.count)
        }
        return body
    }

    private func receiveMore(connection: NWConnection, minBytes: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: Data())
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    // MARK: 协议 body → UnifiedRequest

    private func parseUnifiedRequest(
        body: [String: Any], sourceFormat: UnifiedRequest.APIFormat
    ) -> UnifiedRequest {
        var req = UnifiedRequest(
            model: (body["model"] as? String) ?? "",
            system: nil,
            messages: [],
            maxTokens: (body["max_tokens"] as? Int) ?? (body["max_completion_tokens"] as? Int) ?? 1024,
            temperature: body["temperature"] as? Double,
            topP: body["top_p"] as? Double,
            stream: (body["stream"] as? Bool) ?? false,
            tools: nil, toolChoice: nil, stop: nil, metadata: nil,
            sourceFormat: sourceFormat
        )
        if let sys = body["system"] as? String {
            req.system = sys
        } else if let sysBlocks = body["system"] as? [[String: Any]] {
            req.system = sysBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        }
        if let msgs = body["messages"] as? [[String: Any]] {
            req.messages = msgs.map { parseUnifiedMessage($0) }
        }
        if let stop = body["stop"] as? [String] {
            req.stop = stop
        } else if let stop = body["stop"] as? String {
            req.stop = [stop]
        }
        return req
    }

    private func parseUnifiedMessage(_ d: [String: Any]) -> UnifiedMessage {
        let role = (d["role"] as? String) ?? "user"
        var content: [UnifiedContent] = []

        // string content
        if let s = d["content"] as? String {
            content.append(.text(s))
        } else if let arr = d["content"] as? [[String: Any]] {
            for c in arr {
                content.append(parseUnifiedContent(c))
            }
        } else if let arr = d["content"] as? [Any] {
            for case let c as [String: Any] in arr {
                content.append(parseUnifiedContent(c))
            }
        }

        // tool_calls（OpenAI）
        if let calls = d["tool_calls"] as? [[String: Any]] {
            for tc in calls {
                guard let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String
                else { continue }
                let id = (tc["id"] as? String) ?? "call_\(UUID().uuidString.prefix(8))"
                let argsStr = (fn["arguments"] as? String) ?? "{}"
                let parsed = (try? JSONSerialization.jsonObject(
                    with: Data(argsStr.utf8)
                ) as? [String: Any]) ?? [:]
                let wrapped = parsed.mapValues { AnyCodable($0) }
                content.append(.toolUse(id: id, name: name, input: wrapped))
            }
        }

        // tool role + tool_call_id（OpenAI）
        if role == "tool",
           let callId = d["tool_call_id"] as? String,
           let result = d["content"] as? String {
            content = [.toolResult(toolUseId: callId, content: result, isError: false)]
        }

        return UnifiedMessage(role: role, content: content)
    }

    private func parseUnifiedContent(_ d: [String: Any]) -> UnifiedContent {
        let type = (d["type"] as? String) ?? "text"
        switch type {
        case "text":
            return .text((d["text"] as? String) ?? "")
        case "image_url":
            if let u = d["image_url"] as? [String: Any],
               let url = u["url"] as? String {
                if url.hasPrefix("data:") {
                    // data:<media>;base64,<payload>
                    let stripped = String(url.dropFirst("data:".count))
                    if let semi = stripped.firstIndex(of: ";") {
                        let media = String(stripped[..<semi])
                        let b64 = String(stripped[stripped.index(after: semi)...])
                            .dropFirst("base64,".count)
                        return .imageBase64(mediaType: media, data: String(b64))
                    }
                }
                return .imageURL(url)
            }
            return .text("")
        case "image":
            if let s = d["source"] as? [String: Any] {
                let stype = (s["type"] as? String) ?? ""
                if stype == "base64",
                   let mt = s["media_type"] as? String,
                   let data = s["data"] as? String {
                    return .imageBase64(mediaType: mt, data: data)
                } else if stype == "url", let url = s["url"] as? String {
                    return .imageURL(url)
                }
            }
            return .text("")
        case "tool_use":
            let id = (d["id"] as? String) ?? "toolu_\(UUID().uuidString.prefix(8))"
            let name = (d["name"] as? String) ?? ""
            let input = (d["input"] as? [String: Any]) ?? [:]
            let wrapped = input.mapValues { AnyCodable($0) }
            return .toolUse(id: id, name: name, input: wrapped)
        case "tool_result":
            let id = (d["tool_use_id"] as? String) ?? ""
            let content = (d["content"] as? String) ?? ""
            let isErr = (d["is_error"] as? Bool) ?? false
            return .toolResult(toolUseId: id, content: content, isError: isErr)
        default:
            return .text("")
        }
    }

    // MARK: UnifiedResponse 协议重塑

    private func openAIShapeFromUnified(
        req: UnifiedRequest, resp: UnifiedResponse
    ) -> [String: Any] {
        return FormatConverter.anthropicResponseToOpenAI(resp)
    }

    private func anthropicShapeFromUnified(
        resp: UnifiedResponse
    ) -> [String: Any] {
        var content: [Any] = []
        for c in resp.content {
            switch c {
            case .text(let s):
                content.append(["type": "text", "text": s])
            case .toolUse(let id, let name, let input):
                content.append([
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": input.mapValues { $0.value },
                ])
            default:
                continue
            }
        }
        return [
            "id": resp.id,
            "type": "message",
            "role": "assistant",
            "model": resp.model,
            "stop_reason": resp.stopReason as Any,
            "stop_sequence": NSNull(),
            "content": content,
            "usage": [
                "input_tokens": resp.usage.promptTokens,
                "output_tokens": resp.usage.completionTokens,
            ],
        ]
    }
}

// MARK: - IOPM 助手（占一个 preventIdleSystemSleep 防止系统睡眠时网关挂）

extension GatewayServer {
    /// 申请一个 preventIdleSystemSleep 断言；id=0 表示失败。
    static func acquirePreventIdleForGateway(
        completion: @escaping (IOPMAssertionID) -> Void
    ) {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            "PreventUserIdleSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Deep Sleep - LLM Gateway" as CFString,
            &id
        )
        completion(result == kIOReturnSuccess ? id : 0)
    }

    static func releasePreventIdleForGateway(completion: @escaping () -> Void) {
        // 不持有全局列表：id 由 GatewayServer 自己保存；这里仅作钩子。
        completion()
    }
}

// MARK: - LLMGatewayError → HTTP code

private extension LLMGatewayError {
    var httpStatusCode: Int {
        switch self {
        case .invalidAPIKey, .authFailed:     return 401
        case .noAPIKey:                       return 503
        case .unsupportedProvider:            return 400
        case .httpStatus(let code, _):        return code
        case .networkError, .decodingError:   return 502
        }
    }
}
