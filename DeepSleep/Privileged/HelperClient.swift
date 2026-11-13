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

    /// 助手在不在跑。
    ///
    /// **不能只看 socket 文件在不在。** `/var/run` 每次开机是空的，而助手
    /// 是开机之后才绑的 socket——这段时间里「已安装、正在启动」和「装了但死
    /// 了」长得一模一样，只看 socket 就会把前者当成后者，让用户去重装。
    /// 所以再看一眼 launchd：任务注册上了、状态是 running，就算在跑（读
    /// launchctl 是只读操作，不需要 root）。
    var isLaunched: Bool {
        if FileManager.default.fileExists(atPath: HelperConstants.socketPath) {
            return true
        }
        return Self.isRegisteredWithLaunchd
    }

    /// launchd 里这个任务的状态是不是 running。
    static var isRegisteredWithLaunchd: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(HelperConstants.label)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.contains("state = running")
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

        // 连不上先重试几轮：开机那几十秒里助手可能刚起，socket 还在路上。
        // 一次失败就报「助手不可用」，用户看到的就是「每次开机都得重装」。
        var fd: Int32 = -1
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                fd = try UnixSocket.connect(to: HelperConstants.socketPath, timeout: timeout)
                lastError = nil
                break
            } catch {
                lastError = error
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
        }
        guard fd >= 0 else {
            throw HelperClientError.notReachable(
                lastError?.localizedDescription ?? "socket 连不上")
        }
        defer { close(fd) }

        try UnixSocket.sendFrame(fd, request)
        return try UnixSocket.readFrame(fd, as: HelperResponse.self)
    }

    /// 一次探测的结果。
    /// 用结构体而不是元组：字段还会增加（加 build 时元组会把所有调用点的解构
    /// 一起改掉），结构体加字段是兼容的。
    struct Probe {
        let reachable: Bool
        let protocolVersion: Int?
        /// 助手自身二进制的 SHA-256。旧版助手不回报这个字段，因此为 nil。
        let digest: String?
        let detail: String
    }

    /// 探测助手是否就绪。任何异常都被视为「未就绪」。
    func probe() async -> Probe {
        do {
            let response = try await send(.init(command: .ping), timeout: 3)
            return Probe(
                reachable: true,
                protocolVersion: response.payload["version"].flatMap { Int($0) },
                digest: response.payload["digest"],
                detail: response.message
            )
        } catch {
            return Probe(reachable: false, protocolVersion: nil, digest: nil,
                         detail: error.localizedDescription)
        }
    }
}
