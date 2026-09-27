//
//  PowerSettingsView.swift
//  Deep Sleep
//
//  电源设置页：直接读写 pmset 的系统级设置。
//  读取任何情况下都可用（`pmset -g` 不需要 root），写入需要完全控制。
//

import SwiftUI

struct PowerSettingsView: View {

    @EnvironmentObject private var controller: SleepController

    /// 展示与编辑的设置项。单位统一为分钟（0 表示从不）。
    private struct Item: Identifiable {
        let key: String
        let title: String
        let detail: String
        var id: String { key }
    }

    private let items: [Item] = [
        Item(key: "sleep", title: "系统睡眠", detail: "无操作多久后进入睡眠，0 表示从不"),
        Item(key: "displaysleep", title: "显示器睡眠", detail: "无操作多久后关闭显示器，0 表示从不"),
        Item(key: "disksleep", title: "硬盘睡眠", detail: "无操作多久后让硬盘休眠，0 表示从不"),
        Item(key: "hibernatemode", title: "休眠模式", detail: "0 仅内存、3 内存+磁盘、25 仅磁盘"),
        Item(key: "powernap", title: "Power Nap", detail: "睡眠中仍执行后台任务，1 开启 / 0 关闭"),
        Item(key: "womp", title: "网络唤醒", detail: "允许通过网络唤醒，1 开启 / 0 关闭"),
        Item(key: "ttyskeepawake", title: "远程登录保持唤醒", detail: "有活动会话时阻止睡眠，1 开启 / 0 关闭"),
        Item(key: "lowpowermode", title: "低电量模式", detail: "1 开启 / 0 关闭"),
        Item(key: "autorestart", title: "断电后自动重启", detail: "1 开启 / 0 关闭"),
        Item(key: "lidwake", title: "开盖唤醒", detail: "打开盖子时唤醒，1 开启 / 0 关闭"),
        Item(key: "networkoversleep", title: "网络保持服务", detail: "1 开启 / 0 关闭")
    ]

    var body: some View {
        SectionCard(
            title: "系统电源设置",
            subtitle: controller.helperState.isReady
                ? "修改会立即写入系统。每项修改都需要 \(BiometricAuth.availableMethodDescription) 确认。"
                : "当前为只读模式。启用完全控制后才能修改这些设置。",
            symbol: "slider.horizontal.3"
        ) {
            VStack(spacing: 2) {
                HStack {
                    Spacer()
                    Button {
                        Task { await controller.refreshPowerSettings() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }

                ForEach(items) { item in
                    SettingRow(
                        title: item.title,
                        detail: item.detail,
                        key: item.key,
                        currentValue: controller.powerSettings[item.key] ?? "—",
                        isEditable: controller.helperState.isReady
                    ) { value in
                        Task { await controller.writePowerSetting(key: item.key, value: value) }
                    }
                    if item.key != items.last?.key {
                        Divider()
                    }
                }
            }
        }

        SectionCard(
            title: "依赖关系提示",
            subtitle: nil,
            symbol: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: 7) {
                BulletLine("系统睡眠为 0 时不会自动休眠，这是比 assertion 更持久的设置，重启后依然生效。")
                BulletLine("「完全禁止系统睡眠」在系统里体现为 SleepDisabled 这一项。")
                BulletLine("若只是想临时保持清醒，用总览页的 assertion 更合适，退出应用即自动恢复。")
            }
        }
    }
}
