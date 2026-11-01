//
//  AutoStartSettings.swift
//  Deep Sleep
//
//  开机自启开关。已并入 ControlView 的「开机自启」段；本文件作为独立
//  View 提供，让监控页与控制页都可以引用同一个开关逻辑。
//
//  界面约定：开关用原生 Toggle；状态与失败原因用「颜色 + 文字」双编码。
//

import SwiftUI

struct AutoStartToggle: View {

    @State private var enabled: Bool = AutoStartManager.isEnabled
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("开机自动启动 Deep Sleep")
                        .font(.body.weight(.medium))
                    Text("写入 ~/Library/LaunchAgents/com.skyc8266.deepsleep.plist；"
                         + "用户主动退出应用后不会被强行唤起（KeepAlive=false）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: enabled) { _, newValue in
                applyChange(newValue)
            }

            if let lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DS.Tone.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            enabled = AutoStartManager.isEnabled
        }
    }

    private func applyChange(_ newValue: Bool) {
        do {
            if newValue {
                try AutoStartManager.enable()
            } else {
                try AutoStartManager.disable()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            enabled = AutoStartManager.isEnabled
        }
    }
}
