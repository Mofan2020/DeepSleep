//
//  HangDetectionView.swift
//  Deep Sleep
//
//  「未响应应用检测」配置页：总开关、检测范围、白名单、当前状态。
//
//  单独一个 View（无参数），主界面怎么摆由主 Agent 决定。
//  配置改动立即落盘（`HangDetectionConfig.saveIfNotDefault`），
//  检测器每轮从 UserDefaults 重读，所以改完立刻生效，不需要「保存」按钮。
//

import SwiftUI
import AppKit

struct HangDetectionView: View {

    @ObservedObject private var detector = HangDetector.shared

    @State private var config: HangDetectionConfig = .default
    @State private var isPicking = false
    @State private var installedApps: [InstalledApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switchCard
            scopeCard
            whitelistCard
            statusCard
            Spacer(minLength: 0)
        }
        .pageLayout()
        .onAppear {
            config = HangDetectionConfig.load()
        }
        .onChange(of: config) { _, newValue in
            newValue.saveIfNotDefault()
            applyDetectorState()
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
            subtitle: "后台定时询问系统里的应用是否还应答，卡死的应用会从菜单栏下方弹出提示，"
                + "可以忽略、强制退出或重启。",
            symbol: "exclamationmark.arrow.triangle.2.circlepath",
            accent: .orange
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("启用检测", isOn: $config.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                if config.enabled {
                    HStack(spacing: 10) {
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
            VStack(alignment: .leading, spacing: 10) {
                Toggle("检测后台应用", isOn: $config.checkBackgroundApps)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("忽略系统进程", isOn: $config.ignoreSystemProcesses)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Text("系统进程指安装在「/System」下的应用。它们极少卡死，"
                    + "而且误报的系统进程没法处理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 白名单

    private var whitelistCard: some View {
        SectionCard(
            title: "白名单",
            subtitle: "名单里的应用永远不会被检测，也不会弹提示。",
            symbol: "checklist",
            accent: .green
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if config.whitelistBundleIDs.isEmpty {
                    Text("名单为空")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(config.whitelistBundleIDs, id: \.self) { bundleID in
                        HStack(spacing: 10) {
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
                            Spacer(minLength: 8)
                            Button(role: .destructive) {
                                config.whitelistBundleIDs.removeAll { $0 == bundleID }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
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
                    Spacer()
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    StatusPill(
                        text: detector.isProbeAvailable ? "系统判定可用" : "系统判定接口不可用",
                        isActive: detector.isProbeAvailable,
                        color: detector.isProbeAvailable ? .green : .orange
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
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack(spacing: 10) {
                    Text("检测间隔")
                        .font(.callout)
                    Spacer(minLength: 8)
                    Text(config.enabled ? "\(config.detectionIntervalSeconds) 秒" : "已停用")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 10) {
                    Text("最近一次检测")
                        .font(.callout)
                    Spacer(minLength: 8)
                    Text(lastResultText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 辅助

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
        VStack(alignment: .leading, spacing: 12) {
            Text("添加白名单")
                .font(.headline)

            TextField("搜索应用", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { app in
                        HStack(spacing: 10) {
                            Image(systemName: "app")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                    .font(.body)
                                Text(app.bundleID)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if app.isRunning {
                                Tag(text: "运行中", color: .green)
                            }
                            Button("添加") { onPick(app) }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            HStack {
                Spacer()
                Button("完成", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 480)
    }
}
