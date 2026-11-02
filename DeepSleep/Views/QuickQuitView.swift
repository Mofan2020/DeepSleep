//
//  QuickQuitView.swift
//  Deep Sleep
//
//  快速退出页：配快捷键、选应用、看结果。
//
//  2026-11 界面换新：
//  - 应用名单改成原生 Table（可搜索、可勾选多行）。
//  - 「立即退出全部」是页面的主操作，borderedProminent，并写清会连带结束
//    这些应用的**全部子进程**。
//  - 空态用 EmptyStateView。
//  - 间距 / 圆角一律走 `DS.Space` / `DS.Radius`，不写字面量。
//

import Carbon.HIToolbox
import SwiftUI

struct QuickQuitView: View {

    @EnvironmentObject private var controller: SleepController
    @ObservedObject private var engine = QuickQuitEngine.shared

    @State private var showPicker = false
    /// Table 里勾选的行（按 bundle id 记录）。
    @State private var selection: Set<QuickQuitTarget.ID> = []
    @State private var query: String = ""

    /// 待确认的删除。`nil` 表示没有删除在等确认。
    @State private var pendingDelete: TlDeleteRequest?

    /// 搜索过滤后的名单。
    private var filteredTargets: [QuickQuitTarget] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return engine.targets }
        return engine.targets.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            mainCard
            hotkeyCard
            appsCard
            protectedCard
            if let outcome = engine.lastOutcome {
                outcomeCard(outcome)
            }
        }
        .sheet(isPresented: $showPicker) {
            QuickQuitAppPicker(
                candidates: engine.candidates(),
                onPick: { candidate in
                    engine.add(bundleIdentifier: candidate.bundleIdentifier, name: candidate.name)
                },
                onClose: { showPicker = false }
            )
        }
        .deleteConfirmation($pendingDelete)
    }

    // MARK: - 主操作

    private var mainCard: some View {
        SectionCard(
            title: "快速退出",
            subtitle: "按下快捷键，把名单里的应用连同它们的全部子进程一起强制结束。"
                + "受保护的系统进程会被跳过，不会因为按错键而失去界面或会话。",
            symbol: "bolt.horizontal.circle",
            accessory: AnyView(
                StatusPill(
                    text: shortcutStatusText,
                    isActive: engine.isHotkeyLive,
                    color: engine.isHotkeyLive ? DS.Tone.good : DS.Tone.idle
                )
            )
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                StatusPill(
                    text: engine.targets.isEmpty ? "名单为空" : "名单 \(engine.targets.count) 个应用",
                    isActive: !engine.targets.isEmpty,
                    color: engine.targets.isEmpty ? DS.Tone.idle : DS.Tone.info
                )

                if let problem = engine.hotkeyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DS.Tone.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { _ = await engine.run(dryRun: false, trigger: "界面按钮") }
                } label: {
                    Label("立即退出全部", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(engine.targets.isEmpty || engine.isRunning)

                Text("会一并结束名单里这些应用的**全部子进程**（受保护的系统进程除外）。先点「演练一次」看看会动哪些。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: DS.Space.sm) {
                    Button {
                        Task { _ = await engine.run(dryRun: true, trigger: "界面演练") }
                    } label: {
                        Label("演练一次", systemImage: "eye")
                    }
                    .disabled(engine.targets.isEmpty || engine.isRunning)

                    Spacer(minLength: DS.Space.sm)
                }

                Divider()

                Toggle(isOn: $engine.isTriggerEnabled) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("启用全局快捷键").font(.body)
                        Text("关掉之后快捷键不再响应，名单与设置保留。")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: $engine.requiresConfirmation) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("执行前需要 Touch ID 确认").font(.body)
                        Text("默认关闭：这是应急按钮，多一步确认就慢一拍。")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    // MARK: - 快捷键

    private var hotkeyCard: some View {
        SectionCard(title: "快捷键", subtitle: nil, symbol: "keyboard") {
            HStack(spacing: DS.Space.md) {
                HotkeyRecorderField()
                Spacer(minLength: DS.Space.sm)
            }
        }
    }

    // MARK: - 应用名单

    private var appsCard: some View {
        SectionCard(
            title: "选定的应用",
            subtitle: engine.targets.isEmpty
                ? "还没有选定任何应用。按下快捷键或点「立即退出全部」时不会结束任何东西。"
                : "勾选若干行可以只移除选中的那几条。",
            symbol: "app.dashed",
            accessory: AnyView(
                Button {
                    showPicker = true
                } label: {
                    Label("添加应用", systemImage: "plus")
                }
            )
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                if engine.targets.isEmpty {
                    EmptyStateView(
                        title: "名单为空",
                        message: "把想一键关掉的应用加进来，按下快捷键就会连同它们的子进程一起结束。",
                        systemImage: "app.dashed",
                        actionTitle: "添加应用"
                    ) {
                        showPicker = true
                    }
                } else {
                    TextField("搜索应用名称或 Bundle ID", text: $query)
                        .textFieldStyle(.roundedBorder)

                    if filteredTargets.isEmpty {
                        EmptyStateView(
                            title: "没有匹配的应用",
                            message: "换个关键词再搜一次。",
                            systemImage: "magnifyingglass"
                        )
                    } else {
                        Table(filteredTargets, selection: $selection) {
                            TableColumn("应用") { target in
                                Text(target.name)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                            }
                            TableColumn("Bundle ID") { target in
                                Text(target.bundleIdentifier)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            TableColumn("状态") { target in
                                Tag(
                                    text: engine.isRunning(target) ? "运行中" : "未运行",
                                    color: engine.isRunning(target) ? DS.Tone.good : DS.Tone.idle
                                )
                            }
                            TableColumn("") { target in
                                Button(role: .destructive) {
                                    engine.remove(target)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("从名单里移除这个应用")
                            }
                            .width(DS.Space.xxl)
                        }
                        // Table 需要一个有界的高度；这里用令牌拼一个约 250pt 的区域。
                        .frame(height: DS.Space.xxl * 9)
                    }

                    HStack(spacing: DS.Space.sm) {
                        Button {
                            showPicker = true
                        } label: {
                            Label("添加应用", systemImage: "plus")
                        }

                        if !selection.isEmpty {
                            Button(role: .destructive) {
                                for target in engine.targets where selection.contains(target.id) {
                                    engine.remove(target)
                                }
                                selection.removeAll()
                            } label: {
                                Label("移除所选", systemImage: "trash")
                            }
                        }

                        if !engine.targets.isEmpty {
                            Button(role: .destructive) {
                                pendingDelete = TlDeleteRequest(
                                    title: "清空名单？",
                                    message: "名单里的 \(engine.targets.count) 个应用都会被移出，之后「立即退出全部」不再结束它们。",
                                    confirmTitle: "清空名单",
                                    perform: {
                                        engine.removeAll()
                                        selection.removeAll()
                                    }
                                )
                            } label: {
                                Label("清空名单", systemImage: "trash")
                            }
                        }

                        Spacer(minLength: DS.Space.sm)
                    }
                }
            }
        }
    }

    // MARK: - 不会结束的进程

    private var protectedCard: some View {
        SectionCard(
            title: "不会结束的进程",
            subtitle: "下面这些进程连同它们的子进程永远不会被结束。名单写死在代码里，开关绕不过去。",
            symbol: "hand.raised"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(QuickQuitEngine.protectedDisplayList, id: \.self) { item in
                    Text("· \(item)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("另外：pid 1（launchd）、内核任务、以及 Deep Sleep 自己一律拒绝。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, DS.Space.xxs)
            }
        }
    }

    // MARK: - 最近一次结果

    private func outcomeCard(_ outcome: QuickQuitOutcome) -> some View {
        SectionCard(
            title: outcome.dryRun ? "最近一次演练" : "最近一次结果",
            subtitle: "\(Self.formatter.string(from: outcome.date))，触发方式：\(outcome.usedHelper ? "特权助手" : "本进程权限")",
            symbol: "list.bullet.clipboard",
            accent: outcome.report.isClean ? DS.Tone.good : DS.Tone.caution
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(outcome.summary).font(.callout.weight(.medium))
                ForEach(Array(outcome.details.enumerated()), id: \.offset) { _, line in
                    Text("· \(line)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var shortcutStatusText: String {
        if !engine.isTriggerEnabled { return "快捷键已停用" }
        if engine.isHotkeyLive { return "快捷键生效中（\(engine.hotkey.displayText)）" }
        return "快捷键未生效"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}

// MARK: - 快捷键录制

/// 录制一个组合键。
///
/// 用 `addLocalMonitorForEvents`：它只看得到本应用窗口里的按键，
/// 不需要「输入监控」权限 —— 那正是这个功能刻意避开的东西。
struct HotkeyRecorderField: View {

    @ObservedObject private var engine = QuickQuitEngine.shared
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Text(engine.hotkey.displayText)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.sm)
                .background(Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))

            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Label(isRecording ? "按下新的组合…" : "录制快捷键",
                      systemImage: isRecording ? "record.circle" : "keyboard")
            }
            .buttonStyle(.borderedProminent)
            // 录制中用红色标示「正在等待输入」，配色不用三目选择两个不同的
            // ButtonStyle —— Swift 的三目要求两个分支同一个类型。
            .tint(isRecording ? .red : .accentColor)

            if isRecording {
                Button("取消") { stopRecording() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Text("Esc 取消")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            if let combo = HotkeyCombo(event: event) {
                engine.setHotkey(combo)
                stopRecording()
                return nil
            }
            // 没有修饰键：不当组合键，但也不让它漏进界面触发别的动作。
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }
}

// MARK: - 选择应用

struct QuickQuitAppPicker: View {

    let candidates: [QuickQuitCandidate]
    let onPick: (QuickQuitCandidate) -> Void
    let onClose: () -> Void

    @State private var query = ""

    private var filtered: [QuickQuitCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("选择要加入快速退出名单的应用")
                .font(.title3.weight(.semibold))
            Text("列表包含正在运行的应用与常见安装位置里的应用；受保护的系统应用不在其中。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("搜索", text: $query)
                .textFieldStyle(.roundedBorder)

            List(filtered) { candidate in
                HStack(spacing: DS.Space.sm) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(candidate.name).font(.body)
                        Text(candidate.bundleIdentifier)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: DS.Space.sm)
                    if candidate.isRunning {
                        Tag(text: "运行中", color: DS.Tone.good)
                    }
                    Button("添加") { onPick(candidate) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .frame(minHeight: 300)

            HStack {
                Text("已选中的应用按 bundle id 匹配，与应用从哪启动无关。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 520, height: 470)
    }
}
