//
//  AppDelegate.swift
//  Deep Sleep
//
//  负责应用生命周期的收尾工作：退出前把 assertion 与系统电源设置恢复原样。
//  同时提供命令行接口，让 Deep Sleep 可以被脚本与自动化工具调度。
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await SleepController.shared.bootstrap()
            await Self.handleLaunchArguments()
        }
    }

    /// 退出前先异步清理：释放 assertion、按需恢复 disablesleep。
    /// 用 `.terminateLater` 保证清理动作能跑完，不会留下占用中的 assertion。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await SleepController.shared.shutdown()
            await SleepController.shared.restoreSleepDisabledIfNeeded()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 保留菜单栏常驻能力，不因关闭窗口而退出。
        false
    }

    // MARK: - 命令行接口

    /// 支持的参数：
    ///   --hold <kinds>   逗号分隔，接受 idle-system / display / system 及其别名
    ///   --release        释放全部保持
    ///   --status         把当前状态输出到标准输出
    /// 例如：`open -a "Deep Sleep" --args --hold idle-system,display`
    @MainActor
    private static func handleLaunchArguments() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else { return }

        let controller = SleepController.shared
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--hold":
                guard index + 1 < arguments.count else {
                    emit("--hold 需要一个参数，例如 --hold idle-system")
                    index += 1
                    continue
                }
                let raw = arguments[index + 1]
                let kinds = raw
                    .split(separator: ",")
                    .compactMap { AssertionKind.fromCLIName(String($0)) }
                guard !kinds.isEmpty else {
                    emit("无法识别的保持类型：\(raw)")
                    index += 2
                    continue
                }
                for kind in kinds {
                    await controller.setAssertion(kind, enabled: true)
                }
                // 如实报告结果，而不是只报「已请求」——
                // 需要完全控制的类型在没有助手时会静默失败。
                let applied = kinds.filter { controller.activeAssertions.contains($0) }
                let rejected = kinds.filter { !controller.activeAssertions.contains($0) }
                if !applied.isEmpty {
                    emit("已生效：\(applied.map(\.cliName).joined(separator: ", "))")
                }
                if !rejected.isEmpty {
                    emit("未生效：\(rejected.map(\.cliName).joined(separator: ", "))"
                         + "（该类型需要先启用完全控制，请在应用内操作）")
                }
                index += 2

            case "--release":
                await controller.releaseAllAssertions()
                emit("已释放全部保持")
                index += 1

            case "--status":
                emit(summary(from: controller))
                index += 1

            case "--wait":
                // 让 --status 能在运行一段时间后再报告，
                // 用于验证周期对账确实按预期频率在跑。
                guard index + 1 < arguments.count, let seconds = Double(arguments[index + 1]) else {
                    emit("--wait 需要一个秒数，例如 --wait 10")
                    index += 1
                    continue
                }
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                index += 2

            case "--enable-full-control":
                // 触发一次性管理员授权，安装特权助手。
                // 与界面上的按钮等价，便于脚本化部署。
                emit("正在请求管理员授权以安装特权助手…")
                await controller.installHelper()
                await controller.refreshHelperState()
                emit(summary(from: controller))
                index += 1

            case "--disable-full-control":
                emit("正在卸载特权助手并恢复系统原状…")
                await controller.uninstallHelper()
                emit(summary(from: controller))
                index += 1

            default:
                index += 1
            }
        }
    }

    @MainActor
    private static func summary(from controller: SleepController) -> String {
        let active = controller.activeAssertions
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.cliName)
            .joined(separator: ",")
        let base = """
        hold=\(active.isEmpty ? "none" : active) \
        count=\(controller.activeAssertions.count) \
        fullControl=\(controller.helperState.isReady ? "on" : "off") \
        sleepDisabled=\(controller.sleepDisabled ? "1" : "0") \
        desiredSleepDisabled=\(controller.desiredSleepDisabled ? "1" : "0") \
        backingAssertion=\(controller.sleepDisabledBacking ? "1" : "0") \
        powerWatcher=\(PowerWatcher.shared.isRegistered ? "on" : "off")
        """
        return base + " " + controller.auditSummary
    }

    /// 同时写到标准输出与系统日志，两条通路都能取到结果。
    private static func emit(_ text: String) {
        FileHandle.standardOutput.write(Data(("deepsleep: " + text + "\n").utf8))
        NSLog("[DeepSleep] %@", text)
    }
}
