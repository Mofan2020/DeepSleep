//
//  MonitoringView.swift
//  Deep Sleep
//
//  系统监控设置页：开关、阈值、自动冻结许可、最近一次状态。
//

import SwiftUI

struct MonitoringView: View {

    @EnvironmentObject private var sleep: SleepController
    @State private var config: MonitorConfig = .default
    @State private var helperStatus: String = "未探测"
    @State private var lastEventDescription: String = "无"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("系统监控") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("启用系统监控", isOn: $config.enabled)
                        .onChange(of: config.enabled) { _, newValue in
                            SystemMonitor.shared.updateConfig(config)
                            if newValue {
                                Task { await probeAndMaybeShowHint() }
                            }
                        }

                    Text("监控每 \(Int(config.sampleIntervalSeconds)) 秒抓一次进程快照；"
                         + "对 RSS 单调增长的进程可能暂时告警内存泄漏；"
                         + "对整体 RAM / CPU 持续超阈则提示冻结或终结 Top 3 占用者。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            GroupBox("阈值") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("RAM 使用率阈值")
                        Spacer()
                        Text("\(Int(config.ramHighPercent))%")
                            .monospacedDigit()
                    }
                    Slider(value: $config.ramHighPercent, in: 50...99)
                    HStack {
                        Text("累计 CPU 阈值")
                        Spacer()
                        Text("\(Int(config.cpuHighPercent))%")
                            .monospacedDigit()
                    }
                    Slider(value: $config.cpuHighPercent, in: 100...1000)
                    Stepper("持续超过 \(config.highDurationSeconds) 秒才告警",
                            value: $config.highDurationSeconds,
                            in: 10...600, step: 10)
                    HStack {
                        Text("采样间隔")
                        Spacer()
                        Text("\(config.sampleIntervalSeconds, specifier: "%.0f") 秒")
                    }
                    Slider(value: $config.sampleIntervalSeconds, in: 1...10, step: 1)
                    Toggle("过载时自动冻结 Top 3", isOn: $config.autoSuspend)
                        .help("必须显式开启；否则只会弹对话框让用户决定")
                    Button("保存设置") {
                        SystemMonitor.shared.updateConfig(config)
                    }
                }
            }

            GroupBox("状态") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("助手协议", value: helperStatus)
                    LabeledContent("最近事件", value: lastEventDescription)
                }
                .font(.system(.body, design: .monospaced))
            }

            Spacer()
        }
        .onAppear {
            SystemNotifier.shared.registerCategories()
            Task { await probeAndMaybeShowHint() }
        }
    }

    private func probeAndMaybeShowHint() async {
        let probe = await HelperClient.shared.probe()
        if !probe.reachable {
            helperStatus = "未安装 / 不可用"
        } else if let v = probe.protocolVersion, v >= 2 {
            helperStatus = "v\(v)（已就绪）"
            ProcessStatsProvider.shared.resetVersionCache()
        } else {
            helperStatus = "v\(probe.protocolVersion ?? 0)（需要更新）"
        }
    }
}