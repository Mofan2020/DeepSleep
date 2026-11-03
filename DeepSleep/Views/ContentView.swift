//
//  ContentView.swift
//  Deep Sleep
//
//  主窗口：侧边栏导航 + 详情页。
//
//  设计约束（改动前先读）：
//  - 侧边栏是**数据驱动**的：分组与顺序集中在 `sidebarGroups` 一处，
//    改导航只改这一个数组，不要在 List 里散着写 Section。
//  - 每组最多 4 项。塞不下的功能走工具箱（`ToolboxView`），
//    不要为了塞下把侧边栏撑成长到需要滚动。
//  - 搜索框自己实现（不用 `.searchable`）：`.searchable` 依赖 SwiftUI
//    自己的行过滤行为，遇到 Section + selection 行为不稳定；
//    自己过滤才能保证「搜到就一定点得到」。
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
    /// 图片超分：把图片放大，算法可选。从工具箱进入。
    case imageUpscale
    /// lsof：查端口 / 文件被哪个进程占用。从工具箱进入。
    case lsof
    /// Shell 配置：编辑 .zshrc 等启动文件。从工具箱进入。
    case shellConfig
    /// 设备诊断：全面体检本机硬件 / 系统 / 配置。从工具箱进入。
    case deviceDiagnostics
    /// 未响应应用检测：自动发现卡死的应用并给出处理选项。
    case hangDetection
    /// WOL：扫描局域网设备并发送唤醒魔术包。从工具箱进入。
    case wakeOnLAN

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
        case .imageUpscale:   return "图片超分"
        case .lsof:           return "lsof 查询"
        case .shellConfig:    return "Shell 配置"
        case .deviceDiagnostics: return "设备诊断"
        case .hangDetection:  return "未响应应用"
        case .wakeOnLAN:      return "网络唤醒"
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
        case .imageUpscale:   return "arrow.up.left.and.arrow.down.right"
        case .lsof:           return "network"
        case .shellConfig:    return "terminal"
        case .deviceDiagnostics: return "stethoscope"
        case .hangDetection:  return "app.badge"
        case .wakeOnLAN:      return "bolt.horizontal.circle"
        }
    }

    /// 搜索用的附加关键词。搜「内存」能搜到系统监控，搜「电源」能搜到电源设置。
    var searchKeywords: String {
        switch self {
        case .dashboard:      return "状态 首页 概况 概览 overview"
        case .control:        return "特权 助手 root 管理员 禁止睡眠"
        case .power:          return "pmset 电池 电源 休眠"
        case .automation:     return "规则 自动化 定时条件"
        case .schedule:       return "定时 唤醒 倒计时 睡眠计划 wake"
        case .quickQuit:      return "结束 强杀 退出 进程 kill"
        case .external:       return "阻止 抢占 外部 活动 断言"
        case .log:            return "日志 log 输出"
        case .update:         return "版本 升级 检查 更新"
        case .systemMonitor:  return "cpu 内存 ram 负载 进程 监控 温度"
        case .thermal:        return "温度 传感器 过热 散热 温度监控"
        case .fan:            return "风扇 转速 rpm 散热 降温"
        case .alertRules:     return "告警 规则 阈值 提醒"
        case .uninstall:      return "卸载 清理 移除"
        case .serverMode:     return "服务器 常驻 永不睡眠 锁屏"
        case .nice:           return "优先级 nice 进程 调度"
        case .hosts:          return "hosts 域名 屏蔽 改写"
        case .quarantine:     return "隔离 解除 隔离属性 下载"
        case .toolbox:        return "工具 全部 实用"
        case .aiKeepAlive:    return "保活 ai 模型 接口 心跳"
        case .imageUpscale:   return "图片 放大 超分 清晰度"
        case .lsof:           return "端口 占用 文件 句柄"
        case .shellConfig:    return "shell zshrc 终端 启动文件"
        case .deviceDiagnostics: return "诊断 体检 硬件 检查"
        case .hangDetection:  return "卡死 无响应 假死 应用"
        case .wakeOnLAN:      return "网络唤醒 wol 局域网 魔术包"
        }
    }
}

// MARK: - 侧边栏分组

/// 侧边栏的一个分组。
struct SidebarGroup: Identifiable {
    let id: String
    let title: String
    let items: [SidebarItem]
}

extension ContentView {

    /// 侧边栏的分组与顺序。**导航的唯一来源。**
    ///
    /// 分组按「用户想做什么」排，不按「功能属于哪一层」排：
    /// 「保持清醒」是这台 App 的主用途，占第一组；「散热」是第二用途；
    /// 「维护」和「工具」放最后。
    static let sidebarGroups: [SidebarGroup] = [
        SidebarGroup(id: "awake", title: "保持清醒", items: [.dashboard, .control, .power]),
        SidebarGroup(id: "schedule", title: "计划", items: [.schedule, .automation, .serverMode]),
        SidebarGroup(id: "thermal", title: "散热", items: [.thermal, .fan, .alertRules]),
        SidebarGroup(id: "system", title: "系统", items: [.systemMonitor, .hangDetection, .external, .quickQuit]),
        SidebarGroup(id: "tools", title: "工具", items: [.toolbox]),
        SidebarGroup(id: "maintenance", title: "维护", items: [.update, .uninstall])
    ]
}

// MARK: - 主窗口

struct ContentView: View {

    @EnvironmentObject private var controller: SleepController
    @State private var selection: SidebarItem = .dashboard
    @State private var searchText: String = ""

    /// 页面路由。菜单栏在视图之外，切页只能靠它中转。
    ///
    /// 订阅 `revision` 而不是 `page`：连续两次请求同一个页面时
    /// 目标值没变，订阅 `page` 不会被唤醒。
    @ObservedObject private var router = PageRouter.shared

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onAppear {
            // 窗口被 SwiftUI 销毁重建时，新建的视图要回到用户最后看的那一页。
            selection = router.page
        }
        .onChange(of: router.revision) { _, _ in
            selection = router.page
        }
        .onChange(of: selection) { _, newValue in
            // 界面内部换页同步回路由：菜单栏下次「快速跳转」要知道当前在哪。
            router.noteLocalNavigation(newValue)
        }
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            SidebarSearchField(text: $searchText)

            List(selection: $selection) {
                ForEach(filteredGroups) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            Label(item.title, systemImage: item.symbol).tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                SidebarFooter()
                    .environmentObject(controller)
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
    }

    /// 按搜索词过滤分组。
    ///
    /// 命中的分组如果全被过滤掉就整组不显示；搜不到东西时显示一行提示，
    /// 而不是给一个空白的侧边栏。
    private var filteredGroups: [SidebarGroup] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !keyword.isEmpty else { return Self.sidebarGroups }
        return Self.sidebarGroups.compactMap { group in
            let hits = group.items.filter { item in
                item.title.lowercased().contains(keyword)
                    || item.searchKeywords.lowercased().contains(keyword)
            }
            guard !hits.isEmpty else { return nil }
            // 分组标题本身也命中时，整组都留着。
            if group.title.lowercased().contains(keyword) {
                return group
            }
            return SidebarGroup(id: group.id, title: group.title, items: hits)
        }
    }

    // MARK: 详情列

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                if let banner = controller.banner {
                    BannerView(banner: banner) { controller.banner = nil }
                }
                detailContent
            }
            .pageLayout(maxWidth: contentWidth)
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

    /// 工具箱页排 3 列卡片，需要更宽；其余页面 760 刚好。
    private var contentWidth: CGFloat {
        selection == .toolbox ? 980 : 760
    }

    /// 当前页是不是「从工具箱进来的工具页」。
    private var showsBackToToolbox: Bool {
        switch selection {
        case .nice, .hosts, .quarantine, .aiKeepAlive,
             .imageUpscale, .lsof, .shellConfig, .deviceDiagnostics, .wakeOnLAN:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .dashboard:      DashboardView(onOpenTool: { tool in selection = tool.sidebarItem })
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
        case .imageUpscale:   ImageUpscaleView()
        case .lsof:           LsofView()
        case .shellConfig:    ShellConfigView()
        case .deviceDiagnostics: DiagnosticsView()
        case .hangDetection:  HangDetectionView()
        case .wakeOnLAN:      WakeOnLANView()
        }
    }
}

// MARK: - 搜索框

/// 侧边栏顶部的搜索框。
struct SidebarSearchField: View {

    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索功能", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除")
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs)
        .insetPanel(cornerRadius: DS.Radius.control)
        .padding(.horizontal, DS.Space.md)
        .padding(.top, DS.Space.sm)
        .padding(.bottom, DS.Space.xs)
    }
}

// MARK: - 侧边栏底部摘要

/// 侧边栏底部的状态摘要。
///
/// 只保留**一眼要判断的那件事**：现在是否在阻止睡眠、助手是否就绪。
/// 其余状态（各项生效数、服务器模式）都在总览页说，这里不重复。
struct SidebarFooter: View {
    @EnvironmentObject private var controller: SleepController

    private var isHolding: Bool { !controller.activeAssertions.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Divider()

            HStack(spacing: DS.Space.sm) {
                Circle()
                    .fill(isHolding ? DS.Tone.good : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(isHolding ? "保持清醒中" : "允许正常睡眠")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: controller.helperState.isReady ? "lock.shield.fill" : "lock.shield")
                    .font(.caption2)
                    .foregroundStyle(controller.helperState.isReady ? DS.Tone.good : Color.secondary)
                    .help("完全控制：\(controller.helperState.title)")
            }

            if controller.sleepDisabled {
                Label("已完全禁止睡眠", systemImage: "exclamationmark.octagon.fill")
                    .font(.caption2)
                    .foregroundStyle(DS.Tone.caution)
            }
            if controller.isServerModeActive {
                Label("服务器模式运行中", systemImage: "powersleep")
                    .font(.caption2)
                    .foregroundStyle(DS.Tone.caution)
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.bottom, DS.Space.md)
        .padding(.top, DS.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
