//
//  WindowCoordinator.swift
//  Deep Sleep
//
//  主窗口的显示与 Dock 图标策略。
//
//  三件事在这里汇合，它们互相牵制：
//    1. 关掉所有窗口后隐藏 Dock 图标，应用继续驻留菜单栏后台运行；
//    2. 菜单栏左键要能把主界面叫回来；
//    3. SwiftUI 的 WindowGroup 在窗口关闭后可能连窗口对象一起销毁，
//       那时只能请 SwiftUI 重新创建一个。
//  所以这里同时保存「主窗口弱引用」与「SwiftUI 的 openWindow 动作」，
//  能复用就复用，复用不了就重建。
//

import AppKit
import Combine
import SwiftUI

/// 主窗口的页面路由。
///
/// 菜单栏（AppKit 侧）与主窗口内容（SwiftUI 侧）之间没有直接的引用关系，
/// 所以用这个单例当中转：外部入口「请求切页」，内容视图订阅并应用。
///
/// 为什么要中转而不是直接改 `ContentView` 的 `selection`：
/// `selection` 是 `@State`，只在视图内部可写；而菜单栏在视图之外。
/// 路由把「谁要切到哪一页」这件事独立出来，两边都只跟它打交道。
@MainActor
final class PageRouter: ObservableObject {

    static let shared = PageRouter()

    /// 修订号：每次外部请求 +1。
    ///
    /// 内容视图靠它发现「有新请求了」。不直接用目标页面做触发值，
    /// 是因为连续两次请求同一个页面时目标值没变，订阅方不会被唤醒。
    @Published private(set) var revision = 0

    /// 当前应该显示的页面。
    ///
    /// 外部请求与界面内部换页都会更新它 —— 窗口被销毁重建后，
    /// 新建的内容视图要能回到用户最后看的那一页。
    private(set) var page: SidebarItem = .dashboard

    /// 外部请求切到某个页面。
    func request(_ item: SidebarItem) {
        page = item
        revision &+= 1
    }

    /// 界面内部换页时同步回来。
    func noteLocalNavigation(_ item: SidebarItem) {
        guard item != page else { return }
        page = item
    }
}

@MainActor
final class WindowCoordinator {

    static let shared = WindowCoordinator()

    /// SwiftUI 的 openWindow 动作。它只能从视图环境里取得，
    /// 由 WindowEnvironmentBridge 在视图出现时上报。
    private var openMainWindowAction: (() -> Void)?

    /// 当前主窗口。窗口对象还在时直接前置，比走 openWindow 少一次重建，
    /// 也能保住界面上的选中项与滚动位置。
    private weak var mainWindow: NSWindow?

    /// 当前是否已处于菜单栏模式（无 Dock 图标）。用于避免重复切换。
    private var isAccessory = false

    private init() {}

    // MARK: - 由 SwiftUI 侧上报

    func registerOpenMainWindow(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    func adopt(_ window: NSWindow) {
        mainWindow = window
    }

    // MARK: - 打开主窗口

    /// 菜单栏入口与「访达里再次启动」都走这里。
    func showMainWindow() {
        // 必须先切回常规模式：Dock 图标回来了，窗口才有资格成为 key window。
        // 反过来做的话，accessory 模式下 makeKeyAndOrderFront 不一定生效。
        setAccessory(false)

        if let window = mainWindow, window.windowNumber > 0 {
            window.makeKeyAndOrderFront(nil)
        } else if let action = openMainWindowAction {
            // 窗口对象已被 SwiftUI 销毁，请它重建。
            action()
        } else {
            NSLog("[DeepSleep] 无法打开主窗口：既没有现存窗口，也还没拿到 openWindow 动作")
            return
        }

        NSApp.activate()
    }

    /// 打开主窗口并切到指定页面。
    ///
    /// 菜单栏的「快速跳转」用这个。**先请求切页、再让窗口显示出来** ——
    /// 顺序反了的话窗口会先显示旧页面，然后才跳过去，用户会看到闪一下。
    ///
    /// 窗口被销毁重建时也能对：切页请求记在 `PageRouter` 里，
    /// 新建的内容视图建立时会去读它当前该显示哪一页。
    func showMainWindow(selecting item: SidebarItem) {
        PageRouter.shared.request(item)
        showMainWindow()
    }

    // MARK: - Dock 图标策略

    func observeWindowLifecycle() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            // popover、菜单、工具面板都是 NSPanel，它们开合不代表用户
            // 关掉了应用界面，不该影响 Dock 图标。
            guard !(window is NSPanel) else { return }

            // 关闭通知发出时，这个窗口还在 NSApp.windows 里且 isVisible 仍为 true，
            // 立刻判断会把「最后一个窗口」误算成可见窗口，Dock 图标就永远不隐藏。
            // 所以等这一轮事件处理结束、窗口真正从屏幕上移除后再判断。
            DispatchQueue.main.async {
                WindowCoordinator.shared.updateActivationPolicy()
            }
        }
    }

    /// 没有可见窗口时退成菜单栏模式（隐藏 Dock 图标），有窗口时恢复。
    /// 必须由窗口事件驱动，不能在启动时写死——需求是「关掉所有窗口才隐藏」。
    func updateActivationPolicy() {
        setAccessory(!hasVisiblePrimaryWindow())
    }

    private func hasVisiblePrimaryWindow() -> Bool {
        NSApp.windows.contains { window in
            guard !(window is NSPanel) else { return false }

            // 最小化的窗口仍算「有窗口」：Dock 里还挂着它的缩略图，
            // 此时把 Dock 图标藏掉，用户就再也没法把那个窗口找回来了。
            if window.isMiniaturized { return true }

            // 只要用户界面类型的窗口（带标题栏），排除 SwiftUI 内部建的无边框辅助窗口。
            return window.isVisible && window.styleMask.contains(.titled)
        }
    }

    private func setAccessory(_ enabled: Bool) {
        guard enabled != isAccessory else { return }
        isAccessory = enabled
        NSApp.setActivationPolicy(enabled ? .accessory : .regular)
        NSLog("[DeepSleep] 激活策略切换为 %@",
              enabled ? "accessory（隐藏 Dock 图标，继续后台运行）" : "regular（显示 Dock 图标）")
    }
}

// MARK: - 与 SwiftUI 环境对接

/// 把 SwiftUI 环境里的 openWindow 动作和承载视图的窗口交给 AppKit 侧。
/// 菜单栏是 AppKit 对象，拿不到 SwiftUI 的 environment，只能由视图主动上报。
struct WindowEnvironmentBridge: View {

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        WindowAccessor { window in
            WindowCoordinator.shared.adopt(window)
        }
        .onAppear {
            WindowCoordinator.shared.registerOpenMainWindow { openWindow(id: "main") }
        }
    }
}

/// 反查承载当前视图的 NSWindow。SwiftUI 没有直接暴露它，
/// 只能塞一个临时 NSView 进去再向上问。
private struct WindowAccessor: NSViewRepresentable {

    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // 视图刚构造时还没接入窗口层级，必须等这一轮 runloop 结束再问。
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
