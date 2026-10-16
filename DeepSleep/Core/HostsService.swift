//
//  HostsService.swift
//  Deep Sleep
//
//  应用侧的「Hosts 编辑」封装。
//
//  设计：
//    - 写 hosts 必须走助手（必须 root）—— 与 SleepController 的电源操作同模式；
//    - 读取 hosts 也走助手（保持单一通道 + 助手日志有记录）；
//    - 「谁能改 hosts」白名单本身由助手持 root 写入；应用只能读 + 通过助手改。
//

import Foundation

@MainActor
final class HostsService {

    static let shared = HostsService()

    private init() {}

    enum HostsError: Error, CustomStringConvertible {
        case helperUnavailable(String)
        case rejected(String)
        case invalidResponse(String)
        case encoding(String)

        var description: String {
            switch self {
            case .helperUnavailable(let m): return "助手未就绪：\(m)"
            case .rejected(let m):           return "助手拒绝：\(m)"
            case .invalidResponse(let m):    return "助手返回异常：\(m)"
            case .encoding(let m):           return "内容编码错误：\(m)"
            }
        }
    }

    struct Snapshot {
        /// hosts 当前内容。
        let content: String
        /// 字节数（避免大文件被反复统计）。
        let byteCount: Int
    }

    /// 读 hosts。无参数。
    func read() async throws -> Snapshot {
        guard HelperInstaller.isInstalled else {
            throw HostsError.helperUnavailable("请先在「完全控制」页安装助手")
        }
        let response = try await HelperClient.shared.send(
            .init(command: .readHosts))
        guard response.success else {
            throw HostsError.rejected(response.message)
        }
        guard let content = response.payload["content"] else {
            throw HostsError.invalidResponse("助手未回报 content 字段")
        }
        let length = response.payload["length"].flatMap { Int($0) } ?? content.utf8.count
        return Snapshot(content: content, byteCount: length)
    }

    /// 写 hosts。返回是否成功 + 助手日志里那条简短说明。
    func write(_ content: String) async throws -> String {
        guard HelperInstaller.isInstalled else {
            throw HostsError.helperUnavailable("请先在「完全控制」页安装助手")
        }
        guard content.data(using: .utf8) != nil else {
            throw HostsError.encoding("内容必须是合法 UTF-8")
        }
        let response = try await HelperClient.shared.send(
            .init(command: .writeHosts, arguments: ["content": content]))
        guard response.success else {
            throw HostsError.rejected(response.message)
        }
        return response.message
    }

    /// 读白名单。读取不需要白名单 —— 否则应用想显示白名单都得先被自己允许。
    func editors() async throws -> HostsAllowedEditors.Snapshot {
        guard HelperInstaller.isInstalled else {
            throw HostsError.helperUnavailable("请先在「完全控制」页安装助手")
        }
        let response = try await HelperClient.shared.send(
            .init(command: .listHostsEditors))
        guard response.success else {
            throw HostsError.rejected(response.message)
        }
        let uids = HostsAllowedEditors.parseUids(response.payload["uids"] ?? "")
        let usernames = HostsAllowedEditors.parseUsernames(response.payload["usernames"] ?? "")
        return HostsAllowedEditors.Snapshot(uids: uids, usernames: usernames)
    }

    /// 替换白名单（覆盖式）。
    ///
    /// 助手会校验「调用方 uid 必须在当前白名单内」才允许写。
    /// 应用层不做这个校验 —— 它属于助手自己的安全策略，
    /// 应用侧只是把用户输入整理好再送过去。
    func setEditors(uids: [Int], usernames: [String]) async throws -> HostsAllowedEditors.Snapshot {
        guard HelperInstaller.isInstalled else {
            throw HostsError.helperUnavailable("请先在「完全控制」页安装助手")
        }
        let response = try await HelperClient.shared.send(
            .init(command: .setHostsEditors, arguments: [
                "uids": uids.map(String.init).joined(separator: ","),
                "usernames": usernames.joined(separator: ",")
            ]))
        guard response.success else {
            throw HostsError.rejected(response.message)
        }
        let returnedUids = HostsAllowedEditors.parseUids(response.payload["uids"] ?? "")
        let returnedUsernames = HostsAllowedEditors.parseUsernames(response.payload["usernames"] ?? "")
        return HostsAllowedEditors.Snapshot(uids: returnedUids, usernames: returnedUsernames)
    }
}