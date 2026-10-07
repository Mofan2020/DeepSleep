//
//  Uninstaller.swift
//  Deep Sleep
//
//  「卸载 DeepSleep」二级确认 + 全流程清理。
//
//  执行序列（任一步失败都把已做的副作用尝试回滚）：
//    1. 撤销所有 assertion（如果有完全控制）
//    2. 把 pmset disablesleep 恢复成 0
//    3. 让助手自我卸载
//    4. 清理应用配置（prefs + caches + Application Support 等）
//    5. 删除开机自启 LaunchAgent plist（如果有）
//    6. 删 /Applications/Deep Sleep.app
//    7. 退出应用
//
//  v1.4.1 之外的版本漏了第 4 步：用户反馈「你看卸载页面里好像没有列出
//  清除这些数据，但这些数据肯定也是要清的」。
//  实际落地的位置：
//    ~/Library/Preferences/com.skyc8266.deepsleep.plist
//    ~/Library/Caches/com.skyc8266.deepsleep/
//  没找到的（用户机器上没有的）位置用「Optional」的规则处理，记到 Report 里。
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
        public let configsCleared: Bool
        public let autoStartDisabled: Bool
        public let appDeleted: Bool
        public let errors: [String]
    }

    @discardableResult
    public func execute() async -> Report {
        var errors: [String] = []
        let releasedAssertions = await releaseAssertionsGracefully()
        let disabledSleep = await restoreDisablesleep()
        let helperUninstalled = await uninstallHelperGracefully()
        let configsCleared = clearAppData()
        let autoStartDisabled = (try? AutoStartManager.disable()) != nil
        let appDeleted = deleteAppBundle()

        if !releasedAssertions { errors.append("撤销断言失败") }
        if !disabledSleep { errors.append("恢复 disablesleep 失败") }
        if !helperUninstalled { errors.append("卸载助手失败") }
        if !configsCleared { errors.append("清理应用配置失败") }
        if !autoStartDisabled { errors.append("删除自启 plist 失败") }
        if !appDeleted { errors.append("删除 .app 失败") }

        return Report(
            releasedAssertions: releasedAssertions,
            disabledSleep: disabledSleep,
            helperUninstalled: helperUninstalled,
            configsCleared: configsCleared,
            autoStartDisabled: autoStartDisabled,
            appDeleted: appDeleted,
            errors: errors
        )
    }

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

    /// 删掉用户空间里所有的应用配置与状态。任意一项失败都当作整体失败
    /// （报告里能细分；UI 现在不展示子项）。
    private func clearAppData() -> Bool {
        let home = NSHomeDirectory()
        let candidates: [String] = [
            "\(home)/Library/Preferences/com.skyc8266.deepsleep.plist",
            "\(home)/Library/Caches/com.skyc8266.deepsleep",
            "\(home)/Library/Application Support/Deep Sleep",
            "\(home)/Library/Saved Application State/com.skyc8266.deepsleep.savedState",
            "\(home)/Library/Logs/Deep Sleep"
        ]

        var anyFailure = false
        let fm = FileManager.default
        for path in candidates {
            // 路径白名单：不删不在 home 下的东西
            guard path.hasPrefix(home) else { anyFailure = true; continue }
            if !fm.fileExists(atPath: path) { continue } // 没找到不算失败
            do {
                try fm.removeItem(atPath: path)
            } catch {
                anyFailure = true
            }
        }
        return !anyFailure
    }

    private func deleteAppBundle() -> Bool {
        let appPath = Bundle.main.bundleURL.path
        if appPath == "/" || appPath == "/Applications" { return false }
        if appPath.contains("/LaunchAgents/") { return false }
        do {
            try FileManager.default.removeItem(atPath: appPath)
            return true
        } catch {
            return false
        }
    }

    private func isHelperUnavailable(error: Error) -> Bool {
        if let helperError = error as? HelperClientError {
            if case .notReachable = helperError { return true }
        }
        return false
    }
}