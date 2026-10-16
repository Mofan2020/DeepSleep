//
//  HostsAllowedEditors.swift
//  Shared
//
//  「谁能改 /etc/hosts」白名单。应用与特权助手共用。
//
//  路径：`/Library/Application Support/com.skyc8266.deepsleep/hosts-editors.plist`
//  格式：
//      uids:    [Int]   —— 允许写 hosts 的 uid 列表
//      usernames: [String] —— 同上但用名字（便利；helper 启动时展开为 uid）
//
//  为什么放在 Shared：
//    - 助手写入 + 应用读取，两边都要解析；
//    - 解析规则要严格统一（uid 数字合法性、名字白名单过滤、缺失字段容错）。
//
//  权限边界：
//    - plist 文件 owner: `root:wheel`、mode `0600`（仅 root 可写）；
//    - 应用只能读不能改；改白名单必须走助手 `setHostsEditors` 命令，
//      而该命令自身也要求调用方已在白名单内（防止普通 uid 加自己）。
//

import Foundation

/// hosts 编辑白名单。
///
/// 同一份逻辑由 DeepSleep.app 和 deepsleep-helper 共用 —— 应用读、助手写。
public enum HostsAllowedEditors {

    /// 读取当前白名单。文件不存在 / 不可读 / 格式损坏一律视为「空白名单」，
    /// 此时任何 uid 都被放行（与「未配置」时的开放默认一致）。
    public static func load() -> Snapshot {
        let url = URL(fileURLWithPath: HelperConstants.hostsEditorsPath)
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any] else {
            return Snapshot(uids: [], usernames: [])
        }

        let rawUids = object["uids"] as? [Any] ?? []
        let uids = rawUids.compactMap { parseInt($0) }
        let rawUsernames = object["usernames"] as? [Any] ?? []
        let usernames = rawUsernames.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Snapshot(uids: uids, usernames: usernames)
    }

    /// 写入白名单。文件不存在则创建；存在则覆盖。
    /// 调用方必须已是 root（这是设计本意）。
    @discardableResult
    public static func save(_ snapshot: Snapshot) -> Result<Void, ErrorReason> {
        let directory = (HelperConstants.hostsEditorsPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: nil)
        } catch {
            return .failure(.io("\(directory) 不可写：\(error.localizedDescription)"))
        }

        let payload: [String: Any] = [
            "uids": snapshot.uids,
            "usernames": snapshot.usernames,
        ]
        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: payload, format: .binary, options: 0)
        } catch {
            return .failure(.invalid("\(error.localizedDescription)"))
        }
        let url = URL(fileURLWithPath: HelperConstants.hostsEditorsPath)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return .failure(.io("\(error.localizedDescription)"))
        }
        return .success(())
    }

    /// 解析用户输入的 uid 字符串，逗号分隔，剔除空 / 非数字 / 越界 / 负值。
    /// 应用侧的「添加」按钮用这个把字符串规整成数组。
    public static func parseUids(_ raw: String) -> [Int] {
        raw.split(separator: ",")
            .compactMap { parseNonNegativeInt(String($0.trimmingCharacters(in: .whitespacesAndNewlines))) }
    }

    /// 解析用户输入的用户名字符串，逗号分隔，去空白。
    public static func parseUsernames(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 判定给定 uid 是否在白名单内。白名单为空 → 放行任何 uid。
    /// 这是「默认开放、按需收紧」的语义：第一次安装什么都没配时
    /// 用户能立刻改 hosts，避免「装完啥也干不了」的反向体验。
    public static func isAllowed(uid: Int, snapshot: Snapshot) -> Bool {
        if snapshot.isEmpty { return true }
        return snapshot.uids.contains(uid)
    }

    /// 一份白名单的不可变快照。`uids` 是数字、唯一；
    /// `usernames` 是字符串、唯一（大小写敏感）。
    public struct Snapshot: Equatable, Sendable {
        public let uids: [Int]
        public let usernames: [String]

        public init(uids: [Int], usernames: [String]) {
            self.uids = Array(Set(uids)).sorted()
            self.usernames = Array(Set(usernames)).sorted()
        }

        public var isEmpty: Bool { uids.isEmpty && usernames.isEmpty }
    }

    public enum ErrorReason: Error, CustomStringConvertible, Equatable {
        case io(String)
        case invalid(String)

        public var description: String {
            switch self {
            case .io(let detail):      return "hosts 白名单 IO 失败：\(detail)"
            case .invalid(let detail): return "hosts 白名单格式非法：\(detail)"
            }
        }
    }

    /// 把任意 JSON/Plist 数值解析为 Int；支持 `NSNumber` / `String` / `Int`。
    /// 负数视为非法（uid 在 POSIX 下是非负数）。
    private static func parseInt(_ value: Any) -> Int? {
        if let number = value as? Int { return number >= 0 ? number : nil }
        if let number = value as? NSNumber { return number.intValue >= 0 ? number.intValue : nil }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// 字符串解析为非负整数（用户输入路径专用）。
    /// 与 `parseInt` 的差别：这里主动拒绝负号前缀 —— 用户写「-1」是手滑。
    private static func parseNonNegativeInt(_ text: String) -> Int? {
        guard !text.isEmpty, !text.hasPrefix("-") else { return nil }
        return Int(text).flatMap { $0 >= 0 ? $0 : nil }
    }
}