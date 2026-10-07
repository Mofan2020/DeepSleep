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
    /// 卸载 Deep Sleep：二级确认 + 全流程清理。
    case uninstall

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
        case .uninstall:      return "卸载 Deep Sleep"
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
        case .uninstall:      return "trash"
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
                }
                Section("自动化") {
                    Label(SidebarItem.automation.title, systemImage: SidebarItem.automation.symbol)
                        .tag(SidebarItem.automation)
                    Label(SidebarItem.quickQuit.title, systemImage: SidebarItem.quickQuit.symbol)
                        .tag(SidebarItem.quickQuit)
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
                .pageLayout()
            }
            .navigationTitle(selection.title)
            .frame(minWidth: 620)
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
        case .uninstall:      UninstallView()
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
