//
//  MenuBarView.swift
//  Deep Sleep
//
//  菜单栏面板：不打开主窗口也能快速控制。
//

import SwiftUI
import AppKit

struct MenuBarView: View {

    @EnvironmentObject private var controller: SleepController
    @Environment(\.openWindow) private var openWindow

    private var isHolding: Bool { !controller.activeAssertions.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(spacing: 9) {
                Image(systemName: isHolding ? "cup.and.saucer.fill" : "moon.fill")
                    .foregroundStyle(isHolding ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isHolding ? "正在保持清醒" : "允许正常睡眠")
                        .font(.headline)
                    Text("\(controller.activeAssertions.count) 项保持 · 完全控制\(controller.helperState.isReady ? "已启用" : "未启用")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            ForEach(AssertionKind.allCases) { kind in
                Toggle(isOn: Binding(
                    get: { controller.activeAssertions.contains(kind) },
                    set: { newValue in
                        Task { await controller.setAssertion(kind, enabled: newValue) }
                    }
                )) {
                    HStack(spacing: 7) {
                        Image(systemName: kind.symbolName).frame(width: 18)
                        Text(kind.title).font(.callout)
                        if kind.requiresPrivilege {
                            Tag(text: "需授权", color: .orange)
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Divider()

            if let deadline = controller.countdownDeadline {
                HStack(spacing: 7) {
                    Image(systemName: "timer").foregroundStyle(.orange)
                    CountdownLabel(deadline: deadline)
                    Spacer()
                    Button("取消") { controller.cancelCountdown() }
                        .controlSize(.small)
                }
            } else {
                Button {
                    controller.startCountdown(minutes: 30)
                } label: {
                    Label("30 分钟后睡眠", systemImage: "timer")
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("打开主窗口", systemImage: "macwindow")
                }

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("退出", systemImage: "power")
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
    }
}
