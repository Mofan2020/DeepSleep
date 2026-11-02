//
//  FanControlView.swift
//  Deep Sleep
//
//  风扇控制页：交给系统 / 固定转速 / 按规则调速。
//
//  两件必须先说清楚的事：
//
//  1. 免责声明。SMC 写入是非公开接口上的写操作，不同机型的风扇键名、
//     转速区间、模式键拼写都可能不同。未同意前，所有写入控件禁用。
//     同意状态持久化在 UserDefaults，并且会同步给助手 —— 助手侧还有一道
//     独立门禁，绕过界面直接发协议包也会被拒。
//
//  2. 90°C 兜底。任何规则、任何固定转速都不能压低它。触发时所有写入控件
//     禁用并显示原因，紧急态下连「交回系统」都不接受。
//
//  租约：转速写下去之后由助手按 15 秒租约维持。应用崩溃或被杀后助手
//  自动把风扇交回系统 —— 避免「写风扇的进程死了，风扇还停在低速」。
//
//  界面约定（2026 换新）：
//  - 三档模式用原生 Picker(.segmented)，不用自造分段控件。
//  - 转速滑杆区间永远来自 FanState.Fan 的实测 minRPM / maxRPM，不写死。
//  - 「固定转速」与「规则调速」要写 SMC，必须有特权助手；助手未就绪时
//    控件置灰，副标题说明原因，不能让用户以为改了就会生效。
//

import SwiftUI

struct FanControlView: View {

    @ObservedObject var controller: FanController
    /// 全局助手状态。固定转速与规则调速都靠它写 SMC，所以必须看得见。
    @EnvironmentObject private var sleepController: SleepController

    @State private var draftRPM: [Int: Double] = [:]
    @State private var ruleFanIndex: Int = 0
    @State private var ruleMinTemp: Double = 60
    @State private var ruleMaxTemp: Double = 85
    @State private var showDisclaimer: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if !controller.isDisclaimerAccepted {
                disclaimerCard
            }
            stallWarningCard
            masterCard
            if controller.fans.isEmpty {
                emptyCard
            } else {
                ForEach(controller.fans, id: \.index) { fan in
                    fanCard(fan)
                }
                ruleCard
            }
            emergencyCard
            Spacer(minLength: 0)
        }
        .pageLayout()
        .sheet(isPresented: $showDisclaimer) {
            FanDisclaimerSheet(
                onAccept: {
                    FanController.acceptDisclaimer()
                    showDisclaimer = false
                    Task { await controller.syncDisclaimerToHelper() }
                },
                onCancel: { showDisclaimer = false }
            )
        }
        .task { await controller.refreshFanState() }
        .onAppear { loadRuleFromController() }
    }

    // MARK: - 派生状态

    /// 特权助手是否就绪。写风扇转速要靠它，没就绪时界面必须说清楚。
    private var helperReady: Bool { sleepController.helperState.isReady }

    /// 助手未就绪时给用户看的一句话（总开关卡里说一次完整原因）。
    ///
    /// 三种模式最终都要助手写 SMC ——「交给系统」写的是 rpm=0 的模式键，
    /// 一样要助手。所以助手没就绪时写入控件全部置灰。完整原因只在这里
    /// 出现一次，风扇卡与规则卡的副标题只带一句短提示 —— 同一个原因
    /// 在一页里说三遍，用户只会觉得吵。
    private var helperUnavailableReason: String? {
        guard !helperReady else { return nil }
        switch sleepController.helperState {
        case .notInstalled:
            return "写入风扇需要特权助手：尚未启用「完全控制」，写风扇的指令发不出去。"
        case .unknown:
            return "写入风扇需要特权助手：正在与特权助手握手，稍候再试。"
        default:
            return "写入风扇需要特权助手：\(sleepController.helperState.detail)"
        }
    }

    /// 按钮旁的短提示。只说「缺什么」，不说原因 —— 原因在总开关卡里。
    private let helperUnavailableHint = "需要特权助手才能写入"

    /// 写入类控件的统一禁用条件。
    ///
    /// 「交给系统」不需要写转速，所以不在这条判定里；固定转速与规则调速
    /// 需要写 SMC，助手没就绪就写不进去。
    private var writesDisabled: Bool {
        !controller.isEnabled || controller.isEmergencyActive || !helperReady
    }

    /// 规则字段（目标风扇 / 两个温度）的禁用条件。
    ///
    /// 只有兜底接管时锁：兜底期间任何写入都不该发生。
    /// 助手未就绪**不**锁字段 —— 改字段只是改本地草稿，不写 SMC，
    /// 真正写的是「应用规则」按钮（那一个会置灰）。用户可以在助手恢复前
    /// 先把参数调好，助手一回来直接点应用。
    private var ruleFieldsDisabled: Bool {
        controller.isEmergencyActive
    }

    // MARK: - 免责声明

    private var disclaimerCard: some View {
        SectionCard(
            title: "使用风扇控制需先阅读免责声明",
            subtitle: "风扇转速通过 SMC 写入，属于苹果未公开的接口。同一条指令在不同机型上的表现可能不同。",
            symbol: "exclamationmark.shield",
            accent: DS.Tone.caution
        ) {
            Button {
                showDisclaimer = true
            } label: {
                Label("阅读全文并同意", systemImage: "checkmark.seal")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 总开关

    private var masterCard: some View {
        SectionCard(
            title: "风扇控制",
            subtitle: controller.isEnabled ? "手动模式：风扇转速由本应用接管。" : "关闭时风扇完全由系统管理。",
            symbol: "fan",
            accent: DS.Tone.info
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                LabeledContent {
                    Toggle("", isOn: Binding(
                        get: { controller.isEnabled },
                        set: { newValue in Task { await controller.setEnabled(newValue) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!controller.isDisclaimerAccepted || controller.isEmergencyActive)
                } label: {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("启用风扇控制")
                        Text("关闭时所有风扇立即交回系统自动控制。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = controller.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(DS.Tone.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if controller.isEmergencyActive {
                    Label("紧急降速中：温度已达 \(Int(FanControl.emergencyTemperatureCelsius))°C，"
                          + "风扇已强制最大转速，此处设置暂不生效。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DS.Tone.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let helperUnavailableReason {
                    Label(helperUnavailableReason,
                          systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(DS.Tone.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var emptyCard: some View {
        SectionCard(
            title: "风扇",
            subtitle: nil,
            symbol: "fan",
            accent: DS.Tone.idle
        ) {
            EmptyStateView(
                title: "没有检测到可控制的风扇",
                message: "可能是这台机器没有可读风扇，或特权助手尚未就绪。",
                systemImage: "fan"
            )
            .frame(minHeight: 120)
        }
    }

    // MARK: - 单个风扇

    private func fanCard(_ fan: FanState.Fan) -> some View {
        let mode = controller.modes[fan.index] ?? .automatic
        return SectionCard(
            title: fan.name.isEmpty ? "风扇 \(fan.index)" : fan.name,
            subtitle: fanSubtitle(fan),
            symbol: "fan.fill",
            accent: fan.isManual ? DS.Tone.caution : DS.Tone.info
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                MetricTile(
                    title: "当前转速",
                    value: "\(fan.currentRPM)",
                    unit: "RPM",
                    status: fan.isManual ? "手动控制中" : "系统自动控制",
                    tint: fan.isManual ? DS.Tone.caution : DS.Tone.idle,
                    symbol: "fan"
                )

                Picker("", selection: Binding(
                    get: { modeKind(mode) },
                    set: { kind in
                        Task { await applyMode(kind, fan: fan, currentMode: mode) }
                    }
                )) {
                    Text("交给系统").tag(ModeKind.automatic)
                    Text("固定转速").tag(ModeKind.fixed)
                    Text("规则调速").tag(ModeKind.rule)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // 三档最终都要助手写 SMC ——「交给系统」写的是 rpm=0 的
                // 模式键，一样要助手。所以助手没就绪时整组置灰：切过去以后
                // 控制器会把模式记下来并落盘，但风扇其实没被接管 ——
                // 界面看着生效、实际没生效，是最糟的反馈。
                // 助手恢复后这张卡自动可切。
                .disabled(!controller.isEnabled || controller.isEmergencyActive || !helperReady)

                switch mode {
                case .fixed(let rpm):
                    fixedEditor(fan: fan, rpm: rpm)
                case .rule(let target, let low, let high):
                    Text(String(format: "规则：风扇 %d，%.0f–%.0f°C",
                                target, low, high))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .automatic:
                    EmptyView()
                }
            }
        }
    }

    /// 风扇卡的副标题。助手未就绪时补一句短提示 —— 完整原因在总开关卡里。
    private func fanSubtitle(_ fan: FanState.Fan) -> String {
        let range = "区间 \(fan.minRPM)–\(fan.maxRPM) RPM"
        if helperUnavailableReason != nil {
            return "\(range) · \(helperUnavailableHint)"
        }
        return range
    }

    private func fixedEditor(fan: FanState.Fan, rpm: Int) -> some View {
        let floor = max(fan.minRPM, Int(Double(fan.minRPM) * FanControl.minRpmSafetyRatio))
        let ceiling = max(floor, fan.maxRPM)
        let binding = Binding<Double>(
            get: { draftRPM[fan.index] ?? Double(min(max(rpm, floor), ceiling)) },
            set: { draftRPM[fan.index] = $0 }
        )
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            LabeledContent("目标转速") {
                Text("\(Int(binding.wrappedValue)) RPM")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
            }
            // 滑杆区间来自该风扇实测的 minRPM / maxRPM，不写死：
            // 不同机型的可用区间差很多，写死就会出现拖到底也达不到的转速。
            Slider(value: binding, in: Double(floor)...Double(ceiling),
                   step: ceiling - floor > 4000 ? 10 : 1) { editing in
                if !editing {
                    Task { await applyFixed(fan: fan, rpm: Int(draftRPM[fan.index] ?? Double(rpm))) }
                }
            }
            .disabled(writesDisabled)

            HStack {
                Text("\(floor)")
                Spacer()
                Text("\(ceiling)")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if helperUnavailableReason != nil {
                Label(helperUnavailableHint, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(DS.Tone.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 规则调速

    private var ruleCard: some View {
        SectionCard(
            title: "规则调速参数",
            subtitle: ruleSubtitle,
            symbol: "slider.horizontal.below.rectangle",
            accent: DS.Tone.info
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                LabeledContent("目标风扇") {
                    Picker("", selection: $ruleFanIndex) {
                        ForEach(controller.fans, id: \.index) { fan in
                            Text(fan.name.isEmpty ? "风扇 \(fan.index)" : fan.name)
                                .tag(fan.index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(ruleFieldsDisabled)
                }

                LabeledContent("最低温度") {
                    HStack(spacing: DS.Space.sm) {
                        TextField("", value: $ruleMinTemp, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Stepper("", value: $ruleMinTemp, in: 20...88, step: 1).labelsHidden()
                        Text("°C").foregroundStyle(.secondary)
                    }
                    .disabled(ruleFieldsDisabled)
                }

                LabeledContent("最高温度") {
                    HStack(spacing: DS.Space.sm) {
                        TextField("", value: $ruleMaxTemp, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Stepper("", value: $ruleMaxTemp, in: 21...89, step: 1).labelsHidden()
                        Text("°C").foregroundStyle(.secondary)
                    }
                    .disabled(ruleFieldsDisabled)
                }

                if let warning = ruleWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(DS.Tone.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: DS.Space.md) {
                    Button {
                        Task { await applyRule() }
                    } label: {
                        Label("应用规则", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ruleWarning != nil || writesDisabled)

                    Spacer()
                }
            }
        }
    }

    /// 规则卡的副标题：助手未就绪时带一句短提示，否则不显示。
    /// 完整原因在总开关卡里说过一次，这里不重复。
    private var ruleSubtitle: String? {
        if helperUnavailableReason != nil {
            return helperUnavailableHint
        }
        return nil
    }

    private var ruleWarning: String? {
        if ruleMinTemp >= ruleMaxTemp {
            return "最低温度必须低于最高温度。"
        }
        if ruleMaxTemp >= FanControl.emergencyTemperatureCelsius {
            return "最高温度必须低于 \(Int(FanControl.emergencyTemperatureCelsius))°C。"
        }
        return nil
    }

    // MARK: - 兜底状态

    private var emergencyCard: some View {
        SectionCard(
            title: "安全兜底 · \(Int(FanControl.emergencyTemperatureCelsius))°C",
            subtitle: "温度到这个数时风扇强制最大转速，任何设置都不能压低它。",
            symbol: "shield.lefthalf.filled",
            accent: DS.Tone.caution
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                // 状态与冷却倒计时放在同一个 TimelineView 里：冷却期一结束，
                // 状态词要当场从「注意」翻回「正常」。
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = cooldownRemaining(at: context.date)
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        StatusPill(
                            text: emergencyStatus(remaining: remaining).text,
                            isActive: emergencyStatus(remaining: remaining).isActive,
                            color: emergencyStatus(remaining: remaining).color
                        )

                        // 冷却期内风扇保持最大转速 —— 这句必须写出来，
                        // 否则用户会以为温度一降下来风扇就回到原转速了。
                        if remaining > 0 {
                            Label("降温冷却中，还剩 \(Int(remaining.rounded())) 秒。"
                                  + "冷却结束前风扇保持最大转速。",
                                  systemImage: "clock.arrow.circlepath")
                                .font(.caption)
                                .foregroundStyle(DS.Tone.caution)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if controller.emergencyEvents.isEmpty {
                    Text("还没有触发记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.emergencyEvents.prefix(5)) { event in
                        HStack(spacing: DS.Space.sm) {
                            Image(systemName: "thermometer.high")
                                .font(.caption)
                                .foregroundStyle(DS.Tone.critical)
                            Text(String(format: "峰值 %.1f°C", event.peakCelsius))
                                .font(.caption)
                            Spacer()
                            Text(event.isOngoing
                                 ? "进行中"
                                 : (event.releasedAt?.formatted(date: .omitted, time: .shortened) ?? ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// 兜底状态：颜色 + 文字双编码。
    ///
    /// 「已触发 / 未触发」只说了一个「有没有」，看不出现在是在降速还是在
    /// 冷却 —— 这两种情况下风扇都还是最大转速，处理方式却不同。
    private func emergencyStatus(remaining: TimeInterval) -> (text: String, isActive: Bool, color: Color) {
        if controller.isEmergencyActive {
            return ("紧急 · 正在强制降速", true, DS.Tone.critical)
        }
        if remaining > 0 {
            return ("注意 · 降温冷却中", true, DS.Tone.caution)
        }
        return ("正常 · 未触发", false, DS.Tone.good)
    }

    /// 兜底解除后的冷却剩余秒数。冷却期内风扇保持最大转速。
    private func cooldownRemaining(at now: Date) -> TimeInterval {
        guard let last = controller.emergencyEvents.first,
              let released = last.releasedAt else { return 0 }
        return max(0, FanControl.emergencyCooldownSeconds - now.timeIntervalSince(released))
    }

    @ViewBuilder
    private var stallWarningCard: some View {
        let stalled = controller.stalledFans
        let failed = controller.releaseFailedFans
        if !stalled.isEmpty || !failed.isEmpty {
            SectionCard(
                title: "风扇控制异常",
                subtitle: nil,
                symbol: "exclamationmark.triangle.fill",
                accent: DS.Tone.critical
            ) {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    if !failed.isEmpty {
                        Text("风扇 \(failed.map(String.init).joined(separator: "、")) 连交回系统控制都失败，可能处于无法控制的状态。")
                            .font(.caption)
                            .foregroundStyle(DS.Tone.critical)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !stalled.isEmpty {
                        Text("风扇 \(stalled.map(String.init).joined(separator: "、")) 连续 \(Int(FanControl.stallThresholdSeconds)) 秒写不进，已停止修改它的转速并交回系统控制。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("重新开启一次风扇控制规则即可重新尝试接管。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 模式映射

    /// 从控制器回读已保存的规则。
    ///
    /// 为什么必须回读：切到别的页面再回来，SwiftUI 会重建这个视图，
    /// @State 回到初始值（60/85），看起来就是「设置根本没保存」。
    /// 真正的家在控制器（并且已经落盘），界面只做回显。
    private func loadRuleFromController() {
        guard let rule = controller.currentRule else { return }
        ruleFanIndex = rule.targetFan
        ruleMinTemp = rule.minTempC
        ruleMaxTemp = rule.maxTempC
    }

    private enum ModeKind {
        case automatic, fixed, rule
    }

    private func modeKind(_ mode: FanMode) -> ModeKind {
        switch mode {
        case .automatic: return .automatic
        case .fixed:     return .fixed
        case .rule:      return .rule
        }
    }

    private func applyMode(_ kind: ModeKind, fan: FanState.Fan, currentMode: FanMode) async {
        let floor = max(fan.minRPM, Int(Double(fan.minRPM) * FanControl.minRpmSafetyRatio))
        let target: FanMode
        switch kind {
        case .automatic:
            target = .automatic
        case .fixed:
            let rpm: Int
            if case .fixed(let existing) = currentMode {
                rpm = existing
            } else {
                rpm = draftRPM[fan.index].map { Int($0) } ?? floor
            }
            target = .fixed(rpm: min(max(rpm, floor), fan.maxRPM))
        case .rule:
            target = .rule(targetFan: fan.index,
                           minTempC: ruleMinTemp,
                           maxTempC: min(ruleMaxTemp, 89))
        }
        _ = await controller.setMode(target, for: fan.index)
    }

    private func applyFixed(fan: FanState.Fan, rpm: Int) async {
        let floor = max(fan.minRPM, Int(Double(fan.minRPM) * FanControl.minRpmSafetyRatio))
        let clamped = min(max(rpm, floor), fan.maxRPM)
        _ = await controller.setMode(.fixed(rpm: clamped), for: fan.index)
    }

    private func applyRule() async {
        _ = await controller.setMode(
            .rule(targetFan: ruleFanIndex,
                  minTempC: ruleMinTemp,
                  maxTempC: min(ruleMaxTemp, 89)),
            for: ruleFanIndex
        )
    }
}

// MARK: - 免责声明弹窗

struct FanDisclaimerSheet: View {
    let onAccept: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(spacing: DS.Space.md) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(DS.Tone.caution)
                Text("风扇控制免责声明")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            ScrollView {
                Text(FanDisclaimer.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)

            HStack(spacing: DS.Space.md) {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("我已阅读并同意", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 540)
    }
}
