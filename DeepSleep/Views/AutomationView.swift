//
//  AutomationView.swift
//  Deep Sleep
//
//  自动化页：用规则描述「什么条件下自动保持清醒」。
//
//  2026-11 界面换新：
//  - 规则列表每条压成一行（条件摘要 + 动作 + 开关），不再一条一摞。
//  - 新建 / 编辑规则走 sheet（detail 列没有 NavigationStack，不能用推栈）。
//  - 条件编辑器里的时间窗用原生 DatePicker。
//  - 空态用 EmptyStateView。
//  - 间距 / 圆角一律走 `DS.Space` / `DS.Radius`，不写字面量。
//
//  业务逻辑不变：规则求值仍是每 5 秒一次，定时命令的触发方式也没动。
//

import SwiftUI

struct AutomationView: View {

    @EnvironmentObject private var controller: SleepController
    @State private var showEditor = false
    @State private var editingRule: AutomationRule?
    @State private var weeklyRestartConfig: WeeklyRestartManager.Config = WeeklyRestartManager.shared.current

    @State private var showScheduledEditor = false
    @State private var editingScheduled: ScheduledCommand.Entry?

    private var engine: AutomationEngine { controller.automation }
    private var runningApps: [(bundleIdentifier: String, name: String)] {
        AppRestartWatcher.runningApplications()
    }

    private var restartWatcherSubtitle: String {
        let count = AppRestartWatcher.shared.allTargets.count
        if count == 0 { return "没有目标应用。退出 Deep Sleep 后该监听会失效。" }
        return "已配置 \(count) 个目标应用；只要 Deep Sleep 在跑，被监听的应用退出后会自动按命令重启。"
    }

    private var weeklyRestartSubtitle: String {
        if weeklyRestartConfig.enabled {
            let day = WeeklyRestartManager.shared.weekdayName(weeklyRestartConfig.weekday)
            let time = String(format: "%02d:%02d", weeklyRestartConfig.hour, weeklyRestartConfig.minute)
            return "已启用：每周\(day) \(time) 自动重启 Mac。"
        }
        return "未启用。重启需要 root 权限，需要先启用完全控制才能写入 sudoers 配置。"
    }

    private var scheduledCommandSubtitle: String {
        let count = ScheduledCommand.shared.allEntries.count
        if count == 0 {
            return "还没有定时命令。点「新建定时命令」配置一个。"
        }
        let enabled = ScheduledCommand.shared.allEntries.filter(\.isEnabled).count
        return "共 \(count) 条，启用 \(enabled) 条。命令以当前用户身份运行，Deep Sleep 退出后失效。"
    }

    /// 每周重启的时刻 —— 用原生 DatePicker 显示，底层仍是 hour / minute 两个整数。
    private var weeklyRestartTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: weeklyRestartConfig.hour,
                                      minute: weeklyRestartConfig.minute,
                                      second: 0,
                                      of: Date()) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                weeklyRestartConfig.hour = parts.hour ?? 0
                weeklyRestartConfig.minute = parts.minute ?? 0
                WeeklyRestartManager.shared.current = weeklyRestartConfig
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            engineCard
            rulesCard
            ruleAssertionsCard
            scheduledCommandCard
            weeklyRestartCard
            restartWatcherCard
            siriCard
        }
        .sheet(isPresented: $showEditor) {
            RuleEditorView(rule: editingRule) { rule in
                if editingRule == nil {
                    engine.add(rule)
                } else {
                    engine.update(rule)
                }
                editingRule = nil
                showEditor = false
            } onCancel: {
                editingRule = nil
                showEditor = false
            }
        }
        .sheet(isPresented: $showScheduledEditor) {
            if let entry = editingScheduled {
                ScheduledCommandEditor(entry: entry) { saved in
                    ScheduledCommand.shared.upsert(saved)
                    editingScheduled = nil
                    showScheduledEditor = false
                } onCancel: {
                    editingScheduled = nil
                    showScheduledEditor = false
                }
            }
        }
    }

    // MARK: - 引擎状态

    private var engineCard: some View {
        SectionCard(
            title: "自动化引擎",
            subtitle: "每 5 秒检查一次规则，条件成立就自动保持，条件失效自动释放。",
            symbol: "wand.and.stars",
            accessory: AnyView(
                StatusPill(
                    text: engine.isRunning ? "运行中" : "已停止",
                    isActive: engine.isRunning,
                    color: engine.isRunning ? DS.Tone.good : DS.Tone.idle
                )
            )
        ) {
            HStack(spacing: DS.Space.sm) {
                StatusPill(
                    text: "\(engine.satisfiedRuleIDs.count) / \(engine.rules.count) 条规则条件成立",
                    isActive: !engine.satisfiedRuleIDs.isEmpty,
                    color: engine.satisfiedRuleIDs.isEmpty ? DS.Tone.idle : DS.Tone.good
                )
                Spacer(minLength: DS.Space.sm)
                Button {
                    engine.evaluate()
                } label: {
                    Label("立即评估", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - 规则列表

    private var rulesCard: some View {
        SectionCard(
            title: "规则",
            subtitle: engine.rules.isEmpty ? nil : "每条规则一个条件 + 一个动作；条件成立时自动申请保持状态。",
            symbol: "list.bullet.rectangle",
            accessory: AnyView(
                Button {
                    editingRule = nil
                    showEditor = true
                } label: {
                    Label("新建规则", systemImage: "plus")
                }
            )
        ) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                if engine.rules.isEmpty {
                    EmptyStateView(
                        title: "还没有规则",
                        message: "新建一条自定义规则，或者从模板快速开始。",
                        systemImage: "list.bullet.rectangle",
                        actionTitle: "新建规则"
                    ) {
                        editingRule = nil
                        showEditor = true
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(engine.rules) { rule in
                            RuleRow(
                                rule: rule,
                                isSatisfied: engine.satisfiedRuleIDs.contains(rule.id),
                                onToggle: { engine.toggleEnabled(rule) },
                                onEdit: {
                                    editingRule = rule
                                    showEditor = true
                                },
                                onDelete: { engine.remove(rule) }
                            )
                            if rule.id != engine.rules.last?.id {
                                Divider()
                            }
                        }
                    }
                    .insetPanel()
                }

                HStack(spacing: DS.Space.sm) {
                    Menu {
                        ForEach(Array(RuleTemplate.all().enumerated()), id: \.offset) { _, template in
                            Button(template.name) {
                                var rule = template
                                rule.id = UUID()
                                rule.isEnabled = false
                                engine.add(rule)
                            }
                        }
                    } label: {
                        Label("从模板添加", systemImage: "square.on.square")
                    }

                    Spacer(minLength: DS.Space.sm)
                }
            }
        }
    }

    // MARK: - 规则驱动的保持项

    private var ruleAssertionsCard: some View {
        SectionCard(
            title: "规则生效的保持项",
            subtitle: "这些状态由规则维持，关掉规则才会释放。在总览页手动关会被拒绝。",
            symbol: "lock.circle"
        ) {
            if controller.ruleAssertions.isEmpty {
                EmptyStateView(
                    title: "当前没有规则在维持保持状态",
                    message: "规则条件成立时，申请到的保持状态会列在这里。",
                    systemImage: "lock.circle"
                )
            } else {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    ForEach(controller.ruleAssertions.sorted { $0.rawValue < $1.rawValue }) { kind in
                        HStack(spacing: DS.Space.sm) {
                            Image(systemName: kind.symbolName)
                                .foregroundStyle(DS.Tone.info)
                                .frame(width: DS.Space.xl)
                            Text(kind.title)
                                .font(.body)
                            Spacer(minLength: DS.Space.sm)
                        }
                    }
                }
                .insetPanel()
            }
        }
    }

    // MARK: - 定时命令

    private var scheduledCommandCard: some View {
        SectionCard(
            title: "定时执行终端命令",
            subtitle: scheduledCommandSubtitle,
            symbol: "terminal",
            accessory: AnyView(
                Button {
                    editingScheduled = ScheduledCommand.Entry(
                        id: UUID(),
                        name: "",
                        command: "",
                        cron: "0 * * * *",
                        isEnabled: true,
                        lastRunAt: nil
                    )
                    showScheduledEditor = true
                } label: {
                    Label("新建定时命令", systemImage: "plus")
                }
            )
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Label(
                    "命令以当前用户身份运行，不走特权助手。退出 Deep Sleep 后定时任务失效。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(DS.Tone.caution)

                if ScheduledCommand.shared.allEntries.isEmpty {
                    EmptyStateView(
                        title: "还没有定时命令",
                        message: "用 cron 表达式描述时间，到点就在终端里执行你写的命令。",
                        systemImage: "terminal",
                        actionTitle: "新建定时命令"
                    ) {
                        editingScheduled = ScheduledCommand.Entry(
                            id: UUID(),
                            name: "",
                            command: "",
                            cron: "0 * * * *",
                            isEnabled: true,
                            lastRunAt: nil
                        )
                        showScheduledEditor = true
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(ScheduledCommand.shared.allEntries) { entry in
                            PlScheduledCommandRow(entry: entry) { isEnabled in
                                var e = entry
                                e.isEnabled = isEnabled
                                ScheduledCommand.shared.upsert(e)
                            } onDelete: {
                                ScheduledCommand.shared.remove(id: entry.id)
                            }
                            if entry.id != ScheduledCommand.shared.allEntries.last?.id {
                                Divider()
                            }
                        }
                    }
                    .insetPanel()
                }
            }
        }
    }

    // MARK: - 每周重启

    private var weeklyRestartCard: some View {
        SectionCard(
            title: "每周定时重启 Mac",
            subtitle: weeklyRestartSubtitle,
            symbol: "clock.arrow.circlepath"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Toggle(isOn: Binding(
                    get: { weeklyRestartConfig.enabled },
                    set: { newValue in
                        weeklyRestartConfig.enabled = newValue
                        WeeklyRestartManager.shared.current = weeklyRestartConfig
                        Task {
                            let result = await WeeklyRestartManager.shared.apply()
                            switch result {
                            case .success(let msg):
                                SleepController.shared.appendLog(msg)
                            case .failure(let reason):
                                SleepController.shared.appendLog(
                                    "周重启配置失败：\(reason)", isError: true
                                )
                            }
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("启用").font(.body.weight(.medium))
                        Text("到点会直接重启 Mac，届时请先保存工作。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if weeklyRestartConfig.enabled {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        LabeledContent("星期") {
                            Picker("", selection: Binding(
                                get: { weeklyRestartConfig.weekday },
                                set: { newValue in
                                    weeklyRestartConfig.weekday = newValue
                                    WeeklyRestartManager.shared.current = weeklyRestartConfig
                                }
                            )) {
                                ForEach(0..<7, id: \.self) { idx in
                                    Text(WeeklyRestartManager.shared.weekdayName(idx))
                                        .tag(idx)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        LabeledContent("时刻") {
                            DatePicker("", selection: weeklyRestartTime, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }
                    .insetPanel()

                    if !controller.helperState.isReady {
                        Label("需要先启用完全控制（写入 /etc/sudoers.d 需要 root）",
                              systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(DS.Tone.caution)
                    }
                }
            }
        }
    }

    // MARK: - 应用退出即重启

    private var restartWatcherCard: some View {
        SectionCard(
            title: "应用退出即重启",
            subtitle: restartWatcherSubtitle,
            symbol: "arrow.clockwise.circle"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                if AppRestartWatcher.shared.allTargets.isEmpty {
                    EmptyStateView(
                        title: "还没有监听目标",
                        message: "从正在运行的应用里挑一个，被监听的应用退出后会自动按命令重启。",
                        systemImage: "arrow.clockwise.circle"
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(AppRestartWatcher.shared.allTargets) { target in
                            PlRestartTargetRow(target: target) { isEnabled in
                                var t = target
                                t.isEnabled = isEnabled
                                AppRestartWatcher.shared.upsert(t)
                            } onDelete: {
                                AppRestartWatcher.shared.remove(id: target.id)
                            }
                            if target.id != AppRestartWatcher.shared.allTargets.last?.id {
                                Divider()
                            }
                        }
                    }
                    .insetPanel()
                }

                HStack {
                    Menu {
                        ForEach(runningApps, id: \.bundleIdentifier) { app in
                            Button(app.name) {
                                var t = AppRestartWatcher.Target(
                                    bundleIdentifier: app.bundleIdentifier,
                                    displayName: app.name,
                                    command: "",
                                    isEnabled: true
                                )
                                t.id = UUID()
                                AppRestartWatcher.shared.upsert(t)
                            }
                        }
                    } label: {
                        Label("从正在运行的应用选择", systemImage: "plus")
                    }
                    .disabled(runningApps.isEmpty)

                    Spacer(minLength: DS.Space.sm)

                    Text("退出 Deep Sleep 后该监听会失效。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Siri

    private var siriCard: some View {
        SectionCard(
            title: "Siri 与快捷指令",
            subtitle: "下面这些句子可以直接对 Siri 说；「快捷指令」App 的 Deep Sleep 分区里有同样的动作，可以编进更长的流程。",
            symbol: "mic"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                ForEach(DeepSleepShortcutCatalog.entries) { entry in
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Label(entry.title, systemImage: entry.symbol)
                            .font(.body.weight(.medium))
                        Text(entry.phrases
                                .map { DeepSleepShortcutCatalog.spoken($0) }
                                .joined(separator: "　·　"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                Text("自动操作、AppleScript 与 shell 脚本走 deepsleep:// 命令；`--automation` 能打印完整清单。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                // 用 Link 打开「快捷指令」而不是 AppIntents 的 ShortcutsLink：
                // 后者在 macOS 的 AppIntents 模块里并不存在（只在 iOS 侧提供），
                // 系统自带的 URL scheme 两边都能用。
                Link(destination: URL(string: "shortcuts://")!) {
                    Label("打开「快捷指令」", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - 规则行

/// 一条规则压成一行：条件摘要 + 动作 + 开关。
struct RuleRow: View {
    let rule: AutomationRule
    let isSatisfied: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: rule.trigger.symbolName)
                .font(.system(size: 13))
                .frame(width: DS.Space.xl)
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(rule.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DS.Space.sm)

            Tag(text: statusText, color: statusColor)

            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑这条规则")

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除这条规则")
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
    }

    /// 「条件 → 动作」的一行摘要。
    private var detailText: String {
        var text = "\(rule.trigger.displayName) → \(rule.summary)"
        if rule.notifyOnSatisfied {
            text += "（触发时发邮件）"
        }
        return text
    }

    /// 状态用「颜色 + 文字」双编码。
    private var statusText: String {
        if !rule.isEnabled { return "已停用" }
        return isSatisfied ? "条件成立" : "条件未成立"
    }

    private var statusColor: Color {
        if !rule.isEnabled { return DS.Tone.idle }
        return isSatisfied ? DS.Tone.good : DS.Tone.idle
    }

    private var iconColor: Color {
        if !rule.isEnabled { return DS.Tone.idle }
        return isSatisfied ? DS.Tone.good : DS.Tone.info
    }
}

// MARK: - 定时命令行

/// 一条定时命令的紧凑行。
struct PlScheduledCommandRow: View {

    let entry: ScheduledCommand.Entry
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(entry.name.isEmpty ? "未命名命令" : entry.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(entry.cron)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(entry.command)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let last = entry.lastRunAt {
                    Text("上次执行：\(Self.formatTimestamp(last))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: DS.Space.sm)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除这条定时命令")
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}

// MARK: - 重启监听行

/// 一条「应用退出即重启」的紧凑行。
struct PlRestartTargetRow: View {

    let target: AppRestartWatcher.Target
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Toggle("", isOn: Binding(
                get: { target.isEnabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(target.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(target.bundleIdentifier)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: DS.Space.sm)

            Text(target.resolvedCommand)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除这个监听目标")
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
    }
}

// MARK: - 规则编辑器

struct RuleEditorView: View {

    let rule: AutomationRule?
    let onSave: (AutomationRule) -> Void
    let onCancel: () -> Void

    private enum TriggerType: String, CaseIterable, Identifiable {
        case time, power, app
        var id: String { rawValue }
        var title: String {
            switch self {
            case .time:  return "时间段"
            case .power: return "电源状态"
            case .app:   return "应用运行中"
            }
        }
    }

    @State private var name: String = ""
    @State private var triggerType: TriggerType = .time
    @State private var startTime: Date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var endTime: Date = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var onAC: Bool = true
    @State private var selectedApp: String = ""
    @State private var selectedAssertions: Set<AssertionKind> = [.preventIdleSystemSleep]
    @State private var notifyOnSatisfied: Bool = false

    private var applications: [(bundleIdentifier: String, name: String)] {
        AutomationEngine.runningApplications()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(rule == nil ? "新建自动化规则" : "编辑自动化规则")
                .font(.title3.weight(.semibold))

            LabeledContent("规则名称") {
                TextField("例如：工作时间保持在线", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                SubsectionHeader(title: "触发条件", symbol: "target")
                Picker("", selection: $triggerType) {
                    ForEach(TriggerType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            triggerConfiguration

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                SubsectionHeader(title: "动作（条件成立时要保持的状态）", symbol: "bolt")
                VStack(spacing: DS.Space.sm) {
                    ForEach(AssertionKind.allCases) { kind in
                        Toggle(isOn: Binding(
                            get: { selectedAssertions.contains(kind) },
                            set: { isOn in
                                if isOn { selectedAssertions.insert(kind) }
                                else { selectedAssertions.remove(kind) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                Text(kind.title).font(.body)
                                Text(kind.subtitle).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
                .insetPanel()
            }

            Divider()

            Toggle(isOn: $notifyOnSatisfied) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("触发时发邮件").font(.body)
                    Text("规则从未满足变为满足时，发一封邮件到「完全控制」页配置的收件人。需要邮件告警渠道已配置好。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(rule == nil ? "添加" : "保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || selectedAssertions.isEmpty
                              || (triggerType == .app && selectedApp.isEmpty))
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 520)
        .onAppear(perform: loadExisting)
    }

    @ViewBuilder
    private var triggerConfiguration: some View {
        switch triggerType {
        case .time:
            VStack(alignment: .leading, spacing: DS.Space.md) {
                VStack(spacing: DS.Space.sm) {
                    LabeledContent("开始") {
                        DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                    LabeledContent("结束") {
                        DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }
                .insetPanel()

                Text("结束时间早于开始时间表示跨零点（例如 22:00–06:00）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    SubsectionHeader(title: "重复", symbol: "calendar")
                    // Calendar: 1=周日 … 7=周六 → 内部用 0=周日 … 6=周六
                    PlWeekdaySelector(selected: $weekdays, firstIndex: 0)
                }
            }
        case .power:
            Picker("", selection: $onAC) {
                Text("接入电源时").tag(true)
                Text("使用电池时").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        case .app:
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                if applications.isEmpty {
                    Text("没有检测到正在运行的常规应用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $selectedApp) {
                        Text("请选择应用").tag("")
                        ForEach(applications, id: \.bundleIdentifier) { app in
                            Text(app.name).tag(app.bundleIdentifier)
                        }
                    }
                    .labelsHidden()
                }
                Text("只列出当前正在运行的应用。规则保存后按 bundle id 匹配，与应用启动顺序无关。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func loadExisting() {
        guard let rule else {
            if name.isEmpty { name = defaultName() }
            return
        }
        name = rule.name
        selectedAssertions = rule.assertions
        notifyOnSatisfied = rule.notifyOnSatisfied
        switch rule.trigger {
        case .timeWindow(let start, let end, let days):
            triggerType = .time
            weekdays = days
            startTime = Self.date(fromMinutes: start)
            endTime = Self.date(fromMinutes: end)
        case .powerSource(let ac):
            triggerType = .power
            onAC = ac
        case .appRunning(let bundleIdentifier, _):
            triggerType = .app
            selectedApp = bundleIdentifier
        }
    }

    private func defaultName() -> String {
        switch triggerType {
        case .time:  return "时间段保持"
        case .power: return onAC ? "接电源时保持" : "电池时保持"
        case .app:   return "应用运行时保持"
        }
    }

    private func save() {
        let trigger: RuleTrigger
        switch triggerType {
        case .time:
            trigger = .timeWindow(
                startMinutes: Self.minutes(from: startTime),
                endMinutes: Self.minutes(from: endTime),
                weekdays: weekdays
            )
        case .power:
            trigger = .powerSource(onAC: onAC)
        case .app:
            let display = applications.first { $0.bundleIdentifier == selectedApp }?.name ?? selectedApp
            trigger = .appRunning(bundleIdentifier: selectedApp, displayName: display)
        }

        let result = AutomationRule(
            id: rule?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            isEnabled: rule?.isEnabled ?? true,
            trigger: trigger,
            assertions: selectedAssertions,
            notifyOnSatisfied: notifyOnSatisfied
        )
        onSave(result)
    }

    private static func minutes(from date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private static func date(fromMinutes minutes: Int) -> Date {
        let hour = max(0, min(23, minutes / 60))
        let minute = max(0, min(59, minutes % 60))
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
}

// MARK: - 定时命令编辑器

struct ScheduledCommandEditor: View {

    let entry: ScheduledCommand.Entry
    let onSave: (ScheduledCommand.Entry) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var command: String = ""
    @State private var cron: String = "0 * * * *"
    @State private var isEnabled: Bool = true
    @State private var validationError: String?

    private static let presets: [(label: String, value: String)] = [
        ("每小时整点", "0 * * * *"),
        ("每 30 分钟", "*/30 * * * *"),
        ("每天 0 点", "0 0 * * *"),
        ("每天 3:30", "30 3 * * *"),
        ("每周一 9:00", "0 9 * * 1"),
        ("每月 1 号 4:00", "0 4 1 * *")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("定时执行终端命令")
                .font(.title3.weight(.semibold))

            LabeledContent("名称") {
                TextField("如：清理下载目录", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("命令（以当前用户身份跑）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("/bin/sh 风格的命令字符串", text: $command, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("cron 表达式（5 字段：分 时 日 月 周）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("* * * * *", text: $cron)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: cron) { _, _ in validateCron() }
                HStack(spacing: DS.Space.xs) {
                    ForEach(Self.presets, id: \.value) { preset in
                        Button(preset.label) {
                            cron = preset.value
                            validateCron()
                        }
                        .controlSize(.mini)
                    }
                }
                if let err = validationError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(DS.Tone.critical)
                }
            }

            Toggle(isOn: $isEnabled) {
                Text("启用").font(.body)
            }
            .toggleStyle(.switch)

            Label(
                "命令以当前用户身份运行，没有沙箱。写错 `rm -rf /` 真的会删。请先在终端试跑。",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(DS.Tone.caution)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 520)
        .onAppear { loadExisting() }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespaces).isEmpty
            && validationError == nil
    }

    private func loadExisting() {
        name = entry.name
        command = entry.command
        cron = entry.cron.isEmpty ? "0 * * * *" : entry.cron
        isEnabled = entry.isEnabled
        validateCron()
    }

    private func validateCron() {
        switch ScheduledCommand.validate(cron) {
        case .success:
            validationError = nil
        case .failure(let reason):
            validationError = reason.description
        }
    }

    private func save() {
        let saved = ScheduledCommand.Entry(
            id: entry.id,
            name: name.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespaces),
            cron: cron.trimmingCharacters(in: .whitespaces),
            isEnabled: isEnabled,
            lastRunAt: entry.lastRunAt
        )
        onSave(saved)
    }
}
