//
//  HelperVersionManager.swift
//  Deep Sleep
//
//  检测已安装的特权助手是否落后于应用内置的版本，必要时就地更新它。
//
//  三种状态必须分清，因为处理方式完全不同：
//    1. 助手未安装 —— 用户没启用「完全控制」，属正常状态，什么都不做；
//    2. 助手在跑但读不到 build（旧版）—— 它没有自我更新命令，
//       只能提示用户走一次管理员授权重装；
//    3. 助手在跑且读到了 build，但落后 —— 用 updateSelf 命令就地替换。
//
//  **防循环是这里的核心要求** —— 版本判断写错就会变成「每次启动都更新一遍」。
//  一共三道防线：
//    - 判据是 `已安装 build < 内置 build`，不是「两者不相等」。
//      若用「不相等」，一旦应用比助手旧就会反复降级再升级，永不停止；
//    - 每次应用运行最多尝试一次自动更新，失败即停手，留给下次启动；
//    - 更新后必须重新探测到新 build 才算成功，确认不到就记失败、不重试。
//

import CryptoKit
import Foundation

@MainActor
final class HelperVersionManager: ObservableObject {

    static let shared = HelperVersionManager()

    enum State: Equatable {
        /// 助手未安装（用户尚未启用完全控制）。
        case notInstalled
        /// 已是最新。
        case upToDate(installed: Int)
        /// 落后，正在或可以自我更新。
        case outdated(installed: Int?, target: Int)
        /// 落后且不支持自我更新，需要重新授权安装。
        case needsReinstall(installed: Int?, target: Int)
        /// 更新尝试失败。带上原因，避免用户只看到「失败」两个字。
        case updateFailed(String)

        var text: String {
            switch self {
            case .notInstalled:
                return "未安装（在「完全控制」里启用即可）"
            case .upToDate(let installed):
                return "已是内置的最新版本（构建 \(installed)）"
            case .outdated(let installed, let target):
                return "落后于应用内置版本（\(installed.map(String.init) ?? "?") → \(target)）"
            case .needsReinstall:
                return "是旧版本助手，且它不认识自动更新命令，需要重新授权安装一次"
            case .updateFailed(let reason):
                return "更新失败：\(reason)"
            }
        }

        /// 是否需要用户关注（未安装不算，那是正常状态）。
        var needsAttention: Bool {
            switch self {
            case .notInstalled, .upToDate: return false
            default:                       return true
            }
        }
    }

    @Published private(set) var state: State = .notInstalled

    /// 本次运行已尝试的自动更新次数。上限 1 —— 更新失败时重试除了制造循环
    /// 没有任何好处，下一次启动自然会再检查一次。
    private var attemptsThisRun = 0
    private let maxAttemptsPerRun = 1

    /// 助手重启并报到新版本所需的最长等待（每次轮询 0.5 秒）。
    private let confirmationPolls = 20

    private init() {}

    /// 探测并在必要时更新助手。
    /// - Returns: 是否确实完成了一次更新。
    @discardableResult
    func checkAndUpdateIfNeeded() async -> Bool {
        guard HelperInstaller.isInstalled else {
            state = .notInstalled
            return false
        }

        let probe = await HelperClient.shared.probe()
        guard probe.reachable else {
            // 装了但没跑起来：这是 launchd 层面的问题，不是版本问题。
            // 不去更新它 —— 对没响应的助手发更新命令也不会成功。
            return false
        }

        let target = HelperConstants.helperBuild

        // 读不到 build：旧版助手，没有自我更新能力。
        guard let installed = probe.build else {
            state = .needsReinstall(installed: nil, target: target)
            return false
        }

        // 核心判断：只有**严格落后**才更新。相等不装、更新也不装。
        guard installed < target else {
            state = .upToDate(installed: installed)
            return false
        }

        state = .outdated(installed: installed, target: target)
        guard attemptsThisRun < maxAttemptsPerRun else { return false }
        attemptsThisRun += 1

        return await performSelfUpdate(from: installed, to: target)
    }

    // MARK: - 执行更新

    private func performSelfUpdate(from installed: Int, to target: Int) async -> Bool {
        let source = HelperInstaller.embeddedHelperPath
        guard let bytes = FileManager.default.contents(atPath: source), !bytes.isEmpty else {
            state = .updateFailed("应用内置的助手缺失，请重新安装应用")
            return false
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        do {
            let response = try await HelperClient.shared.send(
                .init(command: .updateSelf, arguments: [
                    "source": source,
                    "sha256": digest,
                    "build": "\(target)"
                ]),
                timeout: 30
            )
            guard response.success else {
                state = .updateFailed(response.message)
                SleepController.shared.appendLog("助手自我更新被拒绝：\(response.message)", isError: true)
                return false
            }
        } catch {
            state = .updateFailed(error.localizedDescription)
            SleepController.shared.appendLog("助手自我更新请求失败：\(error.localizedDescription)", isError: true)
            return false
        }

        SleepController.shared.appendLog("已请求助手自我更新（构建 \(installed) → \(target)），等待其重启")

        // 等它重启并报出新版本。这一步不能省 —— 不确认就宣称成功，
        // 用户会看到「更新了但版本没变」，而这是最难排查的一类问题。
        for _ in 0..<confirmationPolls {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let probe = await HelperClient.shared.probe()
            if let build = probe.build, build >= target {
                state = .upToDate(installed: build)
                SleepController.shared.appendLog("助手已更新到构建 \(build)")
                return true
            }
        }

        state = .updateFailed("助手重启后未能在 \(confirmationPolls / 2) 秒内报到新版本")
        SleepController.shared.appendLog(
            "助手更新后未能确认新版本，本次不再重试（下次启动会再检查）", isError: true)
        return false
    }
}
