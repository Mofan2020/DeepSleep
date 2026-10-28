//
//  ContentView.swift
//  Deep Sleep
//
//  主窗口：侧边栏导航 + 详情页。
//

import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard
    case control
    case power
    case automation
    case schedule
    /// 快速退出：一键结束选定应用及其子进程。
    case quickQuit
    /// 外部活动：谁在阻止休眠、谁在改电源设置。
    case external
    case log
    /// 更新：应用自身与特权助手的版本维护。
    case update
    /// 系统监控：CPU/RAM 过载检测 + 内存泄漏告警。
    case systemMonitor
    /// 温度监控：各传感器实时温度 + 90°C 安全兜底状态。
    case thermal
    /// 风扇控制：手动固定转速 / 交回系统 / 按规则调速。
    case fan
    /// 告警规则：用户自定义的告警条件与动作。
    case alertRules
    /// 卸载 Deep Sleep：二级确认 + 全流程清理。
    case uninstall
    /// 服务器模式：永不睡眠 + 定时关屏锁屏。
    case serverMode
    /// 进程优先级（nice）：查看 / 调整任何非系统进程的 nice。
    case nice
    /// Hosts 编辑：读写 /etc/hosts + 管理「谁能改 hosts」白名单。
    case hosts
    /// Quarantine 属性管理：扫描并清除 macOS 的 quarantine 扩展属性。
    case quarantine
    /// 工具箱：nice / hosts / quarantine / AI 保活 的卡片网格。
    ///
    /// 这几个 case 保留在枚举里，但**不从侧边栏渲染** —— 侧边栏「工具」段
    /// 只渲染工具箱一项。工具箱页点卡片时切 selection 到对应 case。
    case toolbox
    /// AI 保活：按计划给指定接口发一次请求。
    case aiKeepAlive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:      return "总览"
        case .control:        return "完全控制"
        case .power:          return "电源设置"
        case .automation:     return "自动化"
        case .schedule:       return "定时与唤醒"
        case .quickQuit:      return "快速退出"
        case .external:       return "外部活动"
        case .log:            return "运行日志"
        case .update:         return "更新"
        case .systemMonitor:  return "系统监控"
        case .thermal:        return "温度监控"
        case .fan:            return "风扇控制"
        case .alertRules:     return "告警规则"
        case .uninstall:      return "卸载 Deep Sleep"
        case .serverMode:     return "服务器模式"
        case .nice:           return "进程优先级"
        case .hosts:          return "Hosts 编辑"
        case .quarantine:     return "Quarantine"
        case .toolbox:        return "工具箱"
        case .aiKeepAlive:    return "AI 保活"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard:      return "square.grid.2x2"
        case .control:        return "lock.shield"
        case .power:          return "bolt"
        case .automation:     return "gearshape.2"
        case .schedule:       return "clock"
        case .quickQuit:      return "bolt.slash"
        case .external:       return "person.2"
        case .log:            return "doc.text"
        case .update:         return "arrow.down.circle"
        case .systemMonitor:  return "waveform.path.ecg"
        case .thermal:        return "thermometer.medium"
        case .fan:            return "fan"
        case .alertRules:     return "bell.badge"
        case .uninstall:      return "trash"
        case .serverMode:     return "powersleep"
        case .nice:           return "gauge.with.dots.needle.bottom.50percent"
        case .hosts:          return "doc.text.fill"
        case .quarantine:     return "lock.shield"
        case .toolbox:        return "wrench.and.screwdriver.fill"
        case .aiKeepAlive:    return "bolt.heart.fill"
        }
    }
}

struct ContentView: View {

    @EnvironmentObject private var controller: SleepController
    @State private var selection: SidebarItem = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("保持清醒") {
                    Label(SidebarItem.dashboard.title, systemImage: SidebarItem.dashboard.symbol)
                        .tag(SidebarItem.dashboard)
                }
                Section("系统控制") {
                    ForEach([SidebarItem.control, .power, .schedule]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                    Label(SidebarItem.serverMode.title, systemImage: SidebarItem.serverMode.symbol)
                        .tag(SidebarItem.serverMode)
                }
                Section("自动化") {
                    Label(SidebarItem.automation.title, systemImage: SidebarItem.automation.symbol)
                        .tag(SidebarItem.automation)
                    Label(SidebarItem.quickQuit.title, systemImage: SidebarItem.quickQuit.symbol)
                        .tag(SidebarItem.quickQuit)
                }
                Section("散热") {
                    ForEach([SidebarItem.thermal, .fan, .alertRules]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("诊断") {
                    Label(SidebarItem.external.title, systemImage: SidebarItem.external.symbol)
                        .tag(SidebarItem.external)
                    Label(SidebarItem.log.title, systemImage: SidebarItem.log.symbol)
                        .tag(SidebarItem.log)
                    Label(SidebarItem.systemMonitor.title, systemImage: SidebarItem.systemMonitor.symbol)
                        .tag(SidebarItem.systemMonitor)
                }
                Section("维护") {
                    Label(SidebarItem.update.title, systemImage: SidebarItem.update.symbol)
                        .tag(SidebarItem.update)
                    Label(SidebarItem.uninstall.title, systemImage: SidebarItem.uninstall.symbol)
                        .tag(SidebarItem.uninstall)
                }
                Section("工具") {
                    // 只渲染工具箱一项。nice / hosts / quarantine 仍然保留在
                    // SidebarItem 里（工具箱页点卡片靠切 selection 进入它们），
                    // 但不再在侧边栏单独出现。
                    Label(SidebarItem.toolbox.title, systemImage: SidebarItem.toolbox.symbol)
                        .tag(SidebarItem.toolbox)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 250)
            .safeAreaInset(edge: .bottom) {
                SidebarFooter()
                    .environmentObject(controller)
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let banner = controller.banner {
                        BannerView(banner: banner) { controller.banner = nil }
                    }
                    detailContent
                }
                .pageLayout(maxWidth: selection == .toolbox ? 980 : 760)
            }
            .navigationTitle(selection.title)
            .frame(minWidth: 620)
            .toolbar {
                // 从工具箱进入某个工具后，标题栏左侧给一个返回按钮 ——
                // 否则用户会以为走丢了（侧边栏里已经看不到那个条目了）。
                if showsBackToToolbox {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            selection = .toolbox
                        } label: {
                            Label("工具箱", systemImage: "chevron.left")
                        }
                        .help("返回工具箱")
                    }
                }
            }
        }
    }

    /// 当前页是不是「从工具箱进来的工具页」。
    private var showsBackToToolbox: Bool {
        switch selection {
        case .nice, .hosts, .quarantine, .aiKeepAlive:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .dashboard:      DashboardView()
        case .control:        ControlView()
        case .power:          PowerSettingsView()
        case .automation:     AutomationView()
        case .schedule:       ScheduleView()
        case .quickQuit:      QuickQuitView()
        case .external:       ExternalActivityView()
        case .log:            LogView()
        case .update:         UpdateView()
        case .systemMonitor:  MonitoringView()
        case .thermal:        ThermalView(monitor: ThermalMonitor.shared)
        case .fan:            FanControlView(controller: FanController.shared)
        case .alertRules:     AlertRulesView(engine: AlertRuleEngine.shared)
        case .uninstall:      UninstallView()
        case .serverMode:     ServerModeView()
        case .nice:           NiceView()
        case .hosts:          HostsView()
        case .quarantine:     QuarantineView()
        case .toolbox:
            ToolboxView { tool in
                selection = tool.sidebarItem
            }
        case .aiKeepAlive:    KeepAliveView()
        }
    }
}

/// 侧边栏底部的状态摘要。
struct SidebarFooter: View {
    @EnvironmentObject private var controller: SleepController

    private var isHolding: Bool { !controller.activeAssertions.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 7) {
                Circle()
                    .fill(isHolding ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 8, height: 8)
                Text(isHolding ? "保持清醒中（\(controller.activeAssertions.count)）" : "允许正常睡眠")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if controller.sleepDisabled {
                Label("已完全禁止睡眠", systemImage: "exclamationmark.octagon.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if controller.isServerModeActive {
                Label("服务器模式运行中", systemImage: "powersleep")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 5) {
                Image(systemName: controller.helperState.isReady ? "lock.shield.fill" : "lock.shield")
                    .font(.caption2)
                Text("完全控制：\(controller.helperState.title)")
                    .font(.caption2)
            }
            .foregroundStyle(controller.helperState.isReady ? Color.green : Color.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
