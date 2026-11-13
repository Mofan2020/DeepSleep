//
//  AudioControlView.swift
//  Deep Sleep
//
//  音频控制页面（实验性）：逐应用音量调节。
//  - 顶部：实验性警告横幅 + 全局启用开关
//  - 列表：每行 = 应用名 + 音量滑块 + 百分比 + 静音切换 + 状态标签
//  - 底部：刷新按钮 + 说明
//

import SwiftUI

struct AudioControlView: View {

    @EnvironmentObject private var controller: SleepController
    @ObservedObject private var manager = AudioControlManager.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                // 实验性警告
                BannerView(
                    banner: Banner(level: .info, text: "这是实验性功能，可能不稳定。开启后会为每个正在输出音频的应用创建独立的音频引擎。"),
                    onDismiss: {}
                )
                .padding(.horizontal, DS.Space.md)

                // 全局启用开关
                globalToggleSection

                // 授权与菜单栏
                menuBarSection
                permissionSection

                if manager.controlledApps.isEmpty {
                    EmptyStateView(
                        title: "没有检测到正在输出音频的应用",
                        message: "播放音乐、视频或系统声音后，列表会自动刷新。",
                        systemImage: "speaker.wave.2",
                        actionTitle: "手动刷新",
                        action: { manager.refreshNow() }
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, DS.Space.md)
                } else {
                    appsListSection
                }

                // 底部说明
                footerSection
            }
            .pageLayout(maxWidth: 760)
        }
        .navigationTitle("音频控制")
        .onAppear {
            // 页面打开时从存储恢复 enabled 状态（init 已做）
            // 如果已启用，manager 会自动开始刷新
        }
        .onDisappear {
            // 页面关闭不停止 manager（用户可能只是切页，功能应继续生效）
            // 只有显式关闭全局开关才 stopAll
        }
    }

    // MARK: - 全局开关区

    private var globalToggleSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.md) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: DS.Metric.iconButtonSize, weight: .semibold))
                    .foregroundStyle(DS.Tone.info)
                    .frame(width: DS.Metric.minimumTouchTarget, height: DS.Metric.minimumTouchTarget)
                    .contentShape(Rectangle())

                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("启用逐应用音量控制（实验性）")
                        .font(.headline)
                    Text("为每个正在输出音频的应用创建独立音频引擎，可单独调节音量。不改变系统主音量。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DS.Space.sm)

                Toggle("", isOn: Binding(
                    get: { manager.isEnabled },
                    set: { manager.setEnabled($0) }))
                    .controlSize(.large)
                    .toggleStyle(.switch)
                    .accessibilityLabel("启用逐应用音量控制")
            }
            .padding(DS.Space.md)
            .glassCard(cornerRadius: DS.Radius.card)
        }
        .padding(.horizontal, DS.Space.md)
    }

    // MARK: - 菜单栏

    private var menuBarSection: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "menubar.arrow.up.rectangle")
                .font(.system(size: DS.Metric.iconButtonSize, weight: .semibold))
                .foregroundStyle(DS.Tone.info)
                .frame(width: DS.Metric.minimumTouchTarget, height: DS.Metric.minimumTouchTarget)
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("在菜单栏中管理")
                    .font(.headline)
                Text("开启后菜单栏多一个喇叭图标，点开就能调每个正在出声的应用的音量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DS.Space.sm)

            Toggle("", isOn: Binding(
                get: { manager.isMenuBarEnabled },
                set: { manager.setMenuBarEnabled($0) }))
                .controlSize(.large)
                .toggleStyle(.switch)
                .accessibilityLabel("在菜单栏中管理音频")
        }
        .padding(DS.Space.md)
        .glassCard(cornerRadius: DS.Radius.card)
        .padding(.horizontal, DS.Space.md)
    }

    // MARK: - 授权

    /// 没有「系统音频录制」授权时整条链路是静音的，而且没有任何 API 会报错。
    /// 所以这里必须明说，并给一个能直接跳过去的入口。
    @ViewBuilder
    private var permissionSection: some View {
        if manager.permission.isDenied {
            HStack(spacing: DS.Space.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: DS.Metric.iconButtonSize, weight: .semibold))
                    .foregroundStyle(DS.Tone.caution)
                    .frame(width: DS.Metric.minimumTouchTarget, height: DS.Metric.minimumTouchTarget)

                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("需要「系统音频录制」授权")
                        .font(.headline)
                    Text("没有这项授权时调节不会生效，应用的声音也会被摘走。到系统设置的隐私与安全性里打开，授权后会自动恢复。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DS.Space.sm)

                Button {
                    manager.openPermissionSettings()
                } label: {
                    Label("去系统设置", systemImage: "arrow.up.forward.app")
                }
                .controlSize(.regular)
            }
            .padding(DS.Space.md)
            .glassCard(cornerRadius: DS.Radius.card)
            .padding(.horizontal, DS.Space.md)
        }
    }

    // MARK: - 应用列表

    private var appsListSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.md) {
                Text("正在输出音频的应用")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: DS.Space.sm)
                Button {
                    manager.refreshNow()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("重新扫描正在输出音频的应用")
            }
            .padding(.horizontal, DS.Space.md)

            LazyVStack(spacing: DS.Space.sm) {
                ForEach(manager.controlledApps) { app in
                    AppVolumeRow(app: app, manager: manager)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : DS.Animation.bouncy, value: manager.controlledApps.map(\.uniqueKey))
            .padding(.horizontal, DS.Space.md)
        }
    }

    // MARK: - 底部说明

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Divider()
            Text("说明")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("• 每个应用的音量范围是 0%–100%，不放大（避免削波）。")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("• 关闭页面不停止功能；关闭上方开关才会拆除所有引擎并恢复原状。")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("• 蓝牙设备、AirPlay 等非内置输出可能不被支持。")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("• 遇到无声、噪音、崩溃请关闭开关并反馈。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.bottom, DS.Space.lg)
    }
}

// MARK: - 单行：应用 + 音量滑块

private struct AppVolumeRow: View {

    let app: AudioControlledApp
    @ObservedObject var manager: AudioControlManager

    @State private var localVolume: Double
    @State private var isDragging = false

    init(app: AudioControlledApp, manager: AudioControlManager) {
        self.app = app
        self.manager = manager
        self._localVolume = State(initialValue: app.volume)
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            // 应用图标/名称
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: appIcon(for: app.bundleID))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(app.isProducingAudio ? DS.Tone.good : .secondary)
                    Text(app.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if !app.isProducingAudio {
                        Text("静默")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }

                // PID 列表（最多显示 3 个）
                if app.processIDs.count > 1 {
                    Text("PID: \(app.processIDs.prefix(3).map(String.init).joined(separator: ", "))\(app.processIDs.count > 3 ? " …" : "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 160, alignment: .leading)

            // 音量滑块
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: localVolume > 0.001 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(localVolume > 0.001 ? .primary : .secondary)
                        .frame(width: 16)

                    Slider(
                        value: Binding(
                            get: { localVolume },
                            set: { newVal in
                                localVolume = AudioControlSupport.clampVolume(newVal)
                                if !isDragging { manager.setVolume(localVolume, for: app) }
                            }
                        ),
                        in: 0...1,
                        step: AudioControlSupport.volumeStep,
                        onEditingChanged: { dragging in
                            isDragging = dragging
                            if !dragging { manager.setVolume(localVolume, for: app) }
                        }
                    )
                    .controlSize(.regular)
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)

                    Text(AudioControlSupport.formatPercent(localVolume))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }

                // 静音切换 + 状态
                HStack(spacing: DS.Space.sm) {
                    Button {
                        manager.toggleMute(forKey: app.uniqueKey)
                        let current = manager.controlledApps.first { $0.uniqueKey == app.uniqueKey }?.volume ?? app.volume
                        localVolume = current
                    } label: {
                        Label(app.volume > 0.001 ? "静音" : "取消静音", systemImage: app.volume > 0.001 ? "speaker.slash" : "speaker.wave.2")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)

                    if let engine = manager.engines[app.uniqueKey] {
                        Text("引擎运行中 (\(engine.renderCycles) 回调)")
                            .font(.caption2)
                            .foregroundStyle(DS.Tone.good)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: DS.Space.sm)
        }
        .padding(DS.Space.md)
        .glassCard(cornerRadius: DS.Radius.card)
        .onChange(of: app.volume) { _, newVal in
            // 外部改变（如存储恢复）同步到本地
            if !isDragging { localVolume = newVal }
        }
    }

    /// 根据 bundleID 推测图标
    private func appIcon(for bundleID: String?) -> String {
        guard let bid = bundleID?.lowercased() else { return "app" }
        if bid.contains("music") || bid.contains("spotify") || bid.contains("netease") { return "music.note" }
        if bid.contains("safari") { return "safari" }
        if bid.contains("chrome") { return "globe" }
        if bid.contains("firefox") { return "flame" }
        if bid.contains("edge") { return "e.square" }
        if bid.contains("quicktime") || bid.contains("vlc") || bid.contains("iina") { return "play.tv" }
        if bid.contains("facetime") { return "video.badge.waveform" }
        if bid.contains("zoom") || bid.contains("teams") || bid.contains("meet") { return "person.2.wave.2" }
        if bid.contains("discord") { return "message.badge.waveform" }
        if bid.contains("wechat") || bid.contains("weixin") { return "message.fill" }
        if bid.contains("qq") { return "bubble.left.and.bubble.right.fill" }
        if bid.contains("system") || bid.contains("corespeech") { return "gear" }
        return "app"
    }
}