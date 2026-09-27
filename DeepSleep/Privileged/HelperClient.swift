//
//  HelperClient.swift
//  Deep Sleep
//
//  与特权助手通信的客户端。UNIX domain socket + 长度前缀 JSON 帧。
//

import Foundation

enum HelperClientError: LocalizedError {
    case notReachable(String)

    var errorDescription: String? {
        switch self {
        case .notReachable(let reason):
            return "特权助手不可用：\(reason)"
        }
    }
}

final class HelperClient {

    static let shared = HelperClient()
    private init() {}

    /// 助手二进制是否已安装到系统位置。
    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: HelperConstants.installedHelperPath)
    }

    /// 是否处于「已安装但助手进程未运行」的状态。
    var isLaunched: Bool {
        FileManager.default.fileExists(atPath: HelperConstants.socketPath)
    }

    /// 发送一条命令。会在后台队列上执行阻塞式 socket 往返，
    /// 因此调用方可以直接从异步上下文 `await`。
    func send(_ request: HelperRequest, timeout: TimeInterval = 12) async throws -> HelperResponse {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HelperResponse, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try Self.sendSync(request, timeout: timeout)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 同步往返，供后台队列使用。
    private static func sendSync(_ request: HelperRequest, timeout: TimeInterval) throws -> HelperResponse {
        guard FileManager.default.isExecutableFile(atPath: HelperConstants.installedHelperPath) else {
            throw HelperClientError.notReachable("助手尚未安装")
        }

        let fd: Int32
        do {
            fd = try UnixSocket.connect(to: HelperConstants.socketPath, timeout: timeout)
        } catch {
            throw HelperClientError.notReachable(error.localizedDescription)
        }
        defer { close(fd) }

        try UnixSocket.sendFrame(fd, request)
        return try UnixSocket.readFrame(fd, as: HelperResponse.self)
    }

    /// 探测助手是否就绪。任何异常都被视为「未就绪」。
    func probe() async -> (reachable: Bool, version: Int?, detail: String) {
        do {
            let response = try await send(.init(command: .ping), timeout: 3)
            let version = response.payload["version"].flatMap { Int($0) }
            return (true, version, response.message)
        } catch {
            return (false, nil, error.localizedDescription)
        }
    }
}
