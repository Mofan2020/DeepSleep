//
//  UninstallView.swift
//  Deep Sleep
//
//  卸载 Deep Sleep：二级确认 + 一次性执行 Uninstaller 链路。
//
//  「输入 UNINSTALL 才会启用按钮」的做法用于二次确认关键门槛。
//

import SwiftUI

struct UninstallView: View {

    @State private var confirmText: String = ""
    @State private var executing: Bool = false
    @State private var lastReportDescription: String?

    private let requiredPhrase = "UNINSTALL"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("卸载") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("会执行以下操作：")
                        .font(.body)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("• 撤销所有 assertion（含 pmset disablesleep）")
                        Text("• 卸载特权助手（Helper）")
                        Text("• 清理应用配置（Preferences / Caches / Saved State / Logs）")
                        Text("• 删除开机自启 LaunchAgent plist")
                        Text("• 删除 /Applications/Deep Sleep.app")
                        Text("• 退出应用")
                    }
                    .foregroundColor(.secondary)
                    .font(.caption)

                    Text("输入 UNINSTALL 以确认")
                        .font(.caption)
                    TextField("UNINSTALL", text: $confirmText)
                        .textFieldStyle(.roundedBorder)

                    Button(role: .destructive) {
                        Task { await execute() }
                    } label: {
                        if executing {
                            ProgressView()
                        } else {
                            Text("立即卸载 Deep Sleep")
                        }
                    }
                    .disabled(confirmText != requiredPhrase || executing)

                    if let lastReportDescription {
                        Text(lastReportDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
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