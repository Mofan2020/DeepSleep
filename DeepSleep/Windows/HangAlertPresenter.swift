//
//  HangAlertPresenter.swift
//  Deep Sleep
//
//  「应用无响应」提示面板：从菜单栏下方弹出一张轻量提示卡。
//
//  与 `AlertWindowController` 的区别：
//    - 置顶告警是模态级事件（系统过载、CPU 过热），要抢注意力；
//      这里只是「某个应用卡了，你可以顺手处理一下」，
//      所以**不抢焦点**（nonactivatingPanel）、不盖住整个屏幕。
//    - 视觉沿用既有惯例：borderless + nonactivatingPanel +
//      NSVisualEffectView(.hudWindow) 模糊 + .floating 层级 + canJoinAllSpaces。
//
//  坐标约定：`anchor` 是菜单栏按钮在**屏幕坐标系**里的矩形
//  （`NSWindow.convertToScreen` 的结果）。传 nil 时落在主屏右上角。
//

import AppKit
import SwiftUI

/// 无响应提示面板。
@MainActor
public final class HangAlertPresenter {

    public static let shared = HangAlertPresenter()

    /// 当前显示中的面板。新的提示到来时替换掉旧的。
    private var currentPanel: NSPanel?

    private init() {}

    // MARK: - 公开接口

    /// 弹出一张提示面板。
    ///
    /// - Parameters:
    ///   - event: 要提示的无响应事件。
    ///   - anchor: 菜单栏按钮的位置（屏幕坐标）。nil → 主屏右上角。
    ///   - onIgnore: 用户点「忽略」。
    ///   - onForceQuit: 用户点「强制退出」。
    ///   - onRestart: 用户点「重启」。
    public func present(event: HangEvent,
                        anchor: NSRect?,
                        onIgnore: @escaping () -> Void,
                        onForceQuit: @escaping () -> Void,
                        onRestart: @escaping () -> Void) {
        // 同一时刻只留一张卡片。新的事件比旧的更需要处理。
        dismiss()

        let icon = iconFor(event: event)

        let host = NSHostingController(rootView: HangAlertCard(
            appName: event.appName,
            icon: icon,
            reason: event.reason,
            onIgnore: { [weak self] in
                self?.dismiss()
                onIgnore()
            },
            onForceQuit: { [weak self] in
                self?.dismiss()
                onForceQuit()
            },
            onRestart: { [weak self] in
                self?.dismiss()
                onRestart()
            }
        ))

        let panel = makeWindow(host: host)
        panel.setFrameOrigin(origin(for: anchor, panelSize: panel.frame.size))
        // 不抢焦点：面板出现时用户正在做的事不该被打断。
        panel.orderFront(nil)
        currentPanel = panel
    }

    /// 关掉当前提示面板。
    public func dismiss() {
        currentPanel?.orderOut(nil)
        currentPanel = nil
    }

    // MARK: - 实现

    private func makeWindow(host: NSHostingController<HangAlertCard>) -> NSPanel {
        let panel = HangAlertPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 168),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 浮在别的应用上面，但不把别的应用踢走。
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow

        let container = NSView(frame: panel.contentView!.bounds)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(visualEffect)
        visualEffect.frame = container.bounds
        visualEffect.autoresizingMask = [.width, .height]

        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            host.view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            host.view.widthAnchor.constraint(equalToConstant: 340),
            host.view.heightAnchor.constraint(lessThanOrEqualToConstant: 160)
        ])

        panel.contentView = container
        return panel
    }

    /// 面板落点：菜单栏按钮正下方；没有锚点就主屏右上角。
    private func origin(for anchor: NSRect?, panelSize: NSSize) -> NSPoint {
        let screen = screenFor(anchor: anchor)
        let visible = screen.visibleFrame

        guard let anchor else {
            return NSPoint(
                x: visible.maxX - panelSize.width - 16,
                y: visible.maxY - panelSize.height - 16
            )
        }

        // 菜单栏在屏幕顶端，面板挂在按钮下方 8pt。
        var x = anchor.midX - panelSize.width / 2
        var y = anchor.minY - panelSize.height - 8

        // 别跑到屏幕外面去。
        x = min(max(x, visible.minX + 8), visible.maxX - panelSize.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - panelSize.height - 8)
        return NSPoint(x: x, y: y)
    }

    /// 找到锚点所在的那块屏幕。同时兼容左上角原点的坐标。
    private func screenFor(anchor: NSRect?) -> NSScreen {
        guard let anchor else { return NSScreen.main ?? NSScreen.screens.first! }
        let midpoint = NSPoint(x: anchor.midX, y: anchor.midY)
        for screen in NSScreen.screens where NSPointInRect(midpoint, screen.frame) {
            return screen
        }
        // 锚点用的是左上角原点时，换算成 Cocoa 坐标再试。
        for screen in NSScreen.screens {
            let flipped = NSRect(
                x: anchor.origin.x,
                y: screen.frame.maxY - anchor.maxY,
                width: anchor.width,
                height: anchor.height
            )
            if NSPointInRect(NSPoint(x: flipped.midX, y: flipped.midY), screen.frame) {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens.first!
    }

    /// 取应用图标。取不到就用系统占位图。
    private func iconFor(event: HangEvent) -> NSImage? {
        let url = NSRunningApplication(processIdentifier: event.pid)?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: event.bundleID)
        guard let url else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 40, height: 40)
        return icon
    }
}

// MARK: - 面板子类

/// 无边框面板默认 `canBecomeKey == false`，那样 SwiftUI 的按钮收不到点击。
///
/// 这里把它放开：面板可以成为 key，但带着 `.nonactivatingPanel`，
/// 所以点它**不会**把 Deep Sleep 激活、也不会把用户正在用的应用挤走 ——
/// 这正是「轻量提示」要的行为。
final class HangAlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - SwiftUI 视图

/// 提示卡片本体。
struct HangAlertCard: View {
    let appName: String
    let icon: NSImage?
    let reason: String
    let onIgnore: () -> Void
    let onForceQuit: () -> Void
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Group {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 40, height: 40)
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(appName)
                        .font(.headline)
                        .lineLimit(1)
                    Text("无响应")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }

            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("忽略", action: onIgnore)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("强制退出", action: onForceQuit)
                Button("重启", action: onRestart)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 340)
    }
}
