//
//  DashboardView.swift
//  Deep Sleep
//
//  总览页：一屏之内说清三件事 —— 现在是什么状态、下一步做什么、刚发生了什么。
//
//  设计约束（改动前先读）：
//  - 状态**只在这里说一次**。侧边栏底部只留一行摘要，不重复这里的内容。
//  - 主操作（立即睡眠 / 释放 / 倒计时）不放进卡片，直接摊在页面上，
//    放在卡片里会让人以为它需要先展开点什么。
//  - 状态永远「颜色 + 文字」双编码，不能只靠颜色。
//
//  2026-11 v1.11.1 仪表盘重做（只改怎么显示，不改显示什么数据）：
//  - 顶部从「圆圈图标 + 文字」改成**环形仪表**：圆环的填充比例是
//    「当前生效的保持项 / 全部保持项」，中心放状态词。下面一行用文字
//    把状态再说一遍 —— 环形表只能靠颜色传达，文字才是可靠的那一份。
//  - 「保持清醒」四项从「一列开关行」改成**两列卡片网格**：
//    每张卡片自己带标题、说明、状态标签和开关，一眼能扫到哪几项开着。
//    开关行保留在卡片里（不是拿掉），只是从整行改成卡片右下角。
//  - 电源 / 自动化 / 完全控制三项并成一条**横向状态条**，
//    不再各自占一个 MetricTile —— 它们是「背景状态」，
//    不该跟主状态抢视觉重量。
//

import SwiftUI

struct DashboardView: View {

    @EnvironmentObject private var controller: SleepController
    @State private var countdownMinutes: Int = 30

    var body: some View {
        StatusHeroCard()
            .environmentObject(controller)

        quickActions

        assertionGrid

        statusStrip

        recentEvents
    }

    // MARK: - 主操作

    /// 主操作条。不套卡片 —— 这是这一页最该被点到的东西。
    private var quickActions: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.md) {
                Button {
                    Task { await controller.sleepNow() }
                } label: {
                    Label("立即睡眠", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.countdownDeadline != nil)

                Button {
                    Task { await controller.releaseAllAssertions() }
                } label: {
                    Label("释放全部保持", systemImage: "arrow.uturn.backward")
                }
                .disabled(controller.activeAssertions.isEmpty)

                Spacer(minLength: DS.Space.md)

                if let deadline = controller.countdownDeadline {
                    CountdownLabel(deadline: deadline)
                }
            }

            Divider()

            HStack(spacing: DS.Space.md) {
                Text("倒计时睡眠")
                    .font(.subheadline.weight(.medium))
                Text("设定时长后开始计时，到点自动进入睡眠。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: DS.Space.md)

                Picker("", selection: $countdownMinutes) {
                    ForEach([5, 10, 15, 30, 45, 60, 90, 120], id: \.self) { value in
                        Text("\(value) 分钟").tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                .disabled(controller.countdownDeadline != nil)

                Button("开始倒计时") {
                    controller.startCountdown(minutes: countdownMinutes)
                }
                .disabled(controller.countdownDeadline != nil)

                Button("取消") {
                    controller.cancelCountdown()
                }
                .disabled(controller.countdownDeadline == nil)
            }
        }
        .padding(DS.Space.lg)
        .insetPanel()
    }

    // MARK: - 保持清醒（四项卡片）

    /// 四项保持能力的卡片网格。
    ///
    /// 为什么改成网格而不是一列开关行：一列四个长行要滚动才能看全，
    /// 而「哪几项开着」恰恰是需要一眼看出的信息。两列网格把四张卡
    /// 排成 2×2，一屏之内全部可见。
    private var assertionGrid: some View {
        SectionCard(
            title: "保持清醒",
            subtitle: "打开后会持续向系统申请对应的电源 assertion，关闭即释放。",
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

    // MARK: - 背景状态条

    /// 电源 / 自动化 / 完全控制三项。
    ///
    /// 为什么并成一条而不是三个 MetricTile：这三项是「背景状态」——
    /// 它们影响决策但不决定状态。之前各占一个大块，视觉重量和主状态
    /// 一样重，看起来像三个并列的主要结论。
    private var statusStrip: some View {
        SectionCard(
            title: "环境状态",
            subtitle: "这三项是背景条件，不决定当前是醒着还是睡着了。",
            symbol: "info.circle"
        ) {
            HStack(alignment: .top, spacing: DS.Space.lg) {
                stripItem(
                    title: "电源",
                    value: controller.batteryIsOnAC ? "已接入" : "电池",
                    detail: controller.batteryIsOnAC ? "外接供电" : "使用电池供电",
                    tint: controller.batteryIsOnAC ? DS.Tone.good : DS.Tone.caution,
                    symbol: controller.batteryIsOnAC ? "powerplug.fill" : "battery.50"
                )

                Divider().frame(height: DS.Space.xxl)

                stripItem(
                    title: "自动化",
                    value: "\(controller.automation.satisfiedRuleIDs.count) 条生效",
                    detail: controller.automation.isRunning ? "引擎运行中" : "引擎未运行",
                    tint: controller.automation.isRunning ? DS.Tone.info : DS.Tone.idle,
                    symbol: "gearshape.2"
                )

                Divider().frame(height: DS.Space.xxl)

                stripItem(
                    title: "完全控制",
                    value: controller.helperState.isReady ? "已启用" : "未启用",
                    detail: controller.helperState.title,
                    tint: controller.helperState.isReady ? DS.Tone.good : DS.Tone.caution,
                    symbol: controller.helperState.isReady ? "lock.shield.fill" : "lock.shield"
                )
            }
        }
    }

    /// 状态条里的一项。颜色 + 文字双编码：颜色在图标上，文字在内容里。
    private func stripItem(title: String, value: String, detail: String,
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
                .metricNumber(17)
                .foregroundStyle(tint)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 最近事件

    private var recentEvents: some View {
        SectionCard(
            title: "最近事件",
            subtitle: "最近几条运行记录，完整日志在「运行日志」页。",
            symbol: "clock.arrow.circlepath"
        ) {
            if controller.log.isEmpty {
                EmptyStateView(
                    title: "还没有记录",
                    message: "开关一次保持清醒或改一次设置，这里就会有记录。",
                    systemImage: "text.alignleft"
                )
                .frame(minHeight: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(controller.log.suffix(5).reversed())) { entry in
                        HStack(alignment: .top, spacing: DS.Space.sm) {
                            Circle()
                                .fill(entry.isError ? DS.Tone.critical : Color.secondary.opacity(0.5))
                                .frame(width: 6, height: 6)
                                .padding(.top, 5)
                            Text(entry.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
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
    }
}

// MARK: - 顶部状态卡

/// 顶部状态卡：当前是否在阻止睡眠。
///
/// 结构：左边一个环形仪表，右边是状态文字和下一次动作。
/// 环形仪表用原生 `Gauge` 的 `accessoryCircularCapacity` 样式 ——
/// 它画的圆环和中心文字都是系统自己的，跟系统其它地方的表盘一致。
struct StatusHeroCard: View {

    @EnvironmentObject private var controller: SleepController

    private var isHolding: Bool { !controller.activeAssertions.isEmpty }

    /// 生效的保持项数量 / 全部保持项数量。
    ///
    /// 这是**真实比例**，不是装饰：分子是当前实际持有的 assertion 数，
    /// 分母是应用支持的全部保持项。读不到分母时按 0 处理，
    /// 环是空的 —— 不拿估计值凑一个好看的圆。
    private var activeRatio: Double {
        let total = AssertionKind.allCases.count
        guard total > 0 else { return 0 }
        return Double(controller.activeAssertions.count) / Double(total)
    }

    private var statusTitle: String {
        if controller.sleepDisabled { return "系统睡眠已完全禁用" }
        return isHolding ? "正在保持清醒" : "允许正常睡眠"
    }

    private var statusDetail: String {
        if controller.sleepDisabled {
            return "合上盖子也不会睡眠。关闭「完全禁止系统睡眠」即可恢复。"
        }
        if isHolding {
            let names = controller.activeAssertions
                .sorted { $0.rawValue < $1.rawValue }
                .map(\.title)
                .joined(separator: "、")
            return "已生效 \(controller.activeAssertions.count) 项：\(names)"
        }
        return "没有任何 assertion 在阻止睡眠，系统会按电源设置正常休眠。"
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

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.xl) {
            Gauge(value: activeRatio) {
                EmptyView()
            } currentValueLabel: {
                VStack(spacing: DS.Space.xxs) {
                    Image(systemName: controller.sleepDisabled ? "exclamationmark.octagon.fill"
                          : (isHolding ? "cup.and.saucer.fill" : "moon.fill"))
                        .font(.system(size: 17))
                        .foregroundStyle(tint)
                    Text("\(controller.activeAssertions.count)/\(AssertionKind.allCases.count)")
                        .metricNumber(15)
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
                    .fixedSize(horizontal: false, vertical: true)

                // 环形表的状态词：颜色之外的第二重编码。
                StatusPill(text: gaugeCaption, isActive: isHolding, color: tint)
                    .padding(.top, DS.Space.xxs)
            }

            Spacer(minLength: DS.Space.md)

            nextAction
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.hero)
    }

    /// 右栏：下一次系统动作。这是用户最常问的问题之一。
    @ViewBuilder
    private var nextAction: some View {
        VStack(alignment: .trailing, spacing: DS.Space.sm) {
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
        .frame(minWidth: 120, alignment: .trailing)
    }
}

// MARK: - 保持项卡片

/// 一项保持能力的卡片。
///
/// 与 `AssertionRow` 的区别：`AssertionRow` 是「一行的开关」，
/// 适合塞在长列表里；这张卡片自带标题、说明、状态标签和开关，
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
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 15))
                    .foregroundStyle(isOn ? DS.Tone.good : Color.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(kind.title)
                        .font(.body.weight(.medium))
                    Text(kind.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        Task { await controller.setAssertion(kind, enabled: newValue) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            HStack(spacing: DS.Space.sm) {
                StatusPill(text: statusText, isActive: isOn, color: statusTint)
                if let badgeText {
                    Tag(text: badgeText, color: badgeColor)
                }
            }
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
