//
//  ProcessNiceService.swift
//  Deep Sleep
//
//  应用侧的「进程 nice」封装。读 nice 用本进程（`getpriority` 无需特权）；
//  改 nice 走助手（任何方向都需要 root，POSIX 硬约束）。
//
//  与「强制退出」同模式：应用只发 pid + value，所有「能不能改」的判断
//  都由助手基于自己的快照重新做。
//

import Foundation

@MainActor
final class ProcessNiceService {

    static let shared = ProcessNiceService()

    private init() {}

    enum SetNiceError: Error, CustomStringConvertible {
        case helperUnavailable(String)
        case rejected(String)
        case invalidResponse(String)

        var description: String {
            switch self {
            case .helperUnavailable(let m): return "助手未就绪：\(m)"
            case .rejected(let m):           return "助手拒绝：\(m)"
            case .invalidResponse(let m):    return "助手返回异常：\(m)"
            }
        }
    }

    /// 读一组 pid 的 nice。
    /// 本进程直接 `getpriority`，不走助手 —— 读不需要特权。
    func nice(ofPids pids: [pid_t]) -> [pid_t: Int?] {
        var result: [pid_t: Int?] = [:]
        for pid in pids {
            result[pid] = ProcessPriority.nice(of: pid)
        }
        return result
    }

    /// 改一个进程的 nice。
    ///
    /// 调用前应用侧做了一次"看上去能改"的判断（不在系统路径、不在保护名单）；
    /// 但助手会用自己的快照再算一次 —— 应用判断只用来减少不必要的 round trip。
    func setNice(_ value: Int, of pid: pid_t) async throws -> Int {
        guard HelperInstaller.isInstalled else {
            throw SetNiceError.helperUnavailable("请先在「完全控制」页安装助手")
        }
        let response = try await HelperClient.shared.send(.init(
            command: .setProcessNice,
            arguments: ["pid": "\(pid)", "value": NiceLevel.format(value)]
        ))
        guard response.success else {
            throw SetNiceError.rejected(response.message)
        }
        guard let raw = response.payload["value"], let verified = Int(raw) else {
            throw SetNiceError.invalidResponse("助手未回报新 nice 值")
        }
        return verified
    }
}
