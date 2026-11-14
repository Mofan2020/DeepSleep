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
//  三条约定贯穿整个文件：
//  1. 菜单**每次弹出都重建**，所以菜单里的状态永远是当下的真实值，
//     不必额外订阅 controller 做同步。
//  2. 状态一律「颜色 + 文字」双编码，颜色只表达语义
//     （好=保持清醒、注意=已禁用睡眠、中性=允许睡眠）。
//  3. 菜单栏图标也跟着状态走：月亮=允许睡眠、杯子=保持清醒、
//     八边形=已禁止睡眠。图标用模板图，系统按明暗主题自动反色，
//     所以语义由**形状**承担，颜色留给菜单里的状态点。
//

import AppKit
import Combine
import SwiftUI   // 只为把 DS.Tone 的语义色转成 NSColor

@MainActor
final class MenuBarController: NSObject {

    /// 当前实例。NSStatusBar 不提供查询接口，留一个弱引用，
    /// 好让自检能确认菜单栏入口真的建起来了，而不是只在代码里「应该」建了。
    private(set) static weak var current: MenuBarController?

    private let statusItem: NSStatusItem
    private let controller: SleepController

    /// 状态变化时用来刷新菜单栏图标。图标要跟着状态走，
    /// 不能只在初始化时定一次 —— 断言可能被别处改掉。
    private var cancellables = Set<AnyCancellable>()

    /// 切页回调。菜单栏只负责「用户点了哪个页面」，
    /// 具体怎么切交给 WindowCoordinator —— 它知道主窗口与路由通道。
    private let selectPage: (SidebarItem) -> Void

    /// 最近事件的时间戳格式化器。复用同一个实例，
    /// 每次弹菜单都新建 DateFormatter 太浪费。
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(controller: SleepController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.selectPage = { item in
            WindowCoordinator.shared.showMainWindow(selecting: item)
        }
        super.init()
        configureButton()
        observeStateChanges()
        Self.current = self
        // 音频管理是可选的第二个状态栏位置，默认关。它的显隐跟着设置走，
        // 不占位置时菜单栏里什么都不多。
        AudioStatusMenuController.shared.activate()
    }

    // MARK: - 状态栏按钮

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // 图标在 refreshStatusItem() 里按状态设置。
        // 默认只有左键抬起会发出动作，右键会被丢掉；显式声明两种都要。
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        button.action = #selector(handleClick)
        refreshStatusItem()
    }

    /// 刷新菜单栏图标与提示。
    ///
    /// 图标按状态换：允许睡眠=月亮，保持清醒=杯子，已禁止睡眠=警告。
    /// 全部用模板图，系统按明暗主题自动反色 —— 上色会被反色吃掉，
    /// 所以语义由形状承担，提示文字再说一遍。
    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let status = currentStatus()
        let image = NSImage(systemSymbolName: Self.statusSymbolName(for: status),
                            accessibilityDescription: status.text)
        // 模板图会跟着菜单栏明暗主题自动反色。
        image?.isTemplate = true
        button.image = image
        // 提示里带上文字状态：图标只有一个形状，文字才说清到底怎么了。
        button.toolTip = "Deep Sleep · \(status.text)"
    }

    /// 状态变化时刷新图标。
    ///
    /// 用 objectWillChange 而不是逐个属性的 publisher：菜单栏只关心
    /// 「状态有没有变」，不关心是哪个属性变的。
    ///
    /// objectWillChange 在赋值**之前**发出，所以刷新要推到赋值之后，
    /// 否则读到的是旧值。这里用 Task 跳到下一轮主线程。
    private func observeStateChanges() {
        controller.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshStatusItem() }
            }
            .store(in: &cancellables)

        ServerModeController.shared.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshStatusItem() }
            }
            .store(in: &cancellables)
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

        // 1. 状态摘要（颜色圆点 + 文字）
        menu.addItem(statusSummaryItem())

        // 2. 「保持清醒」相关的开关：服务器模式 + 四个断言
        menu.addItem(.separator())
        menu.addItem(serverModeItem())
        for (index, kind) in AssertionKind.allCases.enumerated() {
            menu.addItem(assertionItem(for: kind, tag: index))
        }

        // 3. 音频管理：开着才在菜单栏占位置
        menu.addItem(.separator())
        menu.addItem(audioManagementItem())

        // 4. 倒计时
        menu.addItem(.separator())
        menu.addItem(countdownItem())

        // 5. 快速跳转：高频页面不必先开窗口再点侧边栏
        menu.addItem(.separator())
        menu.addItem(jumpItem(to: .dashboard))
        menu.addItem(jumpItem(to: .systemMonitor))
        menu.addItem(jumpItem(to: .wakeOnLAN))
        menu.addItem(jumpItem(to: .audioControl))

        // 6. 最近事件
        menu.addItem(.separator())
        menu.addItem(recentEventItem())

        // 7. 一次性动作
        menu.addItem(.separator())
        menu.addItem(quickQuitItem())

        // 8. 窗口与退出
        menu.addItem(.separator())
        menu.addItem(makeItem(title: "打开 Deep Sleep…", action: #selector(openMainWindow)))
        menu.addItem(makeItem(title: "退出 Deep Sleep", action: #selector(quit), keyEquivalent: "q"))

        return menu
    }

    // MARK: - 状态摘要行

    /// 菜单里要表达的三种状态。
    ///
    /// 颜色与文字一起给 —— 颜色只表达语义，不单独承载信息。
    private enum MenuStatus {
        /// 允许正常睡眠
        case sleeping
        /// 正在保持清醒
        case awake(count: Int)
        /// 睡眠被完全禁止（含合盖）
        case sleepDisabled

        var text: String {
            switch self {
            case .sleeping:      return "允许正常睡眠"
            case .awake(let n):  return "正在保持清醒 · \(n) 项"
            case .sleepDisabled: return "已完全禁止睡眠（含合盖）"
            }
        }

        /// 状态圆点的颜色。好=绿、注意=橙、中性=灰。
        ///
        /// 中性色用 AppKit 的 secondaryLabelColor，而不是 DS.Tone.idle：
        /// 后者是 SwiftUI 的 Color.secondary，转成 NSColor 后在明暗两种
        /// 菜单主题下不一定是对比度合适的灰。
        var color: NSColor {
            switch self {
            case .sleeping:      return .secondaryLabelColor
            case .awake:         return NSColor(DS.Tone.good)
            case .sleepDisabled: return NSColor(DS.Tone.caution)
            }
        }
    }

    /// 当前状态。睡眠禁用优先于保持清醒 —— 那是更严重的状态。
    private func currentStatus() -> MenuStatus {
        if controller.sleepDisabled { return .sleepDisabled }
        let count = controller.activeAssertions.count
        if count == 0 { return .sleeping }
        return .awake(count: count)
    }

    /// 状态对应的菜单栏图标。形状承担语义，颜色交给系统反色。
    private static func statusSymbolName(for status: MenuStatus) -> String {
        switch status {
        case .sleeping:      return "moon.zzz.fill"
        case .awake:         return "cup.and.saucer.fill"
        case .sleepDisabled: return "exclamationmark.octagon.fill"
        }
    }

    /// 状态摘要行：一个颜色圆点 + 一行状态文字。
    ///
    /// 圆点用 image 而不是把符号写进标题：AppKit 会给菜单里的所有图标
    /// 留出同一列，文字因此自动对齐；而写在标题里的符号会跟着标题
    /// 一起被禁用态压暗，颜色语义就没了。
    private func statusSummaryItem() -> NSMenuItem {
        let status = currentStatus()
        let item = NSMenuItem(title: status.text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = Self.dotImage(color: status.color, description: status.text)
        showImageAlways(item)
        return item
    }

    /// 画一个状态圆点。
    ///
    /// 不用 SF Symbol 的 circle.fill：模板图会被系统按菜单主题统一染色，
    /// 绿色和橙色会变成同一个颜色，语义就没了。这里自己画，颜色是确定的。
    private static func dotImage(color: NSColor, description: String) -> NSImage {
        let size = NSSize(width: 9, height: 9)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "状态：\(description)"
        return image
    }

    // MARK: - 服务器模式

    /// 服务器模式开关。
    ///
    /// 状态直接读 `ServerModeController.shared.phase`：它是唯一真源
    /// （off / starting / waitingForIdle / locked）。
    /// 菜单每次弹出都重建，所以这里读到的一定是当下状态。
    private func serverModeItem() -> NSMenuItem {
        let phase = ServerModeController.shared.phase
        var title = "服务器模式"
        switch phase {
        case .off:
            // 服务器模式要靠助手发命令，助手没就位时点了必然失败，
            // 先在标题里讲明白（与断言项同一套说法）。
            if !controller.helperState.isReady {
                title += "（需先启用完全控制）"
            }
        case .starting:       title += "（启动中）"
        case .waitingForIdle: title += "（空闲倒计时中）"
        case .locked:         title += "（已熄屏锁定）"
        }

        let item = makeItem(title: title, action: #selector(toggleServerMode))
        item.state = phase == .off ? .off : .on
        item.image = Self.symbolImage("powersleep")
        showImageAlways(item)
        return item
    }

    @objc private func toggleServerMode() {
        let enable = ServerModeController.shared.phase == .off
        Task { @MainActor in
            // 状态机入口：ServerModeController.setEnabled(_:controller:)。
            await ServerModeController.shared.setEnabled(enable, controller: controller)
            if !enable {
                // 关闭服务器模式时把 disablesleep 交回系统 ——
                // 与主界面「服务器模式」开关的行为保持一致。
                // 按副作用记：这不是用户去按了「完全禁止系统睡眠」。
                await controller.setSleepDisabled(false, source: .derived)
            }
        }
    }

    // MARK: - 音频管理

    /// 音频管理的总开关。打开后菜单栏多一个喇叭图标，
    /// 从那里能直接调每个正在出声的 app 的音量；关掉就收回去。
    private func audioManagementItem() -> NSMenuItem {
        let manager = AudioControlManager.shared
        let item = makeItem(title: "音频管理", action: #selector(toggleAudioManagement))
        item.state = manager.isMenuBarEnabled ? .on : .off
        item.image = Self.symbolImage("speaker.wave.2")
        showImageAlways(item)
        return item
    }

    @objc private func toggleAudioManagement() {
        let manager = AudioControlManager.shared
        manager.setMenuBarEnabled(!manager.isMenuBarEnabled)
    }

    // MARK: - 断言开关

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

    // MARK: - 倒计时

    private func countdownItem() -> NSMenuItem {
        if controller.countdownDeadline != nil {
            return makeItem(title: "取消倒计时", action: #selector(cancelCountdown))
        }
        return makeItem(title: "30 分钟后睡眠", action: #selector(startCountdown))
    }

    // MARK: - 快速跳转

    /// 快速跳转到某个页面。
    ///
    /// 高频页面（总览 / 系统监控 / 网络唤醒）直接从菜单栏进，
    /// 省掉「开窗口 → 点侧边栏」这两步。
    /// 图标沿用侧边栏同一套 symbol，两处长得一样才认得出是同一个页面。
    private func jumpItem(to item: SidebarItem) -> NSMenuItem {
        let menuItem = makeItem(title: item.title, action: #selector(jumpToPage(_:)))
        // 用 representedObject 带上目标页面，避免再维护一份 tag 映射表。
        menuItem.representedObject = item
        menuItem.image = Self.symbolImage(item.symbol)
        showImageAlways(menuItem)
        return menuItem
    }

    @objc private func jumpToPage(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem else { return }
        selectPage(item)
    }

    // MARK: - 最近事件

    /// 最近一条运行日志。不可点的说明行，只给用户看。
    private func recentEventItem() -> NSMenuItem {
        let item = NSMenuItem(title: "最近事件", action: nil, keyEquivalent: "")
        item.isEnabled = false
        guard let entry = controller.log.last else {
            item.title = "最近事件：暂无记录"
            return item
        }
        // 日志可能很长，截断一下，免得菜单被一条日志撑开。
        let text = entry.text.count > 40 ? String(entry.text.prefix(40)) + "…" : entry.text
        let stamp = timeFormatter.string(from: entry.date)
        item.title = "最近事件：\(stamp) · \(text)"
        return item
    }

    // MARK: - 一次性动作

    /// 快速退出的菜单入口。
    ///
    /// 标题里带上快捷键与名单数量：菜单每次弹出都重建，读到的永远是当下状态，
    /// 用户也就不会对着一个「按了没反应」的快捷键发懵。
    private func quickQuitItem() -> NSMenuItem {
        let engine = QuickQuitEngine.shared
        var title = "强制退出选定的应用"
        if engine.targets.isEmpty {
            title += "（名单为空）"
        } else {
            title += "（\(engine.targets.count) 个）"
        }
        if engine.isHotkeyLive {
            title += "　\(engine.hotkey.displayText)"
        }
        return makeItem(title: title, action: #selector(quickQuit))
    }

    private func makeItem(title: String,
                          action: Selector,
                          keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    /// SF Symbol 图标，统一按模板图处理（系统按明暗主题反色）。
    private static func symbolImage(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image ?? NSImage()
    }

    /// macOS 27 起 AppKit 会自行决定菜单项图标是否显示（通常隐藏）。
    /// 这些图标是我们特意加的状态标识，所以显式要求「始终可见」。
    ///
    /// **为什么用 KVC 而不是 `item.preferredImageVisibility = .visible`**：
    /// 那个属性只在 macOS 27 SDK 里存在。CI 用的是 Xcode 26.6（SDK 26.5），
    /// 直接写会编译失败 —— `#available` 只保护**运行时**，不保护**编译期符号
    /// 是否存在**。SDK 里没有这个符号，`#available(macOS 27.0, *)` 包着也照样
    /// 报 "value of type 'NSMenuItem' has no member 'preferredImageVisibility'"。
    ///
    /// `NSMenuItemImageVisibilityVisible` 的 rawValue 是 1
    /// （Automatic=0 / Visible=1 / Hidden=2，查 MacOSX27.2.sdk 的 NSMenuItem.h）。
    private func showImageAlways(_ item: NSMenuItem) {
        // 26 上没这个 setter，KVC 直接写会抛 NSUnknownKeyException。
        guard item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) else {
            // macOS 26 及更早：设了 image 就会显示，不用额外处理。
            return
        }
        item.setValue(1, forKey: "preferredImageVisibility")
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

    @objc private func quickQuit() {
        Task { await QuickQuitEngine.shared.run(dryRun: false, trigger: "菜单栏") }
    }

    @objc private func openMainWindow() {
        WindowCoordinator.shared.showMainWindow()
    }

    // MARK: - 未响应应用提示

    /// 菜单栏按钮在屏幕坐标系里的位置。
    ///
    /// 未响应应用的提示面板要贴在按钮下方，所以需要真实坐标。
    /// 取不到时返回 nil —— 面板会退到主屏右上角，不能因为取不到坐标就不提示。
    var statusButtonFrameInScreen: NSRect? {
        guard let button = statusItem.button else { return nil }
        return button.window?.convertToScreen(button.frame)
    }

    /// 把检测到的未响应应用交给提示面板。
    ///
    /// 三个按钮的行为都交给检测器自己执行，这里只负责呈现与定位。
    func presentHangAlert(_ event: HangEvent) {
        HangAlertPresenter.shared.present(
            event: event,
            anchor: statusButtonFrameInScreen,
            onIgnore: { HangDetector.shared.ignore(event: event) },
            onForceQuit: { HangDetector.shared.forceQuit(event: event) },
            onRestart: { HangDetector.shared.restart(event: event) }
        )
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 音频管理的菜单栏位置

/// 逐应用音量的第二个状态栏入口。
///
/// 为什么单独占一格而不是塞进上面的右键菜单：这个功能是可选的，开着时
/// 用户要的是「抬手就能调」，不该先记住「右键那个月亮图标」；关掉时也
/// 不该在菜单栏留任何东西。所以它的存在由设置里的开关决定。
///
/// 菜单每次弹出都重建：里面列的是「此刻正在出声的 app」，
/// 两分钟前那份没有意义。
@MainActor
final class AudioStatusMenuController: NSObject {

    static let shared = AudioStatusMenuController()

    /// 自检用：确认状态项真的建起来了（NSStatusBar 没有查询接口）。
    private(set) static weak var current: AudioStatusMenuController?

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let manager = AudioControlManager.shared
    private var iconCache: [String: NSImage] = [:]

    /// 开始跟随设置。菜单栏入口建起来时调一次。
    func activate() {
        guard Self.current == nil else { return }
        Self.current = self

        manager.$isMenuBarEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.syncStatusItem(visible: enabled) }
            .store(in: &cancellables)

        manager.$permission
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshStatusButton() }
            .store(in: &cancellables)

        syncStatusItem(visible: manager.isMenuBarEnabled)
    }

    // MARK: - 状态栏按钮

    private func syncStatusItem(visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.target = self
            item.button?.action = #selector(handleClick)
            statusItem = item
            refreshStatusButton()
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func refreshStatusButton() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "音频管理")
        image?.isTemplate = true
        button.image = image
        button.toolTip = manager.permission.isDenied
            ? "Deep Sleep · 音频管理（需要系统音频录制授权）"
            : "Deep Sleep · 音频管理"
    }

    @objc private func handleClick() {
        guard let button = statusItem?.button else { return }
        // 和主菜单同一个理由：popUp 不把菜单挂到状态项上，
        // 收起时不必记得摘掉。
        makeMenu().popUp(positioning: nil,
                         at: NSPoint(x: 0, y: button.bounds.height + 4),
                         in: button)
    }

    // MARK: - 菜单

    /// 抽出成独立方法：自检要能在不弹出菜单的前提下校验内容
    /// （弹出是模态的，自动化会卡死在里面）。
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 菜单栏开着、但功能在页面上被关掉了：这里要说清楚，并给一个能直接开回来的入口。
        if !manager.isEnabled {
            menu.addItem(infoItem(title: "音频管理已关闭"))
            menu.addItem(actionItem(title: "开启音频管理", action: #selector(enableAudioManagement)))
            menu.addItem(.separator())
            menu.addItem(actionItem(title: "打开音频控制…", action: #selector(openAudioPage)))
            return menu
        }

        if manager.permission.isDenied {
            menu.addItem(infoItem(title: "需要授权：系统音频录制"))
            menu.addItem(actionItem(title: "去系统设置授权", action: #selector(openAudioCaptureSettings)))
            menu.addItem(.separator())
        }

        let apps = AudioControlSupport.menuBarApps(manager.controlledApps)
        if apps.isEmpty {
            menu.addItem(infoItem(title: "没有正在出声的应用"))
        } else {
            for app in apps {
                menu.addItem(appItem(for: app))
            }
        }

        menu.addItem(.separator())
        menu.addItem(actionItem(title: "打开音频控制…", action: #selector(openAudioPage)))
        menu.addItem(actionItem(title: "关闭音频管理", action: #selector(disableAudioManagement)))

        return menu
    }

    private func infoItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// 一行 = 应用名 + 音量滑杆 + 静音。
    ///
    /// 用 NSMenuItem.view 而不是「点了弹窗」：菜单本来就是一路点下来的，
    /// 拖滑杆时菜单该留在原地。
    private func appItem(for app: AudioControlledApp) -> NSMenuItem {
        let item = NSMenuItem(title: app.displayName, action: nil, keyEquivalent: "")
        let row = AudioMenuRowView(app: app, icon: icon(for: app.bundleID))

        row.onVolumeChange = { [weak self] volume in
            self?.manager.setVolume(volume, for: app)
        }
        row.onToggleMute = { [weak self, weak row] in
            guard let self else { return }
            self.manager.toggleMute(forKey: app.uniqueKey)
            let current = self.manager.controlledApps.first { $0.uniqueKey == app.uniqueKey }?.volume
                ?? app.volume
            row?.apply(volume: current)
        }

        item.view = row
        return item
    }

    private func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        iconCache[bundleID] = image
        return image
    }

    // MARK: - 动作

    @objc private func openAudioCaptureSettings() {
        manager.openPermissionSettings()
    }

    @objc private func openAudioPage() {
        WindowCoordinator.shared.showMainWindow(selecting: .audioControl)
    }

    @objc private func enableAudioManagement() {
        manager.isEnabled = true
    }

    @objc private func disableAudioManagement() {
        manager.setMenuBarEnabled(false)
        manager.isEnabled = false
    }
}

// MARK: - 音频菜单里的一行

/// 菜单项里的自定义视图。用 frame 布局而不是自动布局：
/// NSMenu 只看 view 的 frame，autolayout 在这里量不出尺寸。
final class AudioMenuRowView: NSView {

    static let rowWidth: CGFloat = 320
    static let rowHeight: CGFloat = 50

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let muteButton = NSButton(frame: .zero)

    /// 回调里的音量是 0...1。
    var onVolumeChange: ((Double) -> Void)?
    var onToggleMute: (() -> Void)?

    private var volume: Double

    init(app: AudioControlledApp, icon: NSImage?) {
        self.volume = app.volume
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        nameLabel.stringValue = app.displayName
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right
        addSubview(percentLabel)

        slider.isContinuous = true
        slider.controlSize = .small
        slider.minValue = 0
        slider.maxValue = 100
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.toolTip = "「\(app.displayName)」的音量"
        addSubview(slider)

        muteButton.isBordered = false
        muteButton.bezelStyle = .inline
        muteButton.imagePosition = .imageOnly
        muteButton.target = self
        muteButton.action = #selector(muteTapped)
        addSubview(muteButton)

        apply(volume: app.volume)
        // 菜单项视图不会拿到一次自动的布局 pass，子视图得自己摆一次，
        // 否则整行空白。
        layout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.rowWidth, height: Self.rowHeight)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height

        iconView.frame = NSRect(x: 14, y: height - 26, width: 16, height: 16)
        nameLabel.frame = NSRect(x: 36, y: height - 27, width: max(0, width - 36 - 62), height: 18)
        percentLabel.frame = NSRect(x: width - 62, y: height - 27, width: 44, height: 18)
        slider.frame = NSRect(x: 14, y: 7, width: max(0, width - 14 - 62), height: 19)
        muteButton.frame = NSRect(x: width - 42, y: 4, width: 24, height: 24)
    }

    /// 外部（静音按钮、刷新）改了音量之后同步显示。
    func apply(volume: Double) {
        let clamped = AudioControlSupport.clampVolume(volume)
        self.volume = clamped
        slider.doubleValue = clamped * 100
        percentLabel.stringValue = AudioControlSupport.formatPercent(clamped)
        updateMuteImage(isMuted: clamped <= 0.001)
    }

    private func updateMuteImage(isMuted: Bool) {
        let symbol = isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: isMuted ? "取消静音" : "静音")
        image?.isTemplate = true
        muteButton.image = image
        muteButton.toolTip = isMuted ? "取消静音「\(nameLabel.stringValue)」" : "静音「\(nameLabel.stringValue)」"
    }

    @objc private func sliderChanged() {
        let value = AudioControlSupport.clampVolume(slider.doubleValue / 100)
        volume = value
        // 拖动过程中就生效：松手才改的话，用户听不出哪一档是对的。
        onVolumeChange?(value)
        percentLabel.stringValue = AudioControlSupport.formatPercent(value)
        updateMuteImage(isMuted: value <= 0.001)
    }

    @objc private func muteTapped() {
        onToggleMute?()
    }
}
