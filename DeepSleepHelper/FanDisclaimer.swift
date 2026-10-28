//
//  FanDisclaimer.swift
//  deepsleep-helper
//
//  风扇免责声明的助手侧门禁与持久化。
//
//  ============================================================================
//  为什么助手侧要自己存一份
//  ============================================================================
//  应用侧的同意状态（UserDefaults）拦不住「绕过 UI 直接构造协议包打助手」——
//  socket 就在 /var/run，任何有权限连进来的进程都能直接发 setFanSpeed。
//  风扇写入是本项目风险最高的功能（写错可能让风扇停转），所以门禁必须落在
//  **执行点**：助手自己持久化一份同意状态，每次真正写 SMC 之前自己查一遍。
//
//  应用在用户勾选同意后通过 `setFanDisclaimerAccepted` 把状态同步过来，
//  应用启动时也会同步一次。两条链路各存一份，互不信任。
//
//  ============================================================================
//  存哪、谁能读
//  ============================================================================
//  `/var/db/deepsleep/fan-disclaimer.json`，目录 0700、文件 0600，owner root。
//  助手以 root 跑（launchd LaunchDaemon），普通用户改不了 —— 这正是要的效果：
//  想绕过 UI 打开风扇控制，得先拿到 root。
//
//  版本语义：声明正文有实质变化时 `FanControl.disclaimerVersion` +1，
//  老用户存的 version 低于当前值就算「没同意」，必须重新同意一次。
//

import Foundation

/// 风扇免责声明的持久化 + 门禁。
///
/// 助手进程内单例。启动时读一次，之后以内存值为准（写入同时落盘）。
final class FanDisclaimer {

    static let shared = FanDisclaimer()

    // MARK: - 落盘位置

    private static let directoryPath = "/var/db/deepsleep"
    private static let filePath = "/var/db/deepsleep/fan-disclaimer.json"

    // MARK: - 状态

    /// 落盘的结构。字段名固定，应用侧不读它 —— 这份文件只给助手自己看。
    private struct Store: Codable {
        var accepted: Bool
        var version: Int
        var updatedAt: String
    }

    private let lock = NSLock()
    private var store: Store

    // MARK: - 初始化

    private init() {
        store = Self.load()
    }

    /// 读盘。文件不存在 / 内容损坏 / 权限异常都当作「未同意」——
    /// 安全功能的失败方向必须是保守的那一侧。
    private static func load() -> Store {
        let fallback = Store(accepted: false, version: 0, updatedAt: "")
        guard let data = FileManager.default.contents(atPath: filePath),
              let decoded = try? JSONDecoder().decode(Store.self, from: data) else {
            return fallback
        }
        return decoded
    }

    // MARK: - 查询

    /// 用户是否已明确同意（且同意的是当前版本的声明）。
    var isAccepted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return store.accepted && store.version >= FanControl.disclaimerVersion
    }

    /// 当前落盘的声明版本（0 = 从没同意过）。
    var acceptedVersion: Int {
        lock.lock()
        defer { lock.unlock() }
        return store.version
    }

    /// 门禁。写 SMC 的入口必须先过这一关。
    ///
    /// 抛出的 message 里带「需先同意免责声明」—— 应用侧靠这句话做 UI 提示，
    /// 措辞不要改。
    func requireAccepted() throws {
        guard isAccepted else {
            throw FanDisclaimerError.notAccepted
        }
    }

    // MARK: - 写入

    /// 更新同意状态并落盘。
    ///
    /// - Parameter accepted: true = 用户已同意当前版本；false = 撤回同意。
    /// - Throws: 目录 / 文件写不进去时抛错。**落盘失败不能静默** ——
    ///   否则会出现「应用以为开了，助手重启后又不认」的鬼状态。
    func setAccepted(_ accepted: Bool) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let updated = Store(
            accepted: accepted,
            version: accepted ? FanControl.disclaimerVersion : 0,
            updatedAt: now)

        try Self.persist(updated)

        lock.lock()
        store = updated
        lock.unlock()
    }

    /// 写盘：目录 0700、文件 0600，先写临时文件再原子替换。
    private static func persist(_ value: Store) throws {
        let manager = FileManager.default

        if !manager.fileExists(atPath: directoryPath) {
            try manager.createDirectory(
                atPath: directoryPath,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)

        let temporaryPath = "\(filePath).tmp.\(getpid())"
        guard manager.createFile(
            atPath: temporaryPath,
            contents: data,
            attributes: [.posixPermissions: 0o600]) else {
            throw FanDisclaimerError.writeFailed("无法创建 \(temporaryPath)")
        }

        // rename 在同一文件系统内是原子的，不会留下半截文件。
        if rename(temporaryPath, filePath) != 0 {
            let code = errno
            try? manager.removeItem(atPath: temporaryPath)
            throw FanDisclaimerError.writeFailed(
                "rename 到 \(filePath) 失败：\(String(cString: strerror(code)))")
        }

        // rename 保留原 inode 的权限位；这里再显式设一次，防止 umask 干扰。
        try? manager.setAttributes(
            [.posixPermissions: 0o600, .ownerAccountID: 0],
            ofItemAtPath: filePath)
    }
}

// MARK: - 错误

enum FanDisclaimerError: Error, CustomStringConvertible {
    /// 未同意免责声明。
    case notAccepted
    /// 落盘失败。
    case writeFailed(String)

    var description: String {
        switch self {
        case .notAccepted:
            // 这句话是应用侧的 UI 触发词，别改措辞。
            return "需先同意免责声明"
        case .writeFailed(let detail):
            return "保存免责声明状态失败：\(detail)"
        }
    }
}
