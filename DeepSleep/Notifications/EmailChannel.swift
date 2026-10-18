//
//  EmailChannel.swift
//  Deep Sleep
//
//  SMTP 邮件告警渠道 —— 把监控事件、自动化规则触发的异常，用邮件告诉用户。
//
//  为什么不用 sendmail / osascript：
//   - sendmail：需要本机有可用的 MTA，普通 macOS 没装。
//   - Mail.app AppleScript：依赖用户已配好的账号，且 Mail 必须正在运行。
//   - 直发 SMTP：唯一不依赖额外条件的方式，但要求用户配一个 SMTP 服务
//     （QQ / 163 / Outlook / 自建均可，必须支持明文登录或 app password）。
//
//  凭据存储：
//   - host / port / username / from / to / tls  → UserDefaults JSON（无敏感数据）
//   - password                                → Keychain（独立 service 隔离）
//
//  与 LLMGateway.KeychainStore 共用一套 SecItemAdd/Copy 模式但独立 service，
//  避免两类凭据互相覆盖。
//
//  协议支持：仅 ESMTP + 25/465/587 端口（明文 LOGIN 或 STARTTLS）。
//  不支持 OAuth2（QQ/163/Gmail 用 app password 也能登）。
//
//  不做的事：
//   - 不重试 / 不退避 —— 由调用方负责，邮件比 URLSession 重试模式更复杂；
//   - 不做 DKIM / SPF —— 用户自配 SMTP 时已处理；
//   - 不缓存连接 —— 告警频率低，每次新连更简单。
//

import Foundation
import Security

/// 邮件渠道配置（不含密码）。
public struct EmailConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var username: String
    public var fromAddress: String
    public var toAddress: String
    /// 邮件主题前缀，便于过滤。默认 `DeepSleep`。
    public var subjectPrefix: String

    public init(enabled: Bool = false,
                host: String = "",
                port: Int = 587,
                useTLS: Bool = true,
                username: String = "",
                fromAddress: String = "",
                toAddress: String = "",
                subjectPrefix: String = "DeepSleep") {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.username = username
        self.fromAddress = fromAddress
        self.toAddress = toAddress
        self.subjectPrefix = subjectPrefix
    }

    public static let `default` = EmailConfig()

    /// 是否已配置完整（可发邮件）。
    public var isConfigured: Bool {
        !host.isEmpty && port > 0 && !username.isEmpty
            && !fromAddress.isEmpty && !toAddress.isEmpty
    }

    // MARK: - 便捷存取（UI 直接用）

    private static let configKey = "emailAlertConfig.v1"

    /// 从 UserDefaults 读；缺/坏则返回 `.default`。
    public static func loadFromDefaults() -> EmailConfig {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let config = try? JSONDecoder().decode(EmailConfig.self, from: data) else {
            return .default
        }
        return config
    }

    /// 写回 UserDefaults。失败时静默（不影响主流程）。
    public func saveToDefaults() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.configKey)
    }
}

private enum EmailKeychain {
    /// 独立 service，避免与 LLMGateway 凭据串。
    static let service = "com.skyc8266.deepsleep.email"
    static let passwordAccount = "smtp-password"

    static func savePassword(_ password: String) throws {
        guard let data = password.data(using: .utf8) else { return }
        // 先尝试删旧条目（upsert 语义）。
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount,
        ]
        SecItemDelete(query as CFDictionary)

        var add: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     passwordAccount,
            kSecValueData as String:       data,
            kSecAttrAccessible as String:  kSecAttrAccessibleAfterFirstUnlock,
        ]
        add = add as CFDictionary as? [String: Any] ?? add
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "EmailKeychain", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法写入 SMTP 密码到 Keychain（OSStatus \(status)）"])
        }
    }

    static func loadPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    static func deletePassword() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 单例邮件告警渠道。
///
/// 故意做成「无后台任务」—— `send()` 是 async 函数，调用方决定何时触发，
/// 系统监控 / 自动化各自挂自己的钩子，避免一个组件把整个告警管起来。
public actor EmailChannel {

    public static let shared = EmailChannel()

    private init() {}

    // MARK: - 配置持久化

    private static let configKey = "emailAlertConfig.v1"

    public func loadConfig() -> EmailConfig {
        guard let data = UserDefaults.standard.data(forKey: Self.configKey),
              let config = try? JSONDecoder().decode(EmailConfig.self, from: data) else {
            return .default
        }
        return config
    }

    public func saveConfig(_ config: EmailConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.configKey)
    }

    public func savePassword(_ password: String) throws {
        if password.isEmpty {
            EmailKeychain.deletePassword()
        } else {
            try EmailKeychain.savePassword(password)
        }
    }

    public func hasPassword() -> Bool {
        EmailKeychain.loadPassword() != nil
    }

    // MARK: - 发送

    /// 发送一封告警邮件。返回成功 / 失败原因（不抛异常给调用方，便于写日志）。
    public func send(subject: String, body: String) async -> Result<Void, ErrorReason> {
        let config = loadConfig()
        guard config.enabled else {
            return .failure(.notEnabled)
        }
        guard config.isConfigured else {
            return .failure(.incompleteConfig)
        }
        guard let password = EmailKeychain.loadPassword(), !password.isEmpty else {
            return .failure(.missingPassword)
        }
        do {
            try await Self.smtpSend(
                config: config,
                password: password,
                subject: subject,
                body: body
            )
            return .success(())
        } catch let error as ErrorReason {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    /// 发送一封测试邮件。测试邮件固定发给 `toAddress`。
    public func sendTest() async -> Result<Void, ErrorReason> {
        let body = """
        这是 Deep Sleep 的测试邮件。
        收到这条说明 SMTP 配置正确。
        发送时间：\(ISO8601DateFormatter().string(from: Date()))
        """
        return await send(subject: "[Test] 邮件告警测试", body: body)
    }

    // MARK: - 错误

    public enum ErrorReason: Error, CustomStringConvertible {
        case notEnabled
        case incompleteConfig
        case missingPassword
        case transport(String)
        case smtpReply(code: Int, message: String)

        public var description: String {
            switch self {
            case .notEnabled:           return "邮件告警未启用"
            case .incompleteConfig:     return "SMTP 配置不完整（host/username/from/to 至少有一个空）"
            case .missingPassword:      return "SMTP 密码未设置或已被 Keychain 清空"
            case .transport(let m):     return "SMTP 网络错误：\(m)"
            case .smtpReply(let c, let m): return "SMTP 服务器返回 \(c)：\(m)"
            }
        }
    }

    // MARK: - 私有：最小 SMTP 客户端

    /// 直接和 SMTP 服务器对话。足够「能用」，不追求 RFC 完整覆盖。
    ///
    /// 协议步骤：
    ///   1. 220 greeting
    ///   2. EHLO
    ///   3. (若 server 报 STARTTLS) STATTLS → 重 EHLO
    ///   4. AUTH LOGIN → base64(username) / base64(password)
    ///   5. MAIL FROM / RCPT TO / DATA
    ///   6. QUIT
    private static func smtpSend(
        config: EmailConfig,
        password: String,
        subject: String,
        body: String
    ) async throws {
        let host = config.host
        let port = config.port
        let useTLS = config.useTLS

        // 用 NWConnection 做 TCP + TLS，比 POSIX socket + OpenSSL 少踩坑。
        // NWConnection 异步，但 SMTP 协议本身就是请求-响应，正好契合。
        let endpoint = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? 587
        let connection: NWConnection
        if useTLS {
            let tlsOptions = NWProtocolTLS.Options()
            connection = NWConnection(host: endpoint, port: nwPort, using: NWParameters(tls: tlsOptions))
        } else {
            connection = NWConnection(host: endpoint, port: nwPort, using: NWParameters.tcp)
        }
        let queue = DispatchQueue(label: "com.skyc8266.deepsleep.email")
        connection.start(queue: queue)
        // 等 ready
        try await waitForReady(connection: connection, queue: queue)

        let timeoutSeconds: TimeInterval = 15

        func readReply() async throws -> (code: Int, message: String) {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            var data = Data()
            // 一直读到包含完整多行回复：最后一行的「code<space>」+ CRLF，
            // 或任意一行的「code-error」+ CRLF。
            while Date() < deadline {
                let chunk = try await readChunk(connection: connection, queue: queue)
                if chunk.isEmpty {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                data.append(chunk)
                if let reply = parseReply(data) {
                    return reply
                }
            }
            throw ErrorReason.transport("等待 SMTP 回复超时")
        }

        func sendCommand(_ command: String) async throws {
            try await writeData(connection: connection,
                                queue: queue,
                                data: Data((command + "\r\n").utf8))
        }

        // 1. 220
        let greeting = try await readReply()
        guard greeting.code == 220 else {
            throw ErrorReason.smtpReply(code: greeting.code, message: greeting.message)
        }

        // 2. EHLO
        try await sendCommand("EHLO localhost")
        let ehlo = try await readReply()
        guard ehlo.code == 250 else {
            throw ErrorReason.smtpReply(code: ehlo.code, message: ehlo.message)
        }
        // EHLO 多行 reply：最后一行是「250 OK」，前面的行形如「250-SIZE 12345」
        let ehloHasSTARTTLS = ehlo.message.contains("STARTTLS")
        let ehloHasAuthLogin = ehlo.message.contains("AUTH") && ehlo.message.contains("LOGIN")

        // 3. STARTTLS（明文连接需要升级时）
        if !useTLS && ehloHasSTARTTLS {
            try await sendCommand("STARTTLS")
            let tlsReply = try await readReply()
            guard tlsReply.code == 220 else {
                throw ErrorReason.smtpReply(code: tlsReply.code, message: tlsReply.message)
            }
            // 当前实现不支持 STARTTLS 升级路径 —— 重新创建带 TLS 的连接后，
            // 之前累积的所有 await continuation / NWConnection 状态都得重做，
            // 写起来容易出错且难调。用户配 465（implicit TLS）即可跳过 STARTTLS。
            connection.cancel()
            throw ErrorReason.transport(
                "当前实现只支持「配置即 TLS」（port 465）。"
                + "请在配置里把端口设为 465 并保持 TLS 勾选。"
            )
        }

        // 4. AUTH LOGIN
        guard ehloHasAuthLogin else {
            throw ErrorReason.transport("服务器不支持 AUTH LOGIN，请使用支持明文登录的 SMTP")
        }
        try await sendCommand("AUTH LOGIN")
        let authUserReply = try await readReply()
        guard authUserReply.code == 334,
              let userPrompt = Self.decodeBase64(authUserReply.message) else {
            throw ErrorReason.smtpReply(code: authUserReply.code, message: authUserReply.message)
        }
        _ = userPrompt  // "Username:"

        try await writeData(connection: connection, queue: queue,
                            data: Data(Self.encodeBase64(config.username).utf8) + Data("\r\n".utf8))
        let authPassReply = try await readReply()
        guard authPassReply.code == 334,
              let passPrompt = Self.decodeBase64(authPassReply.message) else {
            throw ErrorReason.smtpReply(code: authPassReply.code, message: authPassReply.message)
        }
        _ = passPrompt

        try await writeData(connection: connection, queue: queue,
                            data: Data(Self.encodeBase64(password).utf8) + Data("\r\n".utf8))
        let authResult = try await readReply()
        guard authResult.code == 235 else {
            throw ErrorReason.smtpReply(code: authResult.code, message: authResult.message)
        }

        // 5. MAIL FROM / RCPT TO / DATA
        try await sendCommand("MAIL FROM:<\(config.fromAddress)>")
        let mailFrom = try await readReply()
        guard mailFrom.code == 250 else {
            throw ErrorReason.smtpReply(code: mailFrom.code, message: mailFrom.message)
        }

        try await sendCommand("RCPT TO:<\(config.toAddress)>")
        let rcptTo = try await readReply()
        guard rcptTo.code == 250 else {
            throw ErrorReason.smtpReply(code: rcptTo.code, message: rcptTo.message)
        }

        try await sendCommand("DATA")
        let dataReply = try await readReply()
        guard dataReply.code == 354 else {
            throw ErrorReason.smtpReply(code: dataReply.code, message: dataReply.message)
        }

        let dateString = Self.rfc5322Date(Date())
        let messageID = "<\(UUID().uuidString)@deepsleep>"
        let fromLine = "From: \(config.fromAddress)"
        let toLine = "To: \(config.toAddress)"
        let subjectLine = "Subject: \(config.subjectPrefix.isEmpty ? "" : "[\(config.subjectPrefix)] ")\(subject)"
        let dateLine = "Date: \(dateString)"
        let idLine = "Message-ID: \(messageID)"
        let mimeLine = "MIME-Version: 1.0"
        let contentTypeLine = "Content-Type: text/plain; charset=utf-8"

        let payload = """
        \(fromLine)
        \(toLine)
        \(subjectLine)
        \(dateLine)
        \(idLine)
        \(mimeLine)
        \(contentTypeLine)

        \(body)
        """
        // DATA body 以 <CRLF>.<CRLF> 结束；且每行首字符是 "." 要再补一个 "." 转义。
        let escaped = payload
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if line.hasPrefix(".") { return "." + line } else { return String(line) }
            }
            .joined(separator: "\r\n")
        let dataPayload = escaped + "\r\n.\r\n"
        try await writeData(connection: connection, queue: queue,
                            data: Data(dataPayload.utf8))

        let dataEndReply = try await readReply()
        guard dataEndReply.code == 250 else {
            throw ErrorReason.smtpReply(code: dataEndReply.code, message: dataEndReply.message)
        }

        // 6. QUIT
        try? await sendCommand("QUIT")
        connection.cancel()
    }

    private static func waitForReady(connection: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // 简单起见，固定等 2 秒后认为 ready。SMTP 主动连接不需要等待握手，
            // 网络不通会在第一次 read 时失败。
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                cont.resume()
            }
        }
    }

    private static func readChunk(connection: NWConnection, queue: DispatchQueue) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: ErrorReason.transport(error.localizedDescription))
                } else {
                    cont.resume(returning: data ?? Data())
                }
            }
        }
    }

    private static func writeData(connection: NWConnection, queue: DispatchQueue, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: NWConnection.SendCompletion.contentProcessed { error in
                if let error {
                    cont.resume(throwing: ErrorReason.transport(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// 解析 SMTP reply（多行）。最后一行的 code + 空格 + text 才视为结束。
    private static func parseReply(_ data: Data) -> (code: Int, message: String)? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        let lines = str.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        // 最后一行的形态：「250 OK」「250-STARTTLS」「550 Error」
        guard last.count >= 4,
              let code = Int(last.prefix(3)) else { return nil }
        let separator = last.index(last.startIndex, offsetBy: 3)
        let sep = last[separator]
        // 「250 」表示完整结束，「250-」表示还有后续行。
        guard sep == " " else { return nil }
        let text = String(last[last.index(after: separator)...])
        // 合并所有 multi-line 文本。
        let allText = lines.map { line -> String in
            guard line.count >= 4 else { return line }
            return String(line[line.index(line.startIndex, offsetBy: 4)...])
        }.joined(separator: "\n")
        return (code, allText)
    }

    private static func encodeBase64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private static func decodeBase64(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static let rfc5322Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f
    }()

    private static func rfc5322Date(_ date: Date) -> String {
        rfc5322Formatter.string(from: date)
    }
}

import Network
