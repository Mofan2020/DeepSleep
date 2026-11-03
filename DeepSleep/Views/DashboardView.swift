//
//  DashboardView.swift
//  Deep Sleep
//
//  总览页。一屏之内看完：现在什么状态、生效了几项、下一次动作是什么、
//  刚才发生了什么。
//
//  设计约束（改动前先读）：
//  - 状态**只在这里说一次**。侧边栏底部只留一行摘要，不重复这里的内容。
//  - 状态永远「颜色 + 文字」双编码，不能只靠颜色。
//  - **不放机制说明。** 这一页只回答「现在怎么样 / 我该点什么」，
//    原理、边界、建议一律不写 —— 用户不会读，写了只是噪音。
//  - 间距与圆角只用 `DS` 令牌，不写字面量。
//
//  2026-11 v1.11.3 仪表盘第二次重做：
//  - 主操作（立即睡眠 / 释放全部）并进顶部状态卡，不再单开一块 ——
//    原来那块自己占一屏高度，用户滚一屏才看到「保持清醒」。
//  - 倒计时睡眠从「一行三个控件」改成**一个菜单**：点开选时长直接开始。
//    倒计时进行中才出现「取消」。
//  - 「释放全部」只在真的有保持项时出现，平时不占位置。
//  - 保持清醒四张卡去掉说明文字，压成一行；「需完全控制」保留成小标签，
//    因为用户点了开关没反应会困惑。
//  - 环境状态与最近事件**并排**放在底部，省一屏纵向空间。
//

import SwiftUI

struct DashboardView: View {

    @EnvironmentObject private var controller: SleepController

    /// 点某个置顶工具。调用方（ContentView）负责切 selection。
    /// 默认 nil —— 不传就只有入口没有跳转，向后兼容。
    var onOpenTool: ((ToolboxTool) -> Void)? = nil

    /// 工具箱里置顶的工具。用户随时能改置顶，所以每次仪表盘出现时
    /// 重新读一次布局，不缓存。
    @State private var pinnedTools: [ToolboxTool] = DashboardView.loadPinnedTools()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            StatusHeroCard()
                .environmentObject(controller)

            // 没有置顶工具就不占位置，也不放空态占位。
            if !pinnedTools.isEmpty {
                DashboardQuickAccess(tools: pinnedTools) { tool in
                    onOpenTool?(tool)
                }
            }

            assertionGrid

            DashboardSystemCards()

            bottomRow
        }
        .onAppear {
            // 从工具箱页改过置顶后回到仪表盘，这里读到最新布局。
            pinnedTools = DashboardView.loadPinnedTools()
        }
    }

    /// 置顶的工具，按置顶顺序（工具箱布局里 pinned 数组的顺序）。
    private static func loadPinnedTools() -> [ToolboxTool] {
        ToolboxStore.load().pinned.compactMap { ToolboxTool(rawValue: $0) }
    }

    // MARK: - 保持清醒（四项）

    /// 四项保持能力的两列网格。
    ///
    /// 为什么用网格不用一列开关行：一列四个长行要滚动才看全，
    /// 而「哪几项开着」恰恰是要一眼看出的信息。
    private var assertionGrid: some View {
        SectionCard(
            title: "保持清醒",
            symbol: "moon.zzz.fill"
        ) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: DS.Space.md),
                    GridItem(.flexible(), spacing: DS.Space.md)
                ],
                spacing: DS.Space.md
            ) {
                ForEach(AssertionKind.allCases) { kind in
                    AssertionCard(kind: kind)
                        .environmentObject(controller)
                }
            }
        }
    }

    // MARK: - 底部两栏

    /// 环境状态与最近事件并排。
    ///
    /// 原来这两块各占一整行，纵向要滚三屏才到头。���排之后整页一屏装得下。
    private var bottomRow: some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            SectionCard(
                title: "环境",
                symbol: "info.circle"
            ) {
                HStack(alignment: .top, spacing: DS.Space.lg) {
                    envItem(
                        title: "电源",
                        value: controller.batteryIsOnAC ? "已接入" : "电池",
                        detail: controller.batteryIsOnAC ? "外接供电" : "使用电池",
                        tint: controller.batteryIsOnAC ? DS.Tone.good : DS.Tone.caution,
                        symbol: controller.batteryIsOnAC ? "powerplug.fill" : "battery.50"
                    )

                    Divider().frame(height: DS.Space.xxl)

                    envItem(
                        title: "自动化",
                        value: "\(controller.automation.satisfiedRuleIDs.count) 条生效",
                        detail: controller.automation.isRunning ? "运行中" : "未运行",
                        tint: controller.automation.isRunning ? DS.Tone.info : DS.Tone.idle,
                        symbol: "gearshape.2"
                    )

                    Divider().frame(height: DS.Space.xxl)

                    envItem(
                        title: "完全控制",
                        value: controller.helperState.isReady ? "已启用" : "未启用",
                        detail: controller.helperState.title,
                        tint: controller.helperState.isReady ? DS.Tone.good : DS.Tone.caution,
                        symbol: controller.helperState.isReady ? "lock.shield.fill" : "lock.shield"
                    )
                }
            }
            .frame(maxWidth: .infinity)

            SectionCard(
                title: "最近事件",
                symbol: "clock.arrow.circlepath"
            ) {
                if controller.log.isEmpty {
                    Text("暂无记录")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, DS.Space.sm)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(controller.log.suffix(3).reversed())) { entry in
                            HStack(alignment: .top, spacing: DS.Space.sm) {
                                Circle()
                                    .fill(entry.isError ? DS.Tone.critical : Color.secondary.opacity(0.5))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)
                                Text(entry.text)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: DS.Space.sm)
                                Text(entry.date, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, DS.Space.xs)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 环境状态里的一项。颜色 + 文字双编码：颜色在图标上，文字在内容里。
    private func envItem(title: String, value: String, detail: String,
                         tint: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .metricNumber(16)
                .foregroundStyle(tint)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 顶部状态卡

/// 顶部状态卡：当前状态、生效数量、下一次动作、主操作。
///
/// 环形仪表用原生 `Gauge` 的 `accessoryCircularCapacity` 样式 ——
/// 圆环和中心文字都是系统自己画的，跟系统其它地方的表盘一致。
struct StatusHeroCard: View {

    @EnvironmentObject private var controller: SleepController
    @State private var countdownMinutes: Int = 30

    private var isHolding: Bool { !controller.activeAssertions.isEmpty }

    /// 生效的保持项数量 / 全部保持项数量。
    ///
    /// 这是**真实比例**，不是装饰：分子是当前实际持有的项数，
    /// 分母是应用支持的全部保持项。读不到分母时按 0 处理，
    /// 环是空的 —— 不拿估计值凑一个好看的圆。
    private var activeRatio: Double {
        let total = AssertionKind.allCases.count
        guard total > 0 else { return 0 }
        return Double(controller.activeAssertions.count) / Double(total)
    }

    private var statusTitle: String {
        if controller.sleepDisabled { return "系统睡眠已禁用" }
        return isHolding ? "正在保持清醒" : "允许正常睡眠"
    }

    private var statusDetail: String {
        if controller.sleepDisabled {
            return "合上盖子也不会睡眠。"
        }
        if isHolding {
            let names = controller.activeAssertions
                .sorted { $0.rawValue < $1.rawValue }
                .map(\.title)
                .joined(separator: "、")
            return "生效 \(controller.activeAssertions.count) 项：\(names)"
        }
        return "没有程序在阻止睡眠。"
    }

    private var tint: Color {
        if controller.sleepDisabled { return DS.Tone.caution }
        return isHolding ? DS.Tone.good : DS.Tone.idle
    }

    /// 环形仪表中心的状态词。
    ///
    /// 为什么一定要有这一行字：环形表靠颜色传达状态，
    /// 颜色在深色模式下、在色觉障碍下都可能读不出来。
    /// 文字才是可靠的那一份。
    private var gaugeCaption: String {
        if controller.sleepDisabled { return "睡眠已禁用" }
        if isHolding { return "保持清醒" }
        return "正常睡眠"
    }

    /// 可选的倒计时时长。菜单里直接开始，不再单摆一行控件。
    private let countdownOptions = [5, 10, 15, 30, 45, 60, 90, 120]

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.xl) {
            Gauge(value: activeRatio) {
                EmptyView()
            } currentValueLabel: {
                VStack(spacing: DS.Space.xxs) {
                    Image(systemName: controller.sleepDisabled ? "exclamationmark.octagon.fill"
                          : (isHolding ? "cup.and.saucer.fill" : "moon.fill"))
                        .font(.system(size: 15))
                        .foregroundStyle(tint)
                    Text("\(controller.activeAssertions.count)/\(AssertionKind.allCases.count)")
                        .metricNumber(14)
                        .foregroundStyle(tint)
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .frame(width: DS.Metric.gaugeDiameter, height: DS.Metric.gaugeDiameter)
            .help(gaugeCaption)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(statusTitle)
                    .font(.title2.weight(.semibold))
                Text(statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)

                // 环形表的状态词：颜色之外的第二重编码。
                StatusPill(text: gaugeCaption, isActive: isHolding, color: tint)
                    .padding(.top, DS.Space.xxs)
            }

            Spacer(minLength: DS.Space.md)

            rightColumn
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.hero)
    }

    /// 右栏：下一次动作 + 主操作 + 倒计时入口。
    ///
    /// 为什么主操作放进状态卡而不是单开一块：主操作是这一页最该被点到的
    /// 东西，用户不该先滚过一屏说明才能看到它。
    @ViewBuilder
    private var rightColumn: some View {
        VStack(alignment: .trailing, spacing: DS.Space.md) {
            // 下一次动作
            VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                Text("下一次动作")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let deadline = controller.countdownDeadline {
                    VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                        Text("倒计时睡眠")
                            .font(.callout.weight(.medium))
                        CountdownLabel(deadline: deadline)
                    }
                } else if let wake = controller.scheduledWake {
                    VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                        Text("定时唤醒")
                            .font(.callout.weight(.medium))
                        Text(wake, format: .dateTime.month().day().hour().minute())
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("没有安排")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            // 主操作
            HStack(spacing: DS.Space.sm) {
                Button {
                    Task { await controller.sleepNow() }
                } label: {
                    Label("立即睡眠", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.countdownDeadline != nil)

                // 没有保持项时这一项没意义，也不占位置。
                if !controller.activeAssertions.isEmpty {
                    Button {
                        Task { await controller.releaseAllAssertions() }
                    } label: {
                        Label("释放全部", systemImage: "arrow.uturn.backward")
                    }
                    // 会连自动化规则维持的那些一起放掉 —— 这一点用户
                    // 不点下去是看不出来的，所以挂在提示里。
                    .help("释放全部保持项，包括由自动化规则维持的那些。")
                }
            }

            // 倒计时：平时是一个菜单（选了就开始），进行中才出现取消。
            if controller.countdownDeadline == nil {
                Menu {
                    ForEach(countdownOptions, id: \.self) { value in
                        Button("\(value) 分钟后睡眠") {
                            controller.startCountdown(minutes: value)
                        }
                    }
                } label: {
                    Label("倒计时睡眠", systemImage: "timer")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Button("取消倒计时") {
                    controller.cancelCountdown()
                }
                .buttonStyle(.borderless)
                .fixedSize()
            }
        }
        .frame(minWidth: 160, alignment: .trailing)
    }
}

// MARK: - 保持项卡片

/// 一项保持能力的卡片。
///
/// 与 `AssertionRow` 的区别：`AssertionRow` 是「一行的开关」，
/// 适合塞在长列表里；这张卡片压成一行、自带状态标签和开关，
/// 适合 2×2 网格 —— 不用滚就能看全四项现在各自是什么状态。
///
/// 状态标签（需完全控制 / 自动化维持 / 睡眠加固）合并成一个胶囊，
/// 理由和 `AssertionRow` 一样：四个胶囊比一行文字噪声大。
struct AssertionCard: View {

    let kind: AssertionKind
    @EnvironmentObject private var controller: SleepController

    private var isOn: Bool { controller.activeAssertions.contains(kind) }

    private var isRuleDriven: Bool { controller.ruleAssertions.contains(kind) }
    /// 「完全禁止系统睡眠」会额外持有一枚 PreventSystemSleep 断言作为加固。
    private var isSleepDisabledBacking: Bool {
        controller.sleepDisabledBacking && kind == .preventSystemSleep
    }

    private var badgeText: String? {
        var parts: [String] = []
        if kind.requiresPrivilege { parts.append("需完全控制") }
        if isRuleDriven { parts.append("自动化维持") }
        if isSleepDisabledBacking { parts.append("睡眠加固") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var badgeColor: Color {
        if isSleepDisabledBacking { return DS.Tone.caution }
        if kind.requiresPrivilege { return DS.Tone.caution }
        return DS.Tone.info
    }

    /// 卡片的状态词。开着就是「生效中」，关着就是「未启用」——
    /// 不写「正常 / 异常」，因为关掉一项不是异常，是用户自己的选择。
    private var statusText: String {
        isOn ? "生效中" : "未启用"
    }

    private var statusTint: Color {
        isOn ? DS.Tone.good : DS.Tone.idle
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 14))
                .foregroundStyle(isOn ? DS.Tone.good : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xs) {
                    Text(kind.title)
                        .font(.callout.weight(.medium))
                    if let badgeText {
                        Tag(text: badgeText, color: badgeColor)
                    }
                }
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusTint)
            }

            Spacer(minLength: DS.Space.sm)

            Toggle("", isOn: Binding(
                get: { isOn },
                set: { newValue in
                    Task { await controller.setAssertion(kind, enabled: newValue) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetPanel()
    }
}

// MARK: - 倒计时

/// 每秒刷新的倒计时文案。
struct CountdownLabel: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(deadline.timeIntervalSince(context.date)))
            let minutes = remaining / 60
            let seconds = remaining % 60
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "timer").foregroundStyle(DS.Tone.caution)
                Text(String(format: "剩余 %02d:%02d", minutes, seconds))
                    .font(.system(.body, design: .monospaced).weight(.medium))
            }
        }
    }
}
