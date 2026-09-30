//
//  QuickQuitView.swift
//  Deep Sleep
//
//  快速退出页：配快捷键、选应用、看结果。
//

import Carbon.HIToolbox
import SwiftUI

struct QuickQuitView: View {

    @EnvironmentObject private var controller: SleepController
    @ObservedObject private var engine = QuickQuitEngine.shared

    @State private var showPicker = false

    var body: some View {
        SectionCard(
            title: "快速退出",
            subtitle: "按下快捷键，把名单里的应用连同它们的全部子进程一起强制结束。"
                + "受保护的系统进程会被跳过，不会因为按错键而失去界面或会话。",
            symbol: "bolt.horizontal.circle",
            accent: .red
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    StatusPill(text: shortcutStatusText, isActive: engine.isHotkeyLive)
                    StatusPill(
                        text: engine.targets.isEmpty ? "名单为空" : "名单 \(engine.targets.count) 个应用",
                        isActive: !engine.targets.isEmpty
                    )
                    Spacer()
                }

                if let problem = engine.hotkeyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { _ = await engine.run(dryRun: false, trigger: "界面按钮") }
                    } label: {
                        Label("立即退出全部", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(engine.targets.isEmpty || engine.isRunning)

                    Button {
                        Task { _ = await engine.run(dryRun: true, trigger: "界面演练") }
                    } label: {
                        Label("演练一次", systemImage: "eye")
                    }
                    .disabled(engine.targets.isEmpty || engine.isRunning)

                    Spacer()
                }

                Divider()

                Toggle(isOn: $engine.isTriggerEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("启用全局快捷键").font(.body)
                        Text("关掉之后快捷键不再响应，名单与设置保留。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: $engine.requiresConfirmation) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("执行前需要 Touch ID 确认").font(.body)
                        Text("默认关闭：这是应急按钮，多一步确认就慢一拍。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }

        SectionCard(title: "快捷键", subtitle: nil, symbol: "keyboard") {
            HStack(spacing: 12) {
                HotkeyRecorderField()
                Spacer()
            }
        }

        SectionCard(
            title: "选定的应用",
            subtitle: engine.targets.isEmpty
                ? "还没有选定任何应用。按下快捷键或点「立即退出全部」时不会结束任何东西。"
                : nil,
            symbol: "app.dashed"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if engine.targets.isEmpty {
                    Text("名单为空")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(engine.targets) { target in
                        HStack(spacing: 10) {
                            Image(systemName: "app")
                                .frame(width: 20)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(target.name).font(.body.weight(.medium))
                                Text(target.bundleIdentifier)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Tag(text: engine.isRunning(target) ? "运行中" : "未运行",
                                color: engine.isRunning(target) ? .green : .secondary)
                            Button(role: .destructive) {
                                engine.remove(target)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        if target.id != engine.targets.last?.id {
                            Divider()
                        }
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Button {
                        showPicker = true
                    } label: {
                        Label("添加应用", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)

                    if !engine.targets.isEmpty {
                        Button(role: .destructive) {
                            engine.removeAll()
                        } label: {
                            Label("清空名单", systemImage: "trash")
                        }
                    }

                    Spacer()
                }
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

        SectionCard(
            title: "不会结束的进程",
            subtitle: "以下进程（以及位于它们子树内的进程）永远不会被结束，名单是硬编码的，任何开关都绕不过。",
            symbol: "hand.raised",
            accent: .orange
        ) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(QuickQuitEngine.protectedDisplayList, id: \.self) { item in
                    Text("· \(item)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("另外：pid 1（launchd）、内核任务、以及 Deep Sleep 自己一律拒绝。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
            }
        }

        if let outcome = engine.lastOutcome {
            SectionCard(
                title: outcome.dryRun ? "最近一次演练" : "最近一次结果",
                subtitle: "\(Self.formatter.string(from: outcome.date))，触发方式：\(outcome.usedHelper ? "特权助手" : "本进程权限")",
                symbol: "list.bullet.clipboard",
                accent: outcome.report.isClean ? .green : .orange
            ) {
                VStack(alignment: .leading, spacing: 5) {
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
        HStack(spacing: 12) {
            Text(engine.hotkey.displayText)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))

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
        VStack(alignment: .leading, spacing: 14) {
            Text("选择要加入快速退出名单的应用")
                .font(.title3.weight(.semibold))
            Text("列表包含正在运行的应用与常见安装位置里的应用；受保护的系统应用不在其中。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("搜索", text: $query)
                .textFieldStyle(.roundedBorder)

            List(filtered) { candidate in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(candidate.name).font(.body)
                        Text(candidate.bundleIdentifier)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if candidate.isRunning {
                        Tag(text: "运行中", color: .green)
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
        .padding(22)
        .frame(width: 520, height: 470)
    }
}
