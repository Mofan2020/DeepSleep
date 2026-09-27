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
    /// 外部活动：谁在阻止休眠、谁在改电源设置。
    case external
    case log

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:  return "总览"
        case .control:    return "完全控制"
        case .power:      return "电源设置"
        case .automation: return "自动化"
        case .schedule:   return "定时与唤醒"
        case .external:   return "外部活动"
        case .log:        return "运行日志"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard:  return "gauge.with.dots.needle.bottom.50percent"
        case .control:    return "lock.shield"
        case .power:      return "slider.horizontal.3"
        case .automation: return "wand.and.stars"
        case .schedule:   return "clock.arrow.circlepath"
        case .external:   return "binoculars"
        case .log:        return "text.alignleft"
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
                }
                Section("智能行为") {
                    Label(SidebarItem.automation.title, systemImage: SidebarItem.automation.symbol)
                        .tag(SidebarItem.automation)
                }
                Section("诊断") {
                    Label(SidebarItem.external.title, systemImage: SidebarItem.external.symbol)
                        .tag(SidebarItem.external)
                    Label(SidebarItem.log.title, systemImage: SidebarItem.log.symbol)
                        .tag(SidebarItem.log)
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
        case .dashboard:  DashboardView()
        case .control:    ControlView()
        case .power:      PowerSettingsView()
        case .automation: AutomationView()
        case .schedule:   ScheduleView()
        case .external:   ExternalActivityView()
        case .log:        LogView()
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
