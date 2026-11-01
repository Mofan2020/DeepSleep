//
//  ScheduleView.swift
//  Deep Sleep
//
//  定时与唤醒页：倒计时睡眠，以及排定唤醒。
//
//  v1.9 起，计划唤醒从「单条 + cancelall」改成「多条 + 按条取消 + 循环排定」。
//  原因：`pmset schedule cancelall` 会把**别的程序**排的唤醒一起取消掉 ——
//  排定是共享的系统资源，闹钟、备份工具都在用。取消必须精确到单条。
//
//  排定条目在本地维护一份列表（`scheduledWakes.v1`），每次变更后从
//  `pmset -g sched` 读回真实状态对账 —— 不假设「设了就一直生效」。
//
//  2026-11 界面换新：一次性排定与每周循环排定分成两张卡；时间选择统一走
//  原生 DatePicker（标签由 LabeledContent 提供）；已排定列表压成紧凑行。
//  间距 / 圆角一律走 `DS.Space` / `DS.Radius`，不写字面量。
//

import SwiftUI

struct ScheduleView: View {

    @EnvironmentObject private var controller: SleepController
    @State private var countdownMinutes: Int = 30

    // 一次性排定
    @State private var wakeDate: Date = Date().addingTimeInterval(3600)
    @State private var wakeNote: String = ""

    // 循环排定
    @State private var repeatWeekdays: Set<Int> = [2, 3, 4, 5]
    @State private var repeatTime: Date = Date()
    @State private var repeatNote: String = ""
    @State private var showRepeatEditor: Bool = false

    @State private var managerEntries: [ScheduledWake] = []
    @State private var systemEvents: [SystemScheduledEvent] = []
    @State private var busy: Bool = false

    /// 一次性排定的条目。
    private var onceEntries: [ScheduledWake] {
        managerEntries.filter { !$0.isRepeating }
    }

    /// 每周循环排定的条目。
    private var repeatEntries: [ScheduledWake] {
        managerEntries.filter(\.isRepeating)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            countdownCard
            scheduledWakeCard
            repeatWakeCard
            notesCard
            Spacer(minLength: 0)
        }
        .onAppear {
            ScheduledWakeManager.shared.start()
            managerEntries = ScheduledWakeManager.shared.entries
            systemEvents = ScheduledWakeManager.shared.systemEvents
            Task { await refresh() }
        }
    }

    // MARK: - 倒计时睡眠

    private var countdownCard: some View {
        SectionCard(
            title: "倒计时睡眠",
            subtitle: "到点自动进入睡眠。开始前会先放掉本应用自己的阻止睡眠请求，否则会被自己挡住。",
            symbol: "timer",
            accessory: AnyView(
                StatusPill(
                    text: controller.countdownDeadline == nil ? "未在倒计时" : "倒计时进行中",
                    isActive: controller.countdownDeadline != nil,
                    color: controller.countdownDeadline == nil ? DS.Tone.idle : DS.Tone.info
                )
            )
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                LabeledContent("时长") {
                    Picker("", selection: $countdownMinutes) {
                        ForEach([1, 5, 10, 15, 30, 45, 60, 90, 120, 180], id: \.self) { value in
                            Text("\(value) 分钟").tag(value)
                        }
                    }
                    .labelsHidden()
                    .disabled(controller.countdownDeadline != nil)
                }

                HStack(spacing: DS.Space.sm) {
                    Button {
                        controller.startCountdown(minutes: countdownMinutes)
                    } label: {
                        Label("开始", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.countdownDeadline != nil)

                    Button {
                        controller.cancelCountdown()
                    } label: {
                        Label("取消", systemImage: "stop.fill")
                    }
                    .disabled(controller.countdownDeadline == nil)

                    Spacer(minLength: DS.Space.sm)
                }

                if let deadline = controller.countdownDeadline {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: "hourglass")
                            .foregroundStyle(DS.Tone.info)
                        CountdownLabel(deadline: deadline)
                        Text("（\(deadline.formatted(date: .omitted, time: .shortened)) 触发）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 一次性排定

    private var scheduledWakeCard: some View {
        SectionCard(
            title: "排定唤醒",
            subtitle: "通过 pmset 在指定时刻把 Mac 从睡眠中唤醒。需要完全控制权限。",
            symbol: "clock.arrow.circlepath",
            accessory: AnyView(readyTag)
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                LabeledContent("唤醒时间") {
                    DatePicker(
                        "",
                        selection: $wakeDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .disabled(!controller.helperState.isReady || busy)
                }

                TextField("备注（可选）", text: $wakeNote)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!controller.helperState.isReady || busy)

                HStack(spacing: DS.Space.sm) {
                    Button {
                        Task { await scheduleOnce() }
                    } label: {
                        Label("排定唤醒", systemImage: "alarm")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.helperState.isReady || busy)

                    Spacer(minLength: DS.Space.sm)
                }

                if !controller.helperState.isReady {
                    Label("需要先启用完全控制", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(DS.Tone.caution)
                }

                if onceEntries.isEmpty {
                    EmptyStateView(
                        title: "还没有一次性排定",
                        message: "选好时间后点「排定唤醒」，排好的条目会出现在这里。",
                        systemImage: "alarm"
                    )
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        SubsectionHeader(title: "已排定", symbol: "list.bullet")
                        VStack(spacing: 0) {
                            ForEach(onceEntries) { entry in
                                PlScheduledWakeRow(entry: entry, isBusy: busy) {
                                    Task { await cancel(entry) }
                                }
                                if entry.id != onceEntries.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .insetPanel()
                    }
                }
            }
        }
    }

    // MARK: - 循环排定

    private var repeatWakeCard: some View {
        SectionCard(
            title: "循环唤醒",
            subtitle: "每周固定几天在固定时刻唤醒。用 pmset repeat 实现，系统重启后仍然有效。",
            symbol: "repeat",
            accessory: AnyView(readyTag)
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                if showRepeatEditor {
                    LabeledContent("时刻") {
                        DatePicker(
                            "",
                            selection: $repeatTime,
                            displayedComponents: [.hourAndMinute]
                        )
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        SubsectionHeader(title: "重复", symbol: "calendar")
                        PlWeekdaySelector(selected: $repeatWeekdays)
                    }

                    TextField("备注（可选）", text: $repeatNote)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: DS.Space.sm) {
                        Button {
                            Task { await scheduleRepeating() }
                        } label: {
                            Label("排定循环唤醒", systemImage: "repeat")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!controller.helperState.isReady || busy
                                  || repeatWeekdays.isEmpty)

                        Button("取消") {
                            showRepeatEditor = false
                        }

                        Spacer(minLength: DS.Space.sm)
                    }
                } else {
                    Button {
                        showRepeatEditor = true
                    } label: {
                        Label("添加循环唤醒", systemImage: "plus")
                    }
                    .disabled(!controller.helperState.isReady)
                }

                if !repeatEntries.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        SubsectionHeader(title: "已排定", symbol: "list.bullet")
                        VStack(spacing: 0) {
                            ForEach(repeatEntries) { entry in
                                PlScheduledWakeRow(entry: entry, isBusy: busy) {
                                    Task { await cancel(entry) }
                                }
                                if entry.id != repeatEntries.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .insetPanel()
                    }
                }
            }
        }
    }

    // MARK: - 说明

    private var notesCard: some View {
        SectionCard(
            title: "说明",
            symbol: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                BulletLine("排定唤醒由系统的电源管理服务执行，即使 Deep Sleep 未运行也会在指定时间生效。")
                BulletLine("取消只作用于 Deep Sleep 自己排的那一条，不会动到其它程序排定的唤醒。")
                BulletLine("合盖状态下能否被唤醒取决于机型与电源状态，Apple Silicon 机型合盖时通常不会被定时唤醒。")
                BulletLine("一次性排定在触发后由系统消费，之后会从系统列表里消失 —— 这是正常的。")
            }
        }
    }

    // MARK: - 辅助显示

    /// 「完全控制」是否就绪 —— 排定需要特权助手。
    private var readyTag: some View {
        Tag(
            text: controller.helperState.isReady ? "完全控制已就绪" : "需要完全控制",
            color: controller.helperState.isReady ? DS.Tone.good : DS.Tone.caution
        )
    }

    // MARK: - 操作

    private func scheduleOnce() async {
        busy = true
        defer { busy = false }
        let result = await ScheduledWakeManager.shared.scheduleOnce(at: wakeDate, note: wakeNote)
        switch result {
        case .success:
            wakeNote = ""
            controller.banner = Banner(level: .success, text: "已排定唤醒")
        case .failure(let reason):
            controller.banner = Banner(level: .error, text: reason.errorDescription ?? "排定操作失败")
        }
        await refresh()
    }

    private func scheduleRepeating() async {
        busy = true
        defer { busy = false }
        let result = await ScheduledWakeManager.shared.scheduleRepeating(
            weekdays: repeatWeekdays, timeOfDay: repeatTime, note: repeatNote)
        switch result {
        case .success:
            repeatNote = ""
            showRepeatEditor = false
            controller.banner = Banner(level: .success, text: "已排定循环唤醒")
        case .failure(let reason):
            controller.banner = Banner(level: .error, text: reason.errorDescription ?? "排定操作失败")
        }
        await refresh()
    }

    private func cancel(_ entry: ScheduledWake) async {
        busy = true
        defer { busy = false }
        switch await ScheduledWakeManager.shared.cancel(id: entry.id) {
        case .success:
            controller.banner = Banner(level: .success, text: "已取消该唤醒排定")
        case .failure(let reason):
            controller.banner = Banner(level: .error, text: reason.errorDescription ?? "排定操作失败")
        }
        await refresh()
    }

    private func refresh() async {
        await ScheduledWakeManager.shared.refresh()
        managerEntries = ScheduledWakeManager.shared.entries
        systemEvents = ScheduledWakeManager.shared.systemEvents
    }
}

// MARK: - 排定条目行

/// 一条排定的紧凑行。
///
/// 删除按钮只作用于 **Deep Sleep 自己排的那一条**，不会动到其它程序排定的
/// 唤醒 —— 这一约定写在按钮的 help 与「说明」卡里，不要改文案含义。
struct PlScheduledWakeRow: View {

    let entry: ScheduledWake
    let isBusy: Bool
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: entry.isRepeating ? "repeat" : "alarm")
                .foregroundStyle(DS.Tone.info)
                .frame(width: DS.Space.xl)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(entry.timeText + " · " + entry.weekdayText)
                    .font(.callout)
                    .lineLimit(1)
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DS.Space.sm)

            Button(role: .destructive, action: onCancel) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(isBusy)
            .help("取消这一条（只取消 Deep Sleep 自己排的那一条）")
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
    }
}

// MARK: - 星期选择

/// 星期几的多选按钮组（1 = 周日 … 7 = 周六，与 Calendar 一致）。
struct PlWeekdaySelector: View {

    @Binding var selected: Set<Int>
    /// 集合里最小的星期编号：1 = 周日（Calendar 惯例）/ 0 = 周日（0 基下标）。
    var firstIndex: Int = 1

    private static let names = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(firstIndex..<(firstIndex + 7), id: \.self) { weekday in
                let isOn = selected.contains(weekday)
                Button {
                    if isOn {
                        selected.remove(weekday)
                    } else {
                        selected.insert(weekday)
                    }
                } label: {
                    Text(Self.names[weekday - firstIndex])
                        .font(.caption.weight(.medium))
                        .frame(minWidth: DS.Space.xxl, minHeight: DS.Space.xl)
                        .background(
                            isOn ? DS.Tone.info.opacity(0.22) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        )
                        .foregroundStyle(isOn ? DS.Tone.info : DS.Tone.idle)
                }
                .buttonStyle(.plain)
                .help("周" + Self.names[weekday - firstIndex])
            }
        }
    }
}
