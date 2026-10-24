//
//  KeepAliveTestStubs.swift
//  Deep Sleep 回归测试支撑（仅测试用，不参与 App 构建）
//
//  目的：让 scripts/test-keepalive-schedule.swift 能编译**真实的**
//  KeepAliveEngine.swift / KeepAliveClient.swift / KeepAliveStore.swift /
//  KeepAliveModels.swift，同时把三个 I/O 边界换成可控的桩。
//
//  为什么需要桩：
//  - KeepAliveEngine 依赖 KeychainStore（会触发系统授权）、HTTPClient（真实网络）、
//    SleepController（整个 App 的状态机）。这三样在单测里都不可用。
//  - **调度逻辑本身**（锚点推进 / 退避阶梯 / 冷却基准 / inFlight / 到期判定）
//    才是要测的东西，它不依赖桩的行为细节。
//
//  被替换的边界（只有这三个）：
//  - KeychainStore —— 内存字典
//  - HTTPClient    —— 可编程的假响应（真实的 KeepAliveClient 仍然原样跑，
//                     所以 URL 拼装 / body 编码 / 错误映射 / 脱敏都是真代码）
//  - SleepController —— 只记日志的空壳
//
//  被测的真实源码（一个字节都没改）：
//  - DeepSleep/AIKeepAlive/KeepAliveModels.swift
//  - DeepSleep/AIKeepAlive/KeepAliveStore.swift
//  - DeepSleep/AIKeepAlive/KeepAliveClient.swift
//  - DeepSleep/AIKeepAlive/KeepAliveEngine.swift
//

import Foundation

// MARK: - KeychainStore 桩

/// 内存版 Keychain。真实版在 DeepSleep/LLMGateway/KeychainStore.swift。
///
/// **线程安全**：`KeepAliveStore.readAPIKey` 把 Keychain IO 扔到
/// `DispatchQueue.global` 上，而 `send()` 又是 Task —— 所以 vault 会被
/// 多线程并发访问。用一把锁包住（真实实现靠 Keychain 自身的跨进程串行化）。
enum KeychainStore {

    /// account → key。用 static 让测试进程内共享。
    nonisolated(unsafe) static var vault: [String: String] = [:]

    /// 串行化保护。
    static let lock = NSLock()

    /// 写入 / 覆盖一条 key。
    static func save(key: String, account: String) throws {
        lock.withLock { vault[account] = key }
    }

    /// 读一条 key；不存在返回 nil。
    static func load(account: String) throws -> String? {
        lock.withLock { vault[account] }
    }

    /// 删一条 key。
    static func delete(account: String) throws {
        lock.withLock { _ = vault.removeValue(forKey: account) }
    }

    /// 清空（测试用）。
    static func reset() {
        lock.withLock { vault.removeAll() }
    }

    /// 只读快照（测试用，避免测试代码直接摸字典）。
    static func snapshot() -> [String: String] {
        lock.withLock { vault }
    }
}

// MARK: - HTTPClient 桩

/// 请求。字段与真实版 HTTPClient.swift 一致。
struct HTTPRequest {
    var url: URL
    var method: String = "GET"
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval = 30
}

/// 响应。字段与真实版一致。
struct HTTPResponse {
    var status: Int
    var headers: [AnyHashable: Any]
    var data: Data
}

/// 可编程的假 HTTP 客户端。
///
/// **线程安全**：`fetch` 会被多个 Task 并发调用（`send()` 每次都开 Task），
/// 所以 `requests` 的读写必须加锁 —— 否则并发 append 会踩坏数组的
/// 内存布局，表现为随机的 SIGSEGV / Trace trap。
///
/// 注意：`ensureSuccess` 的实现与真实版逐行等价 —— 否则测的就是桩的行为
/// 而不是真实代码的行为。
final class HTTPClient {

    static let shared = HTTPClient()

    /// 记录收到的每个请求（用来断言 URL / header / body）。
    nonisolated(unsafe) static var requests: [HTTPRequest] = []

    /// 下一个响应的状态码（加锁访问）。
    nonisolated(unsafe) static var nextStatus: Int {
        get { lock.withLock { _nextStatus } }
        set { lock.withLock { _nextStatus = newValue } }
    }

    /// 下一个响应的 body（加锁访问）。
    nonisolated(unsafe) static var nextBody: Data {
        get { lock.withLock { _nextBody } }
        set { lock.withLock { _nextBody = newValue } }
    }

    /// 真实存储（只在锁内访问）。
    nonisolated(unsafe) static var _nextStatus = 200
    nonisolated(unsafe) static var _nextBody = Data()

    /// 请求被卡住时置 true；用来模拟「请求还在飞」。
    nonisolated(unsafe) static var suspendBeforeResponse: Bool {
        get { lock.withLock { _suspend } }
        set { lock.withLock { _suspend = newValue } }
    }
    nonisolated(unsafe) static var _suspend = false

    /// 保护所有可变状态。
    static let lock = NSLock()

    /// 清空记录。
    static func reset() {
        lock.withLock {
            requests.removeAll()
            _nextStatus = 200
            _nextBody = Data()
            _suspend = false
        }
    }

    /// 已记录的请求数（线程安全）。
    static var requestCount: Int {
        lock.withLock { requests.count }
    }

    /// 已记录的请求快照（线程安全）。
    static var requestSnapshot: [HTTPRequest] {
        lock.withLock { requests }
    }

    func fetch(_ req: HTTPRequest) async throws -> HTTPResponse {
        // 注意：NSLock.lock() 在 async 上下文里是 unavailable（Swift 6 起是 error）。
        // 这里用 `withLock`（Swift 5.7+ 的 NSLock.withLock 扩展，async 安全）
        // 或者干脆在**同步**闭包里做临界区。
        let (status, body, suspended) = HTTPClient.lock.withLock { () -> (Int, Data, Bool) in
            HTTPClient.requests.append(req)
            return (HTTPClient._nextStatus, HTTPClient._nextBody, HTTPClient._suspend)
        }

        if suspended {
            while true {
                let stillSuspended = HTTPClient.lock.withLock { HTTPClient._suspend }
                if !stillSuspended { break }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        return HTTPResponse(status: status, headers: [:], data: body)
    }

    /// 与真实版逐行等价。
    static func ensureSuccess(_ resp: HTTPResponse) throws -> Data {
        guard (200..<300).contains(resp.status) else {
            let body = String(data: resp.data, encoding: .utf8) ?? "<binary>"
            throw LLMGatewayError.httpStatus(resp.status, body)
        }
        return resp.data
    }
}

// MARK: - SleepController 桩

/// 只提供 appendLog 的空壳。
@MainActor
final class SleepController {
    static let shared = SleepController()

    /// 收到的日志行。
    nonisolated(unsafe) static var logLines: [String] = []

    /// 保护日志数组（appendLog 会被多个 Task 并发调用）。
    static let logLock = NSLock()

    /// 清空日志。
    static func resetLogs() {
        logLock.withLock { logLines.removeAll() }
    }

    /// 日志快照（线程安全）。
    static func logSnapshot() -> [String] {
        logLock.withLock { logLines }
    }

    func appendLog(_ text: String, isError: Bool = false) {
        SleepController.logLock.withLock { SleepController.logLines.append(text) }
    }
}
