//
//  MenuBarController.swift
//  Deep Sleep
//
//  菜单栏入口：左键打开主界面，右键弹出快速设置。
//
//  这里用 AppKit 的 NSStatusItem 而不是 SwiftUI 的 MenuBarExtra：
//  MenuBarExtra 的点击一律弹出它自己的面板，无法区分左右键，
//  而需求明确要求左键打开应用、右键做设置。
//

import AppKit

@MainActor
final class MenuBarController: NSObject {

    /// 当前实例。NSStatusBar 不提供查询接口，留一个弱引用，
    /// 好让自检能确认菜单栏入口真的建起来了，而不是只在代码里「应该」建了。
    private(set) static weak var current: MenuBarController?

    private let statusItem: NSStatusItem
    private let controller: SleepController

    init(controller: SleepController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureButton()
        Self.current = self
    }

    // MARK: - 状态栏按钮

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "moon.zzz.fill",
                               accessibilityDescription: "Deep Sleep")
        // 模板图会跟着菜单栏明暗主题自动反色。
        button.image?.isTemplate = true
        button.toolTip = "Deep Sleep"
        // 默认只有左键抬起会发出动作，右键会被丢掉；显式声明两种都要。
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        button.action = #selector(handleClick)
    }

    /// 判断一次点击是否属于「次要点击」：右键，或 Control + 左键
    /// （触控板与鼠标的通用习惯）。
    /// 抽成静态纯函数是为了让自检能直接验证两种按键的判定，
    /// 而不必真的去合成系统事件。
    static func isSecondaryClick(eventType: NSEvent.EventType?,
                                 modifiers: NSEvent.ModifierFlags) -> Bool {
        eventType == .rightMouseUp || modifiers.contains(.control)
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let secondary = Self.isSecondaryClick(eventType: event?.type,
                                              modifiers: event?.modifierFlags ?? [])
        if secondary {
            presentMenu()
        } else {
            WindowCoordinator.shared.showMainWindow()
        }
    }

    // MARK: - 右键快速设置

    private func presentMenu() {
        guard let button = statusItem.button else { return }
        // 用 popUp 而不是「设 statusItem.menu 再 performClick」：
        // 后者会把菜单挂到状态项上，收起时必须记得摘掉，否则下次左键也会弹菜单。
        makeMenu().popUp(positioning: nil,
                         at: NSPoint(x: 0, y: button.bounds.height + 4),
                         in: button)
    }

    /// 构建右键菜单。抽成独立方法有两个理由：一是每次弹出都重建，
    /// 菜单里的开关状态永远是当下的真实状态，不必额外订阅 controller 做同步；
    /// 二是自检能在不弹出菜单的前提下校验内容——弹出是模态的，
    /// 自动化测试会卡死在里面。
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let summary = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        menu.addItem(.separator())
        for (index, kind) in AssertionKind.allCases.enumerated() {
            menu.addItem(assertionItem(for: kind, tag: index))
        }

        menu.addItem(.separator())
        menu.addItem(countdownItem())

        menu.addItem(.separator())
        menu.addItem(makeItem(title: "打开 Deep Sleep…", action: #selector(openMainWindow)))
        menu.addItem(makeItem(title: "退出 Deep Sleep", action: #selector(quit), keyEquivalent: "q"))

        return menu
    }

    private var statusText: String {
        let count = controller.activeAssertions.count
        if count == 0 { return "允许正常睡眠" }
        if controller.sleepDisabled { return "已完全禁止睡眠（含合盖）" }
        return "正在保持清醒 · \(count) 项"
    }

    private func assertionItem(for kind: AssertionKind, tag: Int) -> NSMenuItem {
        var title = kind.title
        // 需要 root 权限的类型在没装助手时点了会静默失败，先在标题里讲明白。
        if kind.requiresPrivilege && !controller.helperState.isReady {
            title += "（需先启用完全控制）"
        }
        let item = NSMenuItem(title: title,
                              action: #selector(toggleAssertion(_:)),
                              keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.state = controller.activeAssertions.contains(kind) ? .on : .off
        return item
    }

    private func countdownItem() -> NSMenuItem {
        if controller.countdownDeadline != nil {
            return makeItem(title: "取消倒计时", action: #selector(cancelCountdown))
        }
        return makeItem(title: "30 分钟后睡眠", action: #selector(startCountdown))
    }

    private func makeItem(title: String,
                          action: Selector,
                          keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    // MARK: - 菜单动作

    @objc private func toggleAssertion(_ sender: NSMenuItem) {
        let kinds = AssertionKind.allCases
        guard sender.tag >= 0, sender.tag < kinds.count else { return }
        let kind = kinds[sender.tag]
        // 菜单项状态是弹出那一刻的快照，这里按「切换」语义取反即可。
        let enable = !controller.activeAssertions.contains(kind)
        Task { await controller.setAssertion(kind, enabled: enable) }
    }

    @objc private func startCountdown() {
        controller.startCountdown(minutes: 30)
    }

    @objc private func cancelCountdown() {
        controller.cancelCountdown()
    }

    @objc private func openMainWindow() {
        WindowCoordinator.shared.showMainWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
