//
//  MonitoringView.swift
//  Deep Sleep
//
//  系统监控设置页：开关、阈值、自动冻结许可、最近一次状态。
//
//  v1.4.1 修：config 之前是 @State 默认值，切页或重启都丢，
//  「保存设置」按钮没用。改用 MonitorConfig.load() 在 onAppear 读，
//  onChange 写。任何字段变化立即落盘，不再依赖「保存设置」按钮。
//

import SwiftUI

struct MonitoringView: View {

    @EnvironmentObject private var sleep: SleepController
    @State private var config: MonitorConfig = .default
    @State private var helperStatus: String = "未探测"
    @State private var lastEventDescription: String = "无"
    @State private var lastEventAt: Date?
    @State private var refreshTick: Int = 0   // 每秒自增，让最近事件 UI 自动重抓

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("系统监控") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("启用系统监控", isOn: $config.enabled)
                        .onChange(of: config) { _, newConfig in
                            newConfig.saveIfNotDefault()
                            SystemMonitor.shared.updateConfig(newConfig)
                            if newConfig.enabled {
                                SystemMonitor.shared.start()
                                Task { await probeAndMaybeShowHint() }
                            }
                        }

                    Text("监控每 \(Int(config.sampleIntervalSeconds)) 秒抓一次进程快照；"
                         + "对整体 RAM / CPU 持续超阈则提示冻结或终结 Top 3 占用者；"
                         + "对单进程 RAM 超过阈值则立刻提示。")
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
                    Slider(value: $config.cpuHighPercent, in: 0...100)
                    Stepper("持续超过 \(config.highDurationSeconds) 秒才告警",
                            value: $config.highDurationSeconds,
                            in: 10...600, step: 10)
                    HStack {
                        Text("采样间隔")
                        Spacer()
                        Text("\(config.sampleIntervalSeconds, specifier: "%.0f") 秒")
                    }
                    Slider(value: $config.sampleIntervalSeconds, in: 1...10, step: 1)
                    Stepper(value: Binding(
                        get: { Double(config.singleProcessRAMBytes) / 1_073_741_824 },
                        set: { config.singleProcessRAMBytes = Int($0 * 1_073_741_824) }
                    ), in: 0.5...32, step: 0.5) {
                        Text(String(format: "单进程 RAM 上限 %.2f GB（任一进程达到即立刻告警）",
                                      Double(config.singleProcessRAMBytes) / 1_073_741_824))
                    }
                    Toggle("过载时自动冻结 Top 3", isOn: $config.autoSuspend)
                        .help("必须显式开启；否则只会弹对话框让用户决定")
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
            config = MonitorConfig.load()
            SystemMonitor.shared.updateConfig(config)
            refreshLastEvent()
            Task { await probeAndMaybeShowHint() }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refreshTick += 1
            refreshLastEvent()
        }
    }

    private func refreshLastEvent() {
        if let pair = SystemMonitor.shared.lastEventDescription() {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            lastEventDescription = "\(pair.description) @ \(formatter.string(from: pair.date))"
        } else {
            lastEventDescription = "无"
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