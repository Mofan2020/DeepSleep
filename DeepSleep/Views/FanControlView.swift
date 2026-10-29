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

import SwiftUI

struct FanControlView: View {

    @ObservedObject var controller: FanController

    @State private var draftRPM: [Int: Double] = [:]
    @State private var ruleFanIndex: Int = 0
    @State private var ruleMinTemp: Double = 60
    @State private var ruleMaxTemp: Double = 85
    @State private var showDisclaimer: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            notesCard
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

    // MARK: - 免责声明

    private var disclaimerCard: some View {
        SectionCard(
            title: "使用风扇控制需先阅读免责声明",
            subtitle: "风扇转速通过 SMC 写入，属于苹果未公开的接口。同一条指令在不同机型上的表现可能不同。",
            symbol: "exclamationmark.shield",
            accent: .orange
        ) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    BulletLine("不同 Mac 的风扇键名、转速区间与模式键可能不同，写错会导致风扇不转或异常加速。")
                    BulletLine("风扇长时间停在过低转速可能使机器过热；停在过高转速会增加噪音与磨损。")
                    BulletLine("任何传感器达到 90°C 时，本应用强制所有风扇拉到最大转速，这一条无法关闭。")
                    BulletLine("手动模式有 15 秒租约：应用退出或崩溃后风扇自动交回系统控制。")
                }

                Button {
                    showDisclaimer = true
                } label: {
                    Label("阅读全文并同意", systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - 总开关

    private var masterCard: some View {
        SectionCard(
            title: "风扇控制",
            subtitle: controller.isEnabled
                ? "手动模式下由助手按租约维持转速，应用失联后自动交回系统。"
                : "关闭时风扇完全由系统管理。",
            symbol: "fan",
            accent: .blue
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { controller.isEnabled },
                    set: { newValue in Task { await controller.setEnabled(newValue) } }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("启用风扇控制")
                        Text("关闭时所有风扇立即交回系统自动控制。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!controller.isDisclaimerAccepted || controller.isEmergencyActive)

                if let error = controller.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if controller.isEmergencyActive {
                    Label("紧急降速中：温度已达 \(Int(FanControl.emergencyTemperatureCelsius))°C，"
                          + "风扇已强制最大转速，此处设置暂不生效。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
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
            accent: .secondary
        ) {
            Text("读不到风扇信息。可能是这台机器没有可读风扇，或特权助手尚未就绪。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 单个风扇

    private func fanCard(_ fan: FanState.Fan) -> some View {
        let mode = controller.modes[fan.index] ?? .automatic
        return SectionCard(
            title: fan.name.isEmpty ? "风扇 \(fan.index)" : fan.name,
            subtitle: "区间 \(fan.minRPM)–\(fan.maxRPM) RPM",
            symbol: "fan.fill",
            accent: fan.isManual ? .orange : .blue
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("\(fan.currentRPM)")
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                    Text("RPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Tag(text: fan.isManual ? "手动" : "系统自动",
                        color: fan.isManual ? .orange : .secondary)
                    Spacer()
                }

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
                .disabled(!controller.isEnabled || controller.isEmergencyActive)

                switch mode {
                case .fixed(let rpm):
                    fixedEditor(fan: fan, rpm: rpm)
                case .rule(let target, let low, let high):
                    Text(String(format: "规则：风扇 %d，%.0f–%.0f°C 线性映射到最低/最高转速。",
                                target, low, high))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .automatic:
                    EmptyView()
                }
            }
        }
    }

    private func fixedEditor(fan: FanState.Fan, rpm: Int) -> some View {
        let floor = max(fan.minRPM, Int(Double(fan.minRPM) * FanControl.minRpmSafetyRatio))
        let ceiling = max(floor, fan.maxRPM)
        let binding = Binding<Double>(
            get: { draftRPM[fan.index] ?? Double(min(max(rpm, floor), ceiling)) },
            set: { draftRPM[fan.index] = $0 }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("目标转速").font(.callout)
                Spacer()
                Text("\(Int(binding.wrappedValue)) RPM")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
            }
            Slider(value: binding, in: Double(floor)...Double(ceiling),
                   step: ceiling - floor > 4000 ? 10 : 1) { editing in
                if !editing {
                    Task { await applyFixed(fan: fan, rpm: Int(draftRPM[fan.index] ?? Double(rpm))) }
                }
            }
            .disabled(!controller.isEnabled || controller.isEmergencyActive)

            HStack {
                Text("\(floor)")
                Spacer()
                Text("\(ceiling)")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            Text("下限取机械最低转速的 \(Int(FanControl.minRpmSafetyRatio * 100))%，低于该值部分机型会拒绝执行。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 规则调速

    private var ruleCard: some View {
        SectionCard(
            title: "规则调速参数",
            subtitle: "低于最低温度用最低转速，高于最高温度用最高转速，中间随温度线性变化。",
            symbol: "slider.horizontal.below.rectangle",
            accent: .indigo
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("目标风扇").frame(width: 78, alignment: .leading)
                    Picker("", selection: $ruleFanIndex) {
                        ForEach(controller.fans, id: \.index) { fan in
                            Text(fan.name.isEmpty ? "风扇 \(fan.index)" : fan.name)
                                .tag(fan.index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Spacer()
                }

                HStack {
                    Text("最低温度").frame(width: 78, alignment: .leading)
                    TextField("", value: $ruleMinTemp, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Stepper("", value: $ruleMinTemp, in: 20...88, step: 1).labelsHidden()
                    Text("°C").foregroundStyle(.secondary)
                    Spacer()
                }

                HStack {
                    Text("最高温度").frame(width: 78, alignment: .leading)
                    TextField("", value: $ruleMaxTemp, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Stepper("", value: $ruleMaxTemp, in: 21...89, step: 1).labelsHidden()
                    Text("°C").foregroundStyle(.secondary)
                    Spacer()
                }

                if let warning = ruleWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await applyRule() }
                    } label: {
                        Label("应用规则", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ruleWarning != nil
                              || !controller.isEnabled
                              || controller.isEmergencyActive)

                    Spacer()
                }

                Text("最高温度上限是 89°C：到 90°C 会由安全兜底接管，再高的区间不会生效。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
            subtitle: nil,
            symbol: "shield.lefthalf.filled",
            accent: .orange
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusPill(
                        text: controller.isEmergencyActive ? "已触发" : "未触发",
                        isActive: !controller.isEmergencyActive,
                        color: controller.isEmergencyActive ? .red : .green
                    )
                    Spacer()
                }

                if controller.emergencyEvents.isEmpty {
                    Text("还没有触发记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.emergencyEvents.prefix(5)) { event in
                        HStack(spacing: 8) {
                            Image(systemName: "thermometer.high")
                                .font(.caption)
                                .foregroundStyle(.red)
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

                Text("触发时所有可写风扇立刻拉到最大转速，并拒绝任何降速请求（含交回系统）。"
                     + "温度回落后再等 \(Int(FanControl.emergencyCooldownSeconds)) 秒解除。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                accent: .red
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    if !failed.isEmpty {
                        Text("风扇 \(failed.map(String.init).joined(separator: "、")) 连交回系统控制都失败，可能处于无法控制的状态。")
                            .font(.caption)
                            .foregroundStyle(.red)
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

    private var notesCard: some View {
        SectionCard(
            title: "说明",
            symbol: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: 7) {
                BulletLine("应用退出时主动释放风扇控制权，不等租约超时。")
                BulletLine("助手未就绪或版本过旧时，本页保持只读并如实说明，不会假装写入成功。")
                BulletLine("读不到风扇键时如实报告，不显示虚构的转速。")
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
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

            HStack(spacing: 10) {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("我已阅读并同意", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}
