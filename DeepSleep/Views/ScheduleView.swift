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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            subtitle: "计时结束后自动进入睡眠，过程中会先释放本应用持有的保持状态，否则请求会被自己挡住。",
            symbol: "timer",
            accent: .orange
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Picker("", selection: $countdownMinutes) {
                        ForEach([1, 5, 10, 15, 30, 45, 60, 90, 120, 180], id: \.self) { value in
                            Text("\(value) 分钟").tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .disabled(controller.countdownDeadline != nil)

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

                    Spacer()
                }

                if let deadline = controller.countdownDeadline {
                    HStack(spacing: 8) {
                        Image(systemName: "hourglass").foregroundStyle(.orange)
                        CountdownLabel(deadline: deadline)
                        Text("（\(deadline.formatted(date: .omitted, time: .shortened)) 触发）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("当前没有进行中的倒计时")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
            accent: .blue
        ) {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker(
                    "唤醒时间",
                    selection: $wakeDate,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .disabled(!controller.helperState.isReady || busy)

                TextField("备注（可选）", text: $wakeNote)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!controller.helperState.isReady || busy)

                HStack(spacing: 10) {
                    Button {
                        Task { await scheduleOnce() }
                    } label: {
                        Label("排定唤醒", systemImage: "alarm")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.helperState.isReady || busy)

                    Spacer()
                }

                if !managerEntries.isEmpty {
                    Divider()
                    Text("已排定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(managerEntries) { entry in
                        scheduledRow(entry)
                    }
                } else {
                    Text("当前没有已排定的唤醒")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !controller.helperState.isReady {
                    Label("需要先启用完全控制", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// 一条排定的行。
    private func scheduledRow(_ entry: ScheduledWake) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isRepeating ? "repeat" : "alarm")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.timeText + " · " + entry.weekdayText)
                    .font(.callout)
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                Task { await cancel(entry) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            .help("取消这一条")
        }
    }

    // MARK: - 循环排定

    private var repeatWakeCard: some View {
        SectionCard(
            title: "循环唤醒",
            subtitle: "每周固定几天在固定时刻唤醒。用 pmset repeat 实现，系统重启后仍然有效。",
            symbol: "repeat",
            accent: .indigo
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if showRepeatEditor {
                    DatePicker(
                        "时刻",
                        selection: $repeatTime,
                        displayedComponents: [.hourAndMinute]
                    )

                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { weekday in
                            let weekdayName = ["日", "一", "二", "三", "四", "五", "六"][weekday - 1]
                            Button {
                                if repeatWeekdays.contains(weekday) {
                                    repeatWeekdays.remove(weekday)
                                } else {
                                    repeatWeekdays.insert(weekday)
                                }
                            } label: {
                                Text(weekdayName)
                                    .frame(width: 28, height: 24)
                            }
                            .buttonStyle(.bordered)
                            .tint(repeatWeekdays.contains(weekday) ? .accentColor : .secondary)
                        }
                    }

                    TextField("备注（可选）", text: $repeatNote)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 10) {
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
                        Spacer()
                    }
                } else {
                    Button {
                        showRepeatEditor = true
                    } label: {
                        Label("添加循环唤醒", systemImage: "plus")
                    }
                    .disabled(!controller.helperState.isReady)
                }

                let repeatEntries = managerEntries.filter(\.isRepeating)
                if !repeatEntries.isEmpty {
                    Divider()
                    ForEach(repeatEntries) { entry in
                        scheduledRow(entry)
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
            VStack(alignment: .leading, spacing: 7) {
                BulletLine("排定唤醒由系统的电源管理服务执行，即使 Deep Sleep 未运行也会在指定时间生效。")
                BulletLine("取消只作用于 Deep Sleep 自己排的那一条，不会动到其它程序排定的唤醒。")
                BulletLine("合盖状态下能否被唤醒取决于机型与电源状态，Apple Silicon 机型合盖时通常不会被定时唤醒。")
                BulletLine("一次性排定在触发后由系统消费，之后会从系统列表里消失 —— 这是正常的。")
            }
        }
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
