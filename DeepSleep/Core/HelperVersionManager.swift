//
//  HelperVersionManager.swift
//  Deep Sleep
//
//  判断装着的特权助手是不是应用内置的那一份，不是就地更新它。
//
//  **判据是二进制内容摘要，不是版本号、也不是构建序号。** 理由：
//
//    - 摘要是最准的：「助手代码有没有变」正是我们真正关心的问题。
//      只改了应用代码没动助手时，摘要不变，助手就不需要重装 —— 版本号判据
//      会误判成「要更新」，白折腾一次还重启进程。
//    - 摘要不需要任何人为维护。版本号、构建号都得靠人记得改；
//      忘改就是「明明修好了却不更新」，改错就是「每次都更新一遍」。
//    - 它天然收敛：替换成功后两边摘要必然一致，下次不会再触发。
//      不存在来回替换的循环 —— 这是这类功能最容易踩的坑。
//
//  三种状态处理方式完全不同：
//    1. 助手未安装 —— 用户没启用「完全控制」，属正常状态，什么都不做；
//    2. 助手在跑但不回报摘要（旧版）—— 它没有自我更新命令，
//       只能提示用户走一次管理员授权重装；
//    3. 助手在跑且回报了摘要，但与内置的不同 —— 用 updateSelf 就地替换。
//
//  **两条入口，两种节奏：**
//
//    - 自动：`checkAndUpdateIfNeeded()`。启动后检查一次，发现不同就地替换，
//      全程不需要密码。失败时本轮不再重试（重试只会制造循环），
//      失败原因留在 `state` 里，界面上能看到。
//    - 手动：`refresh()` 先只看不动，`updateNow()` 再真正更新。
//      界面上的「立即检查并更新」走这条 —— 用户点了就必须给回话：
//      要么说清差异并问要不要更新，要么明确告诉他「已经是最新」。
//
//  为什么手动这条路要绕开「本次运行只试一次」的限制：那条限制是给自动路径
//  防重试循环用的。用户手动点击是明确意图，用同一把锁会得到
//  「点了没反应、也没解释」—— 这是最难排查的一类反馈缺失（曾真实发生过）。

import CryptoKit
import Foundation

@MainActor
final class HelperVersionManager: ObservableObject {

    static let shared = HelperVersionManager()

    enum State: Equatable {
        /// 助手未安装（用户尚未启用完全控制）。
        case notInstalled
        /// 助手装了但没响应：launchd 层面的问题，不是版本问题。
        case unreachable
        /// 装着的就是应用内置的那一份。
        case upToDate(installed: String)
        /// 与内置的不是同一份，正在或可以自我更新。
        case outdated(installed: String, target: String)
        /// 落后且不支持自我更新，需要重新授权安装。
        case needsReinstall
        /// 更新尝试失败。带上原因，避免用户只看到「失败」两个字。
        case updateFailed(String)

        /// 对外显示用的短摘要 —— 完整 64 位十六进制对人是噪音。
        static func short(_ digest: String) -> String {
            String(digest.prefix(8))
        }

        var text: String {
            switch self {
            case .notInstalled:
                return "未安装（在「完全控制」里启用即可）"
            case .unreachable:
                return "已安装但没有响应（可能正在重启；也可能是 launchd 层面的问题，可稍等几秒再点一次）"
            case .upToDate(let installed):
                return "与内置版本一致（\(Self.short(installed))）"
            case .outdated(let installed, let target):
                return "与内置版本不同（已装 \(Self.short(installed)) → 内置 \(Self.short(target))）"
            case .needsReinstall:
                return "是旧版助手，不认识自动更新命令，需要重新授权安装一次"
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

    /// 手动更新的结果。界面拿它决定弹哪个对话框 —— 所以每一个分支都得有话说。
    enum ManualOutcome: Equatable {
        /// 本来就已经一致，什么都不用做。
        case noChange(installed: String)
        /// 更新成功，助手已用新摘要报到。
        case updated(installed: String)
        /// 旧版助手，只能重新授权安装。
        case needsReinstall
        /// 没装助手。
        case notInstalled
        /// 装了但没响应。
        case unreachable
        /// 失败，带原因。
        case failed(String)

        var isSuccess: Bool {
            switch self {
            case .updated: return true
            default:       return false
            }
        }
    }

    @Published private(set) var state: State = .notInstalled

    /// 正在更新中。手动路径用它防连点 —— 助手替换期间会短暂离线，
    /// 连点会拿到一串「连不上」的假失败。
    @Published private(set) var isUpdating = false

    /// 自动路径本次运行已尝试的次数。上限 1 —— 更新失败时重试除了制造循环
    /// 没有任何好处，下一次启动自然会再检查一次。
    /// **手动路径不读这个计数**，理由见文件头。
    private var autoAttemptsThisRun = 0
    private let maxAutoAttemptsPerRun = 1

    /// 自动路径是否被挂起。给「用户明确要自己接管」的入口用
    /// （命令行 `--helper-update`）：否则自动检查可能在手动替换进行到一半时
    /// 也发出一条 updateSelf，两条路径同时替换同一个 root 二进制。
    private var automaticUpdatesSuspended = false

    /// 手动接管：本进程不再自动尝试更新助手。
    func suspendAutomaticUpdates() {
        automaticUpdatesSuspended = true
    }

    /// 助手重启并报到新摘要所需的最长等待（每次轮询 0.5 秒）。
    private let confirmationPolls = 20

    /// 内置助手的摘要。同一个应用包内容不会变，算一次即可。
    private var embeddedDigestCache: String?

    private init() {}

    // MARK: - 自动路径

    /// 探测并在必要时更新助手。启动后由对账循环调用。
    /// - Returns: 是否确实完成了一次更新。
    @discardableResult
    func checkAndUpdateIfNeeded() async -> Bool {
        // 手动替换正在进行、或用户已接管时不要插一脚：
        // 两条路径同时替换同一个 root 二进制只会互相踩。
        guard !automaticUpdatesSuspended, !isUpdating else { return false }

        switch await inspect() {
        case .outdated(let installed, let target):
            guard autoAttemptsThisRun < maxAutoAttemptsPerRun else { return false }
            autoAttemptsThisRun += 1
            return await performSelfUpdate(installed: installed, target: target)
        default:
            return false
        }
    }

    // MARK: - 手动路径

    /// 只看不动：刷新状态并返回它，供界面先展示差异。
    @discardableResult
    func refresh() async -> State {
        _ = await inspect()
        return state
    }

    /// 手动更新。**不受自动路径的次数限制**，但会防连点。
    func updateNow() async -> ManualOutcome {
        guard !isUpdating else { return .failed("正在更新中，请稍候") }
        isUpdating = true
        defer { isUpdating = false }

        switch await inspect() {
        case .notInstalled:
            return .notInstalled
        case .unreachable:
            return .unreachable
        case .needsReinstall:
            return .needsReinstall
        case .missingEmbedded:
            return .failed("读不到应用内置的助手，请重新下载安装应用")
        case .upToDate(let installed):
            return .noChange(installed: installed)
        case .outdated(let installed, let target):
            let ok = await performSelfUpdate(installed: installed, target: target)
            if ok {
                return .updated(installed: target)
            }
            // 失败了：state 里已经有具体原因，把它原样交给界面，
            // 不要换成「更新失败」这种没有信息量的说法。
            if case .updateFailed(let reason) = state {
                return .failed(reason)
            }
            return .failed("更新未完成，原因未知")
        }
    }

    // MARK: - 探测

    /// 一次探测的结论。与 `State` 分开：这里表达「事实」，
    /// `State` 表达「给用户看的话」，两者不必一一对应。
    private enum Inspection {
        case notInstalled
        case unreachable
        case missingEmbedded
        case needsReinstall
        case upToDate(installed: String)
        case outdated(installed: String, target: String)
    }

    private func inspect() async -> Inspection {
        guard HelperInstaller.isInstalled else {
            state = .notInstalled
            return .notInstalled
        }

        let probe = await HelperClient.shared.probe()
        guard probe.reachable else {
            // 装了但没跑起来：这是 launchd 层面的问题，不是版本问题。
            // 不去更新它 —— 对没响应的助手发更新命令也不会成功。
            state = .unreachable
            return .unreachable
        }

        guard let target = embeddedDigest() else {
            state = .updateFailed("读不到应用内置的助手，请重新安装应用")
            return .missingEmbedded
        }

        // 读不到摘要：旧版助手，没有自我更新能力。
        guard let installed = probe.digest, !installed.isEmpty else {
            state = .needsReinstall
            return .needsReinstall
        }

        // 核心判断：内容一致就什么都不做。
        guard installed != target else {
            state = .upToDate(installed: installed)
            return .upToDate(installed: installed)
        }

        state = .outdated(installed: installed, target: target)
        return .outdated(installed: installed, target: target)
    }

    // MARK: - 内置助手的摘要

    /// 应用包内那份助手的摘要。
    /// 读不到时返回 nil —— 调用方必须当作「判断不了」，而不是「需要更新」。
    private func embeddedDigest() -> String? {
        if let cached = embeddedDigestCache { return cached }
        let path = HelperInstaller.embeddedHelperPath
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        embeddedDigestCache = digest
        return digest
    }

    // MARK: - 执行更新

    private func performSelfUpdate(installed: String, target: String) async -> Bool {
        let source = HelperInstaller.embeddedHelperPath
        guard !target.isEmpty else {
            state = .updateFailed("应用内置的助手缺失，请重新安装应用")
            return false
        }

        do {
            let response = try await HelperClient.shared.send(
                .init(command: .updateSelf, arguments: [
                    "source": source,
                    "sha256": target
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

        SleepController.shared.appendLog(
            "已请求助手自我更新（\(State.short(installed)) → \(State.short(target))），等待其重启")

        // 等它重启并报出新摘要。这一步不能省 —— 不确认就宣称成功，
        // 用户会看到「更新了但没变化」，而这是最难排查的一类问题。
        for _ in 0..<confirmationPolls {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let probe = await HelperClient.shared.probe()
            if let digest = probe.digest, digest == target {
                state = .upToDate(installed: digest)
                SleepController.shared.appendLog("助手已更新，摘要 \(State.short(digest))")
                return true
            }
        }

        state = .updateFailed("助手重启后未能在 \(confirmationPolls / 2) 秒内报到新摘要")
        SleepController.shared.appendLog(
            "助手更新后未能确认新摘要，本次不再重试（下次启动会再检查）", isError: true)
        return false
    }
}
