//
//  UninstallView.swift
//  Deep Sleep
//
//  卸载 Deep Sleep：二级确认 + 一次性执行 Uninstaller 链路。
//
//  「输入 UNINSTALL 才会启用按钮」的做法用于二次确认关键门槛。
//
//  界面约定：
//    - 卸载是不可逆操作：卡片与按钮都按破坏性操作来表达（危险色 + 文字）。
//    - 先列清楚「会删掉什么」，再要那句确认短语。
//

import SwiftUI

struct UninstallView: View {

    @State private var confirmText: String = ""
    @State private var executing: Bool = false
    @State private var lastReportDescription: String?

    private let requiredPhrase = "UNINSTALL"

    /// 卸载会清掉的东西。顺序与实际清理顺序一致。
    private let cleanupItems: [(title: String, detail: String)] = [
        ("撤销所有 assertion", "含 pmset disablesleep"),
        ("卸载特权助手（Helper）", "/Library 下的文件与 launchd 任务"),
        ("清理应用配置", "Preferences / Caches / Saved State / Logs"),
        ("删除开机自启 LaunchAgent plist", "~/Library/LaunchAgents"),
        ("删除 /Applications/Deep Sleep.app", "本应用本体"),
        ("退出应用", "卸载完成后自动退出")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionCard(
                title: "卸载",
                subtitle: "下面每一步都会真的删掉东西，没有撤销。",
                symbol: "trash",
                accent: DS.Tone.critical
            ) {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    Label("这是不可逆操作。", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(DS.Tone.critical)

                    Text("会执行以下操作：")
                        .font(.body.weight(.medium))

                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        ForEach(cleanupItems, id: \.title) { item in
                            HStack(alignment: .top, spacing: DS.Space.sm) {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DS.Tone.critical)
                                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                    Text(item.title)
                                        .font(.callout)
                                    Text(item.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(DS.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .insetPanel()

                    LabeledContent("输入 UNINSTALL 以确认") {
                        TextField("UNINSTALL", text: $confirmText)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button(role: .destructive) {
                        Task { await execute() }
                    } label: {
                        if executing {
                            ProgressView()
                        } else {
                            Label("立即卸载 Deep Sleep", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Tone.critical)
                    .disabled(confirmText != requiredPhrase || executing)

                    if confirmText != requiredPhrase {
                        Text("确认短语还没输对，按钮保持关闭。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let lastReportDescription {
                        Text(lastReportDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func execute() async {
        executing = true
        defer { executing = false }

        let report = await Uninstaller.shared.execute()
        lastReportDescription = """
            撤销断言：\(report.releasedAssertions ? "✓" : "✗")
            恢复 disablesleep：\(report.disabledSleep ? "✓" : "✗")
            卸载助手：\(report.helperUninstalled ? "✓" : "✗")
            清理配置：\(report.configsCleared ? "✓" : "✗")
            删自启 plist：\(report.autoStartDisabled ? "✓" : "✗")
            删 .app：\(report.appDeleted ? "✓" : "✗")
            """
        if report.appDeleted {
            Uninstaller.shared.quitApplication()
        }
    }
}
