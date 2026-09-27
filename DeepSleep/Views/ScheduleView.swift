//
//  ScheduleView.swift
//  Deep Sleep
//
//  定时与唤醒页：倒计时睡眠，以及基于 pmset 的计划唤醒。
//

import SwiftUI

struct ScheduleView: View {

    @EnvironmentObject private var controller: SleepController
    @State private var countdownMinutes: Int = 30
    @State private var wakeDate: Date = Date().addingTimeInterval(3600)

    var body: some View {
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

        SectionCard(
            title: "计划唤醒",
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
                .disabled(!controller.helperState.isReady)

                HStack(spacing: 10) {
                    Button {
                        Task { await controller.scheduleWake(at: wakeDate) }
                    } label: {
                        Label("排定唤醒", systemImage: "alarm")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.helperState.isReady)

                    Button {
                        Task { await controller.cancelScheduledWake() }
                    } label: {
                        Label("取消全部排定", systemImage: "alarm.slash")
                    }
                    .disabled(!controller.helperState.isReady)

                    Spacer()
                }

                if let scheduled = controller.scheduledWake {
                    HStack(spacing: 8) {
                        Image(systemName: "alarm.fill").foregroundStyle(.blue)
                        Text("已排定：\(scheduled.formatted(date: .abbreviated, time: .shortened))")
                            .font(.callout)
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

        SectionCard(
            title: "说明",
            symbol: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: 7) {
                BulletLine("计划唤醒由系统的电源管理服务执行，即使 Deep Sleep 未运行也会在指定时间生效。")
                BulletLine("取消操作会清除所有由 pmset 排定的唤醒任务，包括其他程序排定的。")
                BulletLine("合盖状态下能否被唤醒取决于机型与电源状态，Apple Silicon 机型合盖时通常不会被定时唤醒。")
            }
        }
    }
}
