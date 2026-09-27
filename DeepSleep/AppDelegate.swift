//
//  AppDelegate.swift
//  Deep Sleep
//
//  负责应用生命周期的收尾工作：退出前把 assertion 与系统电源设置恢复原样。
//  同时提供命令行接口，让 Deep Sleep 可以被脚本与自动化工具调度。
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 菜单栏常驻入口。必须由 AppDelegate 强引用，
    /// 否则控制器一释放，NSStatusItem 跟着消失、图标直接不见。
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowCoordinator.shared.observeWindowLifecycle()

        Task { @MainActor in
            await SleepController.shared.bootstrap()
            // 菜单栏手动搭：需要区分左键（打开主界面）与右键（快速设置），
            // SwiftUI 的 MenuBarExtra 做不到这件事。
            menuBar = MenuBarController(controller: .shared)
            await Self.handleLaunchArguments()
        }
    }

    /// 关掉所有窗口后应用退成菜单栏模式（没有 Dock 图标），
    /// 此时从访达或聚焦再次打开应该把界面带回来，而不是「点了没反应」。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Task { @MainActor in WindowCoordinator.shared.showMainWindow() }
        }
        return true
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
    ///   --window-self-test  自检窗口显示与 Dock 图标策略
    ///   --blockers       列出当前所有在阻止休眠的进程
    ///   --changes        列出检测到的电源设置改动
    ///   --rivals         列出其他会改电源设置的程序
    ///   --helper-version 显示助手的版本状态
    ///   --update-check   立即检查应用更新并输出结果
    ///   --update-script  打印将要执行的更新器脚本（只打印，不执行）
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

            case "--window-self-test":
                await Self.runWindowSelfTest()
                index += 1

            case "--blockers":
                Self.emitBlockers()
                index += 1

            case "--changes":
                Self.emitChanges()
                index += 1

            case "--rivals":
                Self.emitRivals()
                index += 1

            case "--helper-version":
                Self.emitHelperVersion()
                index += 1

            case "--update-script":
                Self.emitUpdateScript()
                index += 1

            case "--update-check":
                await UpdateManager.shared.checkForUpdates()
                Self.emit("更新检查 —— \(UpdateManager.shared.phase.text)")
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
        powerWatcher=\(PowerWatcher.shared.isRegistered ? "on" : "off") \
        dockIcon=\(NSApp.activationPolicy() == .accessory ? "hidden" : "visible")
        """
        return base + " " + controller.auditSummary
    }

    /// 窗口显示与 Dock 图标策略的自检。
    /// 覆盖真实路径：关掉主窗口应当隐藏 Dock 图标，再次打开应当恢复并置前。
    /// 这套行为靠肉眼点菜单栏很难稳定复现，所以留一个可脚本化的入口。
    @MainActor
    private static func runWindowSelfTest() async {
        func snapshot() -> String {
            // 注意：NSApplication 上这是方法，NSRunningApplication 上才是属性。
            let policy = NSApp.activationPolicy() == .accessory
                ? "accessory（无 Dock 图标）"
                : "regular（有 Dock 图标）"
            let visible = NSApp.windows.filter {
                !($0 is NSPanel) && $0.isVisible && $0.styleMask.contains(.titled)
            }
            return "policy=\(policy) visibleWindows=\(visible.count)"
        }

        emit("窗口自检开始 —— \(snapshot())")
        // 菜单栏入口是这次改动的核心之一，NSStatusBar 没有查询接口，
        // 只能靠控制器自己登记的弱引用确认它确实建起来了。
        emit("菜单栏入口 —— \(MenuBarController.current == nil ? "缺失" : "已就绪")")

        // 左键必须打开主界面、右键必须弹出设置，两边错一个都会让用户觉得「点了没反应」。
        let leftPrimary = !MenuBarController.isSecondaryClick(eventType: .leftMouseUp, modifiers: [])
        let rightSecondary = MenuBarController.isSecondaryClick(eventType: .rightMouseUp, modifiers: [])
        let controlSecondary = MenuBarController.isSecondaryClick(eventType: .leftMouseUp, modifiers: [.control])
        emit("点击判定 —— 左键=\(leftPrimary ? "打开主界面" : "判定错误")"
             + " / 右键=\(rightSecondary ? "弹出设置" : "判定错误")"
             + " / Control+左键=\(controlSecondary ? "弹出设置" : "判定错误")")

        // 菜单内容也一并校验：弹出菜单是模态的，自动化测试会卡死，
        // 所以只构建不弹出，核对项数与勾选状态。
        if let menu = MenuBarController.current?.makeMenu() {
            let titles = menu.items.filter { !$0.isSeparatorItem }.map {
                ($0.state == .on ? "☑ " : "☐ ") + $0.title
            }
            emit("右键菜单 \(titles.count) 项 —— \(titles.joined(separator: " | "))")
        } else {
            emit("右键菜单 —— 构建失败")
        }

        // 主窗口由 SwiftUI 在启动流程里创建，可能比这里晚一拍，最多等 3 秒。
        var window: NSWindow?
        for _ in 0..<30 {
            window = NSApp.windows.first {
                !($0 is NSPanel) && $0.isVisible && $0.styleMask.contains(.titled)
            }
            if window != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let window else {
            // 失败时把窗口的真实情况打出来，否则分不清是「SwiftUI 没创建」
            // 还是「创建了但被上面的过滤条件排除掉」。
            let detail = NSApp.windows.map {
                "「\($0.title)」visible=\($0.isVisible) titled=\($0.styleMask.contains(.titled)) panel=\($0 is NSPanel)"
            }.joined(separator: " / ")
            emit("窗口自检失败：3 秒内没等到主窗口。NSApp.windows 共 \(NSApp.windows.count) 个：\(detail.isEmpty ? "（空）" : detail)")
            return
        }

        // 1. 关掉主窗口：应当退成菜单栏模式，Dock 图标消失但进程继续跑。
        window.performClose(nil)
        try? await Task.sleep(nanoseconds: 700_000_000)
        emit("关闭主窗口后 —— \(snapshot())")

        // 2. 从菜单栏入口重新打开：应当重新出现窗口并恢复 Dock 图标。
        WindowCoordinator.shared.showMainWindow()
        try? await Task.sleep(nanoseconds: 700_000_000)
        emit("重新打开后 —— \(snapshot())")
    }

    /// 列出当前所有在阻止休眠的进程。排查时不必打开界面。
    /// 这里用实时查询而不是界面上的缓存，命令行取到的就是此刻的状态。
    @MainActor
    private static func emitBlockers() {
        let blockers = PowerActivityMonitor.currentBlockers()
        guard !blockers.isEmpty else {
            emit("当前没有任何进程在阻止休眠")
            return
        }
        for blocker in blockers {
            let selfMark = blocker.isSelf ? "（本应用）" : ""
            emit("\(blocker.name)\(selfMark)  pid=\(blocker.pid)")
            for assertion in blocker.assertions {
                let scope = assertion.preventsSystemSleep ? "阻止系统睡眠" : "仅阻止屏幕睡眠"
                let reason = assertion.reason.isEmpty ? "" : " — \(assertion.reason)"
                emit("    [\(scope)] \(assertion.type)\(reason)")
            }
        }
    }

    /// 打印更新器脚本供人工检查。只打印，不执行，不落盘。
    @MainActor
    private static func emitUpdateScript() {
        let script = UpdateManager.updaterScript(
            target: Bundle.main.bundleURL.path,
            source: "/tmp/DeepSleepUpdate-示例/extracted/Deep Sleep.app",
            workDirectory: "/tmp/DeepSleepUpdate-示例",
            pid: getpid())
        emit(script)
    }

    /// 列出其他会改电源设置的程序 —— 也就是「谁在跟 Deep Sleep 抢控制权」。
    @MainActor
    private static func emitRivals() {
        PowerActivityMonitor.shared.scan()
        let rivals = PowerActivityMonitor.shared.rivals
        guard !rivals.isEmpty else {
            emit("没有发现其他会修改电源设置的程序")
            return
        }
        for rival in rivals {
            emit("\(rival.name)（\(rival.bundleID)）—— \(rival.note)")
        }
    }

    /// 助手的版本状态。命令行可查，不必为了看一眼版本去翻界面。
    @MainActor
    private static func emitHelperVersion() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        emit("应用版本 \(version)")
        emit("助手版本状态 —— \(HelperVersionManager.shared.state.text)")
    }

    /// 列出检测到的电源设置改动。自身与外部改动都列出，只是分开标记 ——
    /// 用户需要的是完整时间线，而不是只留下「别人的」那部分。
    @MainActor
    private static func emitChanges() {
        let changes = PowerActivityMonitor.shared.changes
        guard !changes.isEmpty else {
            emit("尚未检测到电源设置被改动")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        for change in changes.prefix(20) {
            let source = change.bySelf ? "Deep Sleep" : "外部改动"
            emit("[\(formatter.string(from: change.date))] [\(source)] "
                 + "\(change.key)：\(change.oldValue ?? "（无）") → \(change.newValue)")
        }
    }

    /// 同时写到标准输出与系统日志，两条通路都能取到结果。
    ///
    /// 多行文本逐行加前缀：打印更新器脚本这类多行输出如果只有首行带前缀，
    /// 解析方就只能靠猜来切分正文和日志噪音。
    private static func emit(_ text: String) {
        let payload = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "deepsleep: \($0)\n" }
            .joined()
        FileHandle.standardOutput.write(Data(payload.utf8))
        NSLog("[DeepSleep] %@", text)
    }
}
