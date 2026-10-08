//
//  AlertWindowController.swift
//  Deep Sleep
//
//  系统过载监控 + 内存泄漏检测的置顶对话框。
//
//  设计要点：
//    - 系统过载监控 + 内存泄漏是「必须立刻看到」的事件，
//      浮在所有普通窗口之上；其他窗口的内容用 NSVisualEffectView 模糊，
//      这是 macOS 上标准且最不打扰的实现方式。
//    - 标题与告警文本用 NSColor.systemRed —— 任务要求「红字提醒」。
//    - 不允许拖拽关闭、不允许点关闭按钮 —— 必须按提供的按钮，
//      防止「看到提示但没处理就消失了」。
//
//  与 docs/gotchas 的既有约定一致：菜单栏/置顶窗口不要「抢焦点」，
// 模糊但不阻碍安全窗可见。
//

import AppKit
import SwiftUI

@MainActor
public final class AlertWindowController {

    public static let shared = AlertWindowController()

    private var currentWindow: NSWindow?

    // MARK: - 公开接口

    /// 系统过载对话框。始终显示「冻结 / 结束 / 关闭」三个按钮。
    public func presentOverload(
        event: OverloadEvent,
        onSuspend: @escaping ([pid_t]) -> Void,
        onEnd: @escaping ([pid_t]) -> Void
    ) {
        let pids = event.topThree.map(\.pid)

        let host = NSHostingController(rootView: OverloadAlertView(
            ramPercent: event.ramPercent,
            cpuPercent: event.totalCpuPercent,
            topThree: event.topThree,
            onSuspend: { [weak self] in
                self?.dismiss()
                onSuspend(pids)
            },
            onEnd: { [weak self] in
                self?.dismiss()
                onEnd(pids)
            },
            onClose: { [weak self] in
                self?.dismiss()
            }
        ))
        present(host: host)
    }

    /// 单进程 RSS 超阈值对话框。
    /// - Parameter onSuspend / onEnd: 用户操作按钮后的执行。pids 列表里只会有一个。
    public func presentSingleProcessRAM(
        event: SingleProcessRAMEvent,
        onSuspend: @escaping (pid_t) -> Void,
        onEnd: @escaping (pid_t) -> Void
    ) {
        let pid = event.record.pid

        let host = NSHostingController(rootView: SingleProcessRAMAlertView(
            record: event.record,
            thresholdBytes: event.thresholdBytes,
            onSuspend: { [weak self] in
                self?.dismiss()
                onSuspend(pid)
            },
            onEnd: { [weak self] in
                self?.dismiss()
                onEnd(pid)
            },
            onClose: { [weak self] in
                self?.dismiss()
            }
        ))
        present(host: host)
    }

    /// CPU 温度超阈对话框。只告警,不允许通过它冻结/结束进程
    /// （冻结/结束都不会降温,且系统会自动调频,用户应自行决定处理方式）。
    public func presentCPUTemperature(event: CPUTemperatureEvent) {
        let host = NSHostingController(rootView: CPUTemperatureAlertView(
            maxC: event.maxC,
            averageC: event.averageC,
            aggregateC: event.aggregateC,
            observedMaxC: event.observedMaxC,
            thresholdC: event.thresholdC,
            onClose: { [weak self] in
                self?.dismiss()
            }
        ))
        present(host: host)
    }

    // MARK: - 实现

    private func present(host: NSHostingController<some View>) {
        // 已有对话框就先关掉，避免叠加。
        if let existing = currentWindow {
            existing.orderOut(nil)
            existing.contentViewController = nil
        }

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear

        let containerView = NSView(frame: window.contentView!.bounds)
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        containerView.addSubview(visualEffect)
        visualEffect.frame = containerView.bounds
        visualEffect.autoresizingMask = [.width, .height]

        host.view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            host.view.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            host.view.widthAnchor.constraint(equalToConstant: 480),
            host.view.heightAnchor.constraint(lessThanOrEqualToConstant: 320)
        ])

        window.contentView = containerView

        // 居中
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.midX - window.frame.width / 2
            let y = frame.midY - window.frame.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)
        currentWindow = window
    }

    private func dismiss() {
        currentWindow?.orderOut(nil)
        currentWindow = nil
    }
}

// MARK: - SwiftUI 视图

private struct OverloadAlertView: View {
    let ramPercent: Double
    let cpuPercent: Double
    let topThree: [ProcessStats.Record]
    let onSuspend: () -> Void
    let onEnd: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("系统过载")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.red)
            }

            Text(String(format: "RAM %.0f%% / 累计 CPU %.0f%%", ramPercent, cpuPercent))
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Top 3 占用者：").font(.caption).foregroundColor(.secondary)
                ForEach(topThree, id: \.pid) { record in
                    Text("• \(record.name)  (CPU \(Int(record.cpuPercent))% / RSS \(record.rssBytes / 1_000_000) MB)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.red)
                }
            }

            HStack {
                Button("关闭", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("冻结进程", action: onSuspend)
                Button("结束") { onEnd() }
                    .foregroundColor(.red)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct SingleProcessRAMAlertView: View {
    let record: ProcessStats.Record
    let thresholdBytes: Int
    let onSuspend: () -> Void
    let onEnd: () -> Void
    let onClose: () -> Void

    private var rssGB: Double { Double(record.rssBytes) / 1_073_741_824 }
    private var thresholdGB: Double { Double(thresholdBytes) / 1_073_741_824 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "memorychip.fill")
                    .foregroundColor(.red)
                Text("单进程占用过高")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.red)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("进程：\(record.name)").font(.headline)
                Text(String(format: "当前占用：%.2f GB", rssGB))
                    .font(.body)
                    .foregroundColor(.red)
                Text(String(format: "阈值：%.2f GB", thresholdGB))
                    .font(.caption).foregroundColor(.secondary)
            }

            HStack {
                Button("关闭", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("冻结进程", action: onSuspend)
                Button("结束") { onEnd() }
                    .foregroundColor(.red)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct CPUTemperatureAlertView: View {
    let maxC: Double?
    let averageC: Double?
    let aggregateC: Double?
    let observedMaxC: Double
    let thresholdC: Double
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "thermometer.high")
                    .foregroundColor(.red)
                Text("CPU 温度过高")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.red)
            }

            Text(String(format: "当前最高 %.1f°C，已超过阈值 %.0f°C",
                        observedMaxC, thresholdC))
                .font(.body)
                .foregroundColor(.red)

            VStack(alignment: .leading, spacing: 4) {
                Text("SMC 读数：").font(.caption).foregroundColor(.secondary)
                if let m = maxC {
                    Text(String(format: "• Die Max：%.1f°C", m))
                        .font(.system(.body, design: .monospaced))
                }
                if let a = averageC {
                    Text(String(format: "• Die Average：%.1f°C", a))
                        .font(.system(.body, design: .monospaced))
                }
                if let g = aggregateC {
                    Text(String(format: "• Die Aggregate：%.1f°C", g))
                        .font(.system(.body, design: .monospaced))
                }
            }

            Text("提示：macOS 会自动调频。结束大程序或改善散热即可，"
                 + "Deep Sleep 不会自动杀进程来降温。")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("知道了", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}