//
//  HangDetectionView.swift
//  Deep Sleep
//
//  「未响应应用检测」配置页：总开关、检测范围、白名单、当前状态与检测结果。
//
//  单独一个 View（无参数），主界面怎么摆由主 Agent 决定。
//  配置改动立即落盘（`HangDetectionConfig.saveIfNotDefault`），
//  检测器每轮从 UserDefaults 重读，所以改完立刻生效，不需要「保存」按钮。
//
//  界面约定：
//    - 「检测结果」里的判据直接问系统（与活动监视器、强制退出窗口同源），
//      不经过被测应用，所以不会因为辅助功能响应慢就误报。
//    - 结果用紧凑行列表给全三样东西：应用名 / 已卡多久 / 状态。
//    - 处理选项（强制退出 / 忽略）跟结果放在一起，一眼能知道该点哪个。
//

import SwiftUI
import AppKit

struct HangDetectionView: View {

    @ObservedObject private var detector = HangDetector.shared

    @State private var config: HangDetectionConfig = .default
    @State private var isPicking = false
    @State private var installedApps: [InstalledApp] = []

    /// 当前被系统判定为未响应的应用。只做展示，不参与判定。
    @State private var unresponsive: [SyUnresponsiveApp] = []
    /// 每个进程第一次被发现未响应的时间，用来算「已卡多久」。
    @State private var firstSeen: [pid_t: Date] = [:]
    /// 本页点过「忽略」的进程：检测器不再提示，这里也不再列。
    @State private var ignoredPIDs: Set<pid_t> = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            switchCard
            scopeCard
            resultsCard
            whitelistCard
            statusCard
            Spacer(minLength: 0)
        }
        .pageLayout()
        .onAppear {
            config = HangDetectionConfig.load()
            refreshResults()
        }
        .onChange(of: config) { _, newValue in
            newValue.saveIfNotDefault()
            applyDetectorState()
            refreshResults()
        }
        // 检测器每跑完一轮就更新一次摘要，跟着它刷新结果列表。
        .onChange(of: detector.lastSummary) { _, _ in
            refreshResults()
        }
        .sheet(isPresented: $isPicking) {
            HangAppPickerSheet(apps: installedApps,
                               onPick: { app in
                                   config.whitelistBundleIDs.append(app.bundleID)
                                   config.whitelistBundleIDs.sort()
                               },
                               onClose: { isPicking = false })
        }
    }

    // MARK: - 总开关

    private var switchCard: some View {
        SectionCard(
            title: "未响应应用检测",
            subtitle: "卡死的应用会从菜单栏下方弹出提示，可以忽略、强制退出或重启。",
            symbol: "exclamationmark.arrow.triangle.2.circlepath",
            accent: DS.Tone.caution
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Toggle("启用检测", isOn: $config.enabled)
                    .toggleStyle(.switch)

                if config.enabled {
                    HStack(spacing: DS.Space.md) {
                        Text("检测间隔")
                            .font(.callout)
                        Picker("", selection: $config.detectionIntervalSeconds) {
                            ForEach(Self.intervalChoices, id: \.self) { value in
                                Text("\(value) 秒").tag(value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Text("间隔越短越及时，也越频繁地询问其他应用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - 检测范围

    private var scopeCard: some View {
        SectionCard(
            title: "检测范围",
            subtitle: "关掉「检测后台应用」之后只看当前正在用的那个应用。",
            symbol: "line.3.horizontal.decrease.circle",
            accent: .accentColor
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Toggle("检测后台应用", isOn: $config.checkBackgroundApps)
                    .toggleStyle(.switch)
                Toggle("忽略系统进程", isOn: $config.ignoreSystemProcesses)
                    .toggleStyle(.switch)

                Text("系统进程指安装在「/System」下的应用。它们极少卡死，"
                    + "而且误报的系统进程没法处理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 检测结果

    private var resultsCard: some View {
        SectionCard(
            title: "检测结果",
            subtitle: "与活动监视器、强制退出窗口同源。",
            symbol: "list.bullet.rectangle",
            accent: unresponsive.isEmpty ? DS.Tone.good : DS.Tone.caution,
            accessory: AnyView(
                Button {
                    refreshResults()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            )
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(spacing: DS.Space.md) {
                    MetricTile(
                        title: "本轮扫描",
                        value: scannedCountText,
                        unit: "个应用",
                        status: scannedStatusText,
                        tint: detector.isProbeAvailable ? DS.Tone.good : DS.Tone.caution
                    )
                    MetricTile(
                        title: "判定未响应",
                        value: "\(hungCount)",
                        unit: "个",
                        status: hungCount == 0 ? "全部正常" : "需要处理",
                        tint: hungCount == 0 ? DS.Tone.good : DS.Tone.caution
                    )
                }

                if unresponsive.isEmpty {
                    EmptyStateView(
                        title: "没有发现未响应的应用",
                        message: config.enabled
                            ? "下一轮检测结束后，如果某个应用卡住，这里会列出它。"
                            : "检测当前是关着的。打开上面的「启用检测」后才会开始问系统。",
                        systemImage: "checkmark.circle"
                    )
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        ForEach(unresponsive) { app in
                            unresponsiveRow(app)
                        }
                    }
                }
            }
        }
    }

    /// 一行未响应应用：应用名 / 已卡多久 / 状态 / 处理选项。
    private func unresponsiveRow(_ app: SyUnresponsiveApp) -> some View {
        // 用 TimelineView 让「已卡多久」每秒走一格，不用等下一轮检测。
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Tone.caution)
                    Text(app.name)
                        .font(.body.weight(.medium))
                    Text(app.bundleID)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: DS.Space.sm)
                    StatusPill(text: "未响应", isActive: true, color: DS.Tone.caution)
                }

                HStack(spacing: DS.Space.sm) {
                    Text("已卡 \(durationText(since: app.firstSeen, now: context.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: DS.Space.sm)
                    Button("忽略") {
                        ignore(app)
                    }
                    .controlSize(.small)
                    Button("强制退出", role: .destructive) {
                        forceQuit(app)
                    }
                    .controlSize(.small)
                }
            }
            .padding(DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .insetPanel()
        }
    }

    // MARK: - 白名单

    private var whitelistCard: some View {
        SectionCard(
            title: "白名单",
            subtitle: "名单里的应用永远不会被检测，也不会弹提示。",
            symbol: "checklist",
            accent: DS.Tone.good
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                if config.whitelistBundleIDs.isEmpty {
                    EmptyStateView(
                        title: "白名单为空",
                        message: "把容易误报的应用加进来，它就不会被检测，也不会弹提示。",
                        systemImage: "tray"
                    )
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        ForEach(config.whitelistBundleIDs, id: \.self) { bundleID in
                            HStack(spacing: DS.Space.sm) {
                                Image(systemName: "app")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(displayName(for: bundleID))
                                    .font(.body)
                                Text(bundleID)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: DS.Space.sm)
                                Button(role: .destructive) {
                                    config.whitelistBundleIDs.removeAll { $0 == bundleID }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, DS.Space.xxs)
                        }
                    }
                }

                HStack {
                    Button {
                        installedApps = Self.installedApplications()
                        isPicking = true
                    } label: {
                        Label("添加应用", systemImage: "plus")
                    }
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - 当前状态

    private var statusCard: some View {
        SectionCard(
            title: "当前状态",
            subtitle: nil,
            symbol: "info.circle",
            accent: .accentColor
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(spacing: DS.Space.sm) {
                    StatusPill(
                        text: detector.isProbeAvailable ? "系统判定可用" : "系统判定接口不可用",
                        isActive: detector.isProbeAvailable,
                        color: detector.isProbeAvailable ? DS.Tone.good : DS.Tone.caution
                    )
                    Spacer(minLength: 0)
                }

                Text("是否卡死由系统判定：跟活动监视器、强制退出窗口读的是同一份状态，"
                    + "不经过被测应用，所以不会因为某个应用辅助功能响应慢就误报。"
                    + "系统要等它自己的超时周期（约 15 秒）才会把应用标成未响应，刚卡住的那十几秒里不会提示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !detector.isProbeAvailable {
                    Text("读到系统判定状态的接口没有取到，本机暂时无法检测。"
                        + "这种情况不做任何判定，也不会弹误报的提示。")
                        .font(.caption)
                        .foregroundStyle(DS.Tone.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                LabeledContent("检测间隔") {
                    Text(config.enabled ? "\(config.detectionIntervalSeconds) 秒" : "已停用")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("最近一次检测") {
                    Text(lastResultText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 结果扫描

    /// 只读地问一遍系统：现在有哪些应用被判为未响应。
    ///
    /// 这里**不做判定**，只是把系统的判定结果列出来。筛选条件跟检测器一致
    /// （范围、系统进程、白名单），免得这里列出来、那边又不检测。
    private func refreshResults() {
        guard WindowServerResponsiveness.isAvailable else {
            unresponsive = []
            return
        }

        let now = Date()
        var rows: [SyUnresponsiveApp] = []
        var stillUnresponsive: Set<pid_t> = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  !ignoredPIDs.contains(app.processIdentifier),
                  isInScope(bundleID: bundleID, bundleURL: app.bundleURL) else { continue }
            let pid = app.processIdentifier
            guard let verdict = WindowServerResponsiveness.isUnresponsive(pid: pid), verdict else { continue }

            let first = firstSeen[pid] ?? now
            firstSeen[pid] = first
            stillUnresponsive.insert(pid)
            rows.append(SyUnresponsiveApp(
                pid: pid,
                bundleID: bundleID,
                name: app.localizedName ?? bundleID,
                firstSeen: first
            ))
        }

        // 已经不卡的进程就别再记着「第一次没响应」的时间了。
        for pid in firstSeen.keys where !stillUnresponsive.contains(pid) {
            firstSeen.removeValue(forKey: pid)
        }

        unresponsive = rows.sorted { $0.firstSeen < $1.firstSeen }
    }

    /// 过滤规则与检测器保持一致。
    private func isInScope(bundleID: String, bundleURL: URL?) -> Bool {
        if config.whitelistBundleIDs.contains(bundleID) { return false }
        if config.ignoreSystemProcesses,
           let path = bundleURL?.path,
           path.hasPrefix("/System") { return false }
        if !config.checkBackgroundApps {
            // 只看前台应用：后台应用一律不列。
            let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            return frontmostBundleID == bundleID
        }
        return true
    }

    // MARK: - 处理选项

    /// 忽略：检测器不再提示这个进程，本页也不再列它。
    private func ignore(_ app: SyUnresponsiveApp) {
        ignoredPIDs.insert(app.pid)
        detector.ignore(event: makeEvent(app))
        refreshResults()
    }

    /// 强制退出：先温和 terminate，不动就 kill —— 与弹窗里的按钮同一个实现。
    private func forceQuit(_ app: SyUnresponsiveApp) {
        detector.forceQuit(event: makeEvent(app))
        refreshResults()
    }

    private func makeEvent(_ app: SyUnresponsiveApp) -> HangEvent {
        HangEvent(
            pid: app.pid,
            bundleID: app.bundleID,
            appName: app.name,
            detectedAt: app.firstSeen,
            reason: "系统判定为未响应（活动监视器同源判据）"
        )
    }

    // MARK: - 辅助

    /// 还没跑过检测时不写 0 —— 那是「没测过」，不是「一个都没扫」。
    private var scannedCountText: String {
        guard let summary = detector.lastSummary else { return "—" }
        return "\(summary.scannedCount)"
    }

    private var scannedStatusText: String {
        guard detector.lastSummary != nil else { return "尚未检测" }
        return detector.isProbeAvailable ? "系统判定可用" : "系统判定接口不可用"
    }

    private var hungCount: Int {
        detector.lastSummary?.hungCount ?? unresponsive.count
    }

    private func durationText(since start: Date, now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(start)), 0)
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分 \(seconds % 60) 秒" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    private var lastResultText: String {
        guard let summary = detector.lastSummary else { return "尚未检测" }
        let time = summary.date.formatted(date: .omitted, time: .shortened)
        return "\(time) · \(summary.message)"
    }

    /// 白名单里存的是 bundle id，界面上要显示人看得懂的名字。
    private func displayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }


    /// 配置变了就让检测器跟上：开关变了要重启定时器，间隔变了要换定时器。
    private func applyDetectorState() {
        if config.enabled {
            HangDetector.shared.start()
        } else {
            HangDetector.shared.stop()
        }
    }

    private static let intervalChoices: [Int] = [5, 10, 15, 30, 60, 120]

    /// 扫本机已安装的应用，给白名单用。
    private static func installedApplications() -> [InstalledApp] {
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        ]

        var found: [String: InstalledApp] = [:]

        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty,
                  let url = app.bundleURL else { continue }
            found[bundleID] = InstalledApp(
                bundleID: bundleID,
                name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                path: url.path,
                isRunning: true
            )
        }

        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(entry)
                guard let bundle = Bundle(path: path),
                      let bundleID = bundle.bundleIdentifier,
                      found[bundleID] == nil else { continue }
                let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? (entry as NSString).deletingPathExtension
                found[bundleID] = InstalledApp(
                    bundleID: bundleID,
                    name: name,
                    path: path,
                    isRunning: false
                )
            }
        }

        return found.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - 数据

/// 一个可加入白名单的应用。
struct InstalledApp: Identifiable {
    let bundleID: String
    let name: String
    let path: String
    let isRunning: Bool

    var id: String { bundleID }
}

/// 一条「当前未响应」的应用记录。
///
/// 只做展示用：判据来自系统（与活动监视器同源），本页不参与判定。
struct SyUnresponsiveApp: Identifiable {
    let pid: pid_t
    let bundleID: String
    let name: String
    /// 第一次发现它没响应的时间。
    let firstSeen: Date

    var id: pid_t { pid }
}

// MARK: - 选择应用

/// 白名单选应用的弹窗。
struct HangAppPickerSheet: View {

    let apps: [InstalledApp]
    let onPick: (InstalledApp) -> Void
    let onClose: () -> Void

    @State private var query = ""

    private var filtered: [InstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("添加白名单")
                .font(.headline)

            TextField("搜索应用", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                    ForEach(filtered) { app in
                        HStack(spacing: DS.Space.sm) {
                            Image(systemName: "app")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                Text(app.name)
                                    .font(.body)
                                Text(app.bundleID)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: DS.Space.sm)
                            if app.isRunning {
                                Tag(text: "运行中", color: DS.Tone.good)
                            }
                            Button("添加") { onPick(app) }
                                .controlSize(.small)
                        }
                        .padding(.vertical, DS.Space.xxs)
                    }
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button("完成", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 460, height: 480)
    }
}
