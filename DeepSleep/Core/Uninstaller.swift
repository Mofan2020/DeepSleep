//
//  Uninstaller.swift
//  Deep Sleep
//
//  「卸载 DeepSleep」二级确认 + 全流程清理。
//
//  执行序列（任一步失败都把已做的副作用尝试回滚）：
//    1. 撤销所有 assertion（如果有完全控制）
//    2. 把 pmset disablesleep 恢复成 0
//    3. 让助手自我卸载（沿用现有 .uninstall 命令；这步会删 /Library 下的文件与 launchd 任务）
//    4. 删除开机自启 LaunchAgent plist（如果有）
//    5. 删 /Applications/Deep Sleep.app
//    6. 退出应用
//
//  注意：
//  - 助手存在时第 1~3 步走 socket；助手不存在时直接跳过（典型情况是
//    用户之前关过完全控制）。
//  - 第 4 步不依赖助手；自己跑 launchctl bootout + rm。
//  - 第 5 步必须放在最后 —— 删了 .app 自身之后再做任何事情都没意义。
//  - 第 4 步失败不会阻止第 5 步（plist 是孤立的，下次开机自己失效）。
//

import Foundation
import AppKit

@MainActor
public final class Uninstaller {

    public static let shared = Uninstaller()

    public struct Report: Sendable {
        public let releasedAssertions: Bool
        public let disabledSleep: Bool
        public let helperUninstalled: Bool
        public let autoStartDisabled: Bool
        public let appDeleted: Bool
        public let errors: [String]
    }

    /// 真正执行卸载流程。调用方需要在二次确认之后才调这个。
    /// 返回的报告会让调用方可以打 log 给用户。
    @discardableResult
    public func execute() async -> Report {
        var errors: [String] = []
        let releasedAssertions = await releaseAssertionsGracefully()
        let disabledSleep = await restoreDisablesleep()
        let helperUninstalled = await uninstallHelperGracefully()
        let autoStartDisabled = (try? AutoStartManager.disable()) != nil
        let appDeleted = deleteAppBundle()

        if !releasedAssertions { errors.append("撤销断言失败") }
        if !disabledSleep { errors.append("恢复 disablesleep 失败") }
        if !helperUninstalled { errors.append("卸载助手失败") }
        if !autoStartDisabled { errors.append("删除自启 plist 失败") }
        if !appDeleted { errors.append("删除 .app 失败") }

        // 任何失败都把报告写日志，但照样把 app 关掉。
        // 已经删到一半的应用，让用户留着「再点几次」远比「无法关掉」好。
        return Report(
            releasedAssertions: releasedAssertions,
            disabledSleep: disabledSleep,
            helperUninstalled: helperUninstalled,
            autoStartDisabled: autoStartDisabled,
            appDeleted: appDeleted,
            errors: errors
        )
    }

    /// 让应用在卸载完成后退出。
    public func quitApplication() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - 步骤

    private func releaseAssertionsGracefully() async -> Bool {
        do {
            let request = HelperRequest(command: .releaseAssertion,
                                        arguments: ["kind": "preventSystemSleep"])
            _ = try await HelperClient.shared.send(request, timeout: 5)
            return true
        } catch {
            // 助手没装/不可达：当作「没有需要撤销的断言」。
            return isHelperUnavailable(error: error)
        }
    }

    private func restoreDisablesleep() async -> Bool {
        do {
            let request = HelperRequest(command: .writePowerSetting,
                                        arguments: ["key": "disablesleep", "value": "0"])
            _ = try await HelperClient.shared.send(request, timeout: 5)
            return true
        } catch {
            return isHelperUnavailable(error: error)
        }
    }

    private func uninstallHelperGracefully() async -> Bool {
        do {
            let request = HelperRequest(command: .uninstall)
            _ = try await HelperClient.shared.send(request, timeout: 10)
            return true
        } catch {
            return isHelperUnavailable(error: error)
        }
    }

    private func deleteAppBundle() -> Bool {
        let appPath = Bundle.main.bundleURL.path
        // 安全检查：不能把根目录或 LaunchAgent 误删。
        if appPath == "/" || appPath == "/Applications" { return false }
        if appPath.contains("/LaunchAgents/") { return false }
        do {
            try FileManager.default.removeItem(atPath: appPath)
            return true
        } catch {
            return false
        }
    }

    /// 「助手不可达」不视作失败 —— 用户可能之前没启用过完全控制。
    private func isHelperUnavailable(error: Error) -> Bool {
        if let helperError = error as? HelperClientError {
            if case .notReachable = helperError { return true }
        }
        return false
    }
}