//
//  AlertRulesView.swift
//  Deep Sleep
//
//  自定义告警规则页：用户自己定义「什么条件下告警、告警到哪去」。
//
//  与「系统监控」页的分工：监控页是固定的几组阈值，改不动；这一页是用户
//  自己加的规则列表，可任意增删改。两者用同一套底层采样数据，互不覆盖。
//
//  持续时间不是装饰：温度短暂冲高、CPU 偶发峰值都不该报警。规则必须连续
//  满足条件超过这个秒数才触发，掉回条件内就重新计时。
//
//  AlertRuleEngine 是普通类（不是 ObservableObject），规则读不到变化通知，
//  所以这里用本地副本 —— 每次改动后从引擎重新读一次，界面才会跟着变。
//

import SwiftUI

struct AlertRulesView: View {

    @ObservedObject var engine: AlertRuleEngine

    @State private var editingRule: AlertRule?
    @State private var isCreating: Bool = false
    @State private var firings: [AlertTrigger] = []
    @State private var observerToken: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            rulesCard
            if !firings.isEmpty {
                recentCard
            }
            notesCard
            Spacer(minLength: 0)
        }
        .pageLayout()
        .onAppear {
            // 用观察者而不是 `engine.onTrigger` —— 那个闭包归监控协调器管，
            // 负责派发系统通知与邮件。界面这里只需要记一条历史。
            if observerToken == nil {
                observerToken = engine.addTriggerObserver { trigger in
                    firings.insert(trigger, at: 0)
                    if firings.count > 20 { firings.removeLast() }
                }
            }
        }
        .onDisappear {
            if let token = observerToken {
                engine.removeTriggerObserver(token)
                observerToken = nil
            }
        }
        .sheet(item: $editingRule) { rule in
            AlertRuleEditorSheet(rule: rule) { updated in
                engine.update(updated)
                editingRule = nil
            } onCancel: {
                editingRule = nil
            }
        }
        .sheet(isPresented: $isCreating) {
            AlertRuleEditorSheet(rule: nil) { created in
                engine.add(created)
                isCreating = false
            } onCancel: {
                isCreating = false
            }
        }
    }

    // MARK: - 规则列表

    private var rulesCard: some View {
        SectionCard(
            title: "告警规则",
            subtitle: "条件连续满足设定时长才触发，掉回条件内即重新计时。",
            symbol: "bell.badge",
            accent: .purple
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(engine.rules.isEmpty ? "还没有规则" : "共 \(engine.rules.count) 条规则")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        isCreating = true
                    } label: {
                        Label("新建规则", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if engine.rules.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("常见用法：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        BulletLine("CPU 温度高于 85°C 持续 30 秒 → 通知")
                        BulletLine("单进程内存高于 8GB 持续 60 秒 → 通知 + 邮件")
                        BulletLine("磁盘使用率高于 90% 持续 300 秒 → 通知")
                    }
                    .padding(.top, 4)
                } else {
                    ForEach(engine.rules) { rule in
                        ruleRow(rule)
                        if rule.id != engine.rules.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func ruleRow(_ rule: AlertRule) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { newValue in
                    engine.setEnabled(newValue, for: rule.id)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.callout)
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                Text(conditionText(rule))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Tag(text: rule.action.displayName, color: .purple)

            Button {
                editingRule = rule
            } label: {
                Image(systemName: "pencil")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("编辑")

            Button {
                engine.remove(id: rule.id)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("删除")
        }
        .padding(.vertical, 4)
    }

    private func conditionText(_ rule: AlertRule) -> String {
        let threshold = rule.metric == .singleProcessRAMGB
            ? String(format: "%.1f", rule.threshold)
            : String(format: "%.0f", rule.threshold)
        return "\(rule.metric.displayName) \(rule.operator.displayName) \(threshold)\(rule.metric.unit)"
             + " · 持续 \(rule.durationSeconds) 秒"
    }

    // MARK: - 触发记录

    private var recentCard: some View {
        SectionCard(
            title: "最近的触发",
            subtitle: nil,
            symbol: "clock.arrow.circlepath",
            accent: .orange
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(firings.prefix(8).enumerated()), id: \.offset) { _, firing in
                    HStack(spacing: 8) {
                        Image(systemName: "bell.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(firing.rule.name)
                            .font(.callout)
                        Text(String(format: "%.1f", firing.observedValue) + firing.rule.metric.unit)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(firing.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var notesCard: some View {
        SectionCard(
            title: "说明",
            symbol: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: 7) {
                BulletLine("规则只做告警，不会结束进程 —— 温度与内存类阈值下杀进程容易误伤。")
                BulletLine("选择邮件动作前需先配置好发信账号，否则邮件那一份发不出去。")
                BulletLine("同一规则在条件持续满足期间只触发一次，回到条件内才重新武装。")
                BulletLine("这些规则与「系统监控」页的固定阈值相互独立，两者都生效。")
                BulletLine("温度阈值可以设到 90°C 以上。90°C 兜底只管风扇转速，不管告警 —— "
                          + "温度到了就该报，兜底把风扇拉满是另一回事。")
            }
        }
    }
}

// MARK: - 规则编辑

struct AlertRuleEditorSheet: View {
    @State private var draft: AlertRule
    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    let onSave: (AlertRule) -> Void
    let onCancel: () -> Void

    init(rule: AlertRule?, onSave: @escaping (AlertRule) -> Void, onCancel: @escaping () -> Void) {
        let initial = rule ?? AlertRule(
            name: "",
            metric: .cpuTemperature,
            comparison: .greaterThan,
            threshold: 85,
            durationSeconds: 30,
            action: .notification
        )
        _draft = State(initialValue: initial)
        isNew = rule == nil
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "新建告警规则" : "编辑告警规则")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                labeledRow("名称") {
                    TextField("例如：CPU 过热", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }

                labeledRow("指标") {
                    Picker("", selection: $draft.metric) {
                        ForEach(AlertMetric.allCases, id: \.self) { metric in
                            Text(metric.displayName).tag(metric)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .onChange(of: draft.metric) { _, newValue in
                        // 单位不同的指标不能沿用旧阈值。
                        draft.threshold = defaultThreshold(for: newValue)
                    }
                }

                labeledRow("条件") {
                    HStack(spacing: 8) {
                        Picker("", selection: $draft.operator) {
                            ForEach(AlertOperator.allCases, id: \.self) { op in
                                Text(op.displayName).tag(op)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)

                        TextField("", value: $draft.threshold, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)

                        Text(draft.metric.unit).foregroundStyle(.secondary)
                    }
                }

                labeledRow("持续") {
                    HStack(spacing: 8) {
                        TextField("", value: $draft.durationSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("秒").foregroundStyle(.secondary)
                        ForEach([0, 30, 60, 300], id: \.self) { preset in
                            Button("\(preset)") { draft.durationSeconds = preset }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                }

                labeledRow("动作") {
                    Picker("", selection: $draft.action) {
                        ForEach(AlertAction.allCases, id: \.self) { action in
                            Text(action.displayName).tag(action)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            if let warning = validationWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(validationWarning != nil)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func labeledRow<Content: View>(_ title: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).frame(width: 52, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func defaultThreshold(for metric: AlertMetric) -> Double {
        switch metric {
        case .cpuPercent:         return 90
        case .ramPercent:         return 85
        case .singleProcessRAMGB: return 8
        case .cpuTemperature:     return 85
        case .diskUsagePercent:   return 90
        }
    }

    private var validationWarning: String? {
        // 校验放在模型上（AlertRule.validationError），这里只做展示。
        // 温度阈值不受 90°C 兜底限制 —— 兜底管的是风扇转速，不是告警。
        AlertRule.validationError(for: draft)
    }
}
