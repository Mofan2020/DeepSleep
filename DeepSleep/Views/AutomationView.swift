//
//  AutomationView.swift
//  Deep Sleep
//
//  自动化页：用规则描述「什么条件下自动保持清醒」。
//

import SwiftUI

struct AutomationView: View {

    @EnvironmentObject private var controller: SleepController
    @State private var showEditor = false
    @State private var editingRule: AutomationRule?

    private var engine: AutomationEngine { controller.automation }

    var body: some View {
        SectionCard(
            title: "自动化引擎",
            subtitle: "每 5 秒评估一次全部规则；条件成立时自动申请对应的保持状态，条件失效后自动释放。",
            symbol: "wand.and.stars",
            accent: .purple
        ) {
            HStack(spacing: 10) {
                StatusPill(text: engine.isRunning ? "运行中" : "已停止", isActive: engine.isRunning)
                StatusPill(
                    text: "\(engine.satisfiedRuleIDs.count) / \(engine.rules.count) 条规则条件成立",
                    isActive: !engine.satisfiedRuleIDs.isEmpty
                )
                Spacer()
                Button {
                    engine.evaluate()
                } label: {
                    Label("立即评估", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
        }

        SectionCard(
            title: "规则",
            subtitle: engine.rules.isEmpty ? "还没有规则。可以从下方模板快速开始，或新建自定义规则。" : nil,
            symbol: "list.bullet.rectangle"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if engine.rules.isEmpty {
                    Text("暂无规则")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
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

                Divider()

                HStack(spacing: 10) {
                    Button {
                        editingRule = nil
                        showEditor = true
                    } label: {
                        Label("新建规则", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)

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
                    .frame(width: 160)

                    Spacer()
                }
            }
        }

        SectionCard(
            title: "规则生效的保持项",
            subtitle: "这些保持状态由规则驱动，关闭规则才会释放；在总览页手动关闭会被拒绝。",
            symbol: "lock.circle"
        ) {
            if controller.ruleAssertions.isEmpty {
                Text("当前没有规则在维持保持状态")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.ruleAssertions.sorted { $0.rawValue < $1.rawValue }) { kind in
                        HStack(spacing: 8) {
                            Image(systemName: kind.symbolName)
                                .foregroundStyle(Color.purple)
                                .frame(width: 20)
                            Text(kind.title).font(.body)
                            Spacer()
                        }
                    }
                }
            }
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
    }
}

// MARK: - 规则行

struct RuleRow: View {
    let rule: AutomationRule
    let isSatisfied: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: rule.trigger.symbolName)
                .font(.system(size: 15))
                .frame(width: 24)
                .foregroundStyle(rule.isEnabled ? (isSatisfied ? Color.purple : Color.accentColor) : Color.secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.name).font(.body.weight(.medium))
                    if isSatisfied && rule.isEnabled {
                        Tag(text: "条件成立", color: .purple)
                    }
                    if !rule.isEnabled {
                        Tag(text: "已停用", color: .secondary)
                    }
                }
                Text(rule.trigger.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("动作：\(rule.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
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

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 3)
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

    private var applications: [(bundleIdentifier: String, name: String)] {
        AutomationEngine.runningApplications()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(rule == nil ? "新建自动化规则" : "编辑自动化规则")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("规则名称").font(.caption).foregroundStyle(.secondary)
                TextField("例如：工作时间保持在线", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("触发条件").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $triggerType) {
                    ForEach(TriggerType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            triggerConfiguration

            VStack(alignment: .leading, spacing: 6) {
                Text("动作（条件成立时要保持的状态）").font(.caption).foregroundStyle(.secondary)
                ForEach(AssertionKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { selectedAssertions.contains(kind) },
                        set: { isOn in
                            if isOn { selectedAssertions.insert(kind) }
                            else { selectedAssertions.remove(kind) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.title).font(.body)
                            Text(kind.subtitle).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }

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
        .padding(22)
        .frame(width: 480)
        .onAppear(perform: loadExisting)
    }

    @ViewBuilder
    private var triggerConfiguration: some View {
        switch triggerType {
        case .time:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    DatePicker("开始", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("结束", selection: $endTime, displayedComponents: .hourAndMinute)
                }
                Text("结束时间早于开始时间表示跨零点（例如 22:00–06:00）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text("重复").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { weekday in
                            // Calendar: 1=周日 … 7=周六 → 内部用 0=周日 … 6=周六
                            let dayIndex = weekday - 1
                            let isOn = weekdays.contains(dayIndex)
                            Button {
                                if isOn { weekdays.remove(dayIndex) } else { weekdays.insert(dayIndex) }
                            } label: {
                                Text(RuleTrigger.weekdayName(dayIndex))
                                    .font(.caption.weight(.medium))
                                    .frame(width: 34, height: 26)
                                    .background(
                                        isOn ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    )
                                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
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
            VStack(alignment: .leading, spacing: 6) {
                if applications.isEmpty {
                    Text("没有检测到正在运行的常规应用").font(.caption).foregroundStyle(.secondary)
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
            assertions: selectedAssertions
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
