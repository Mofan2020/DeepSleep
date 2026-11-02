//
//  PowerSettingsView.swift
//  Deep Sleep
//
//  电源设置页：直接读写 pmset 的系统级设置。
//  读取任何情况下都可用（`pmset -g` 不需要 root），写入需要完全控制。
//
//  界面约定：
//    - pmset 的键值分三种形态，各自用一种原生控件，**同类不混用**：
//        时间类（分钟）→ Stepper
//        开关类（0/1）  → Switch
//        模式类（枚举）  → Picker(.segmented)
//    - 每行都能看到「当前值」：写进去的是系统里的真值，不是草稿。
//    - 写入仍走 controller.writePowerSetting(key:value:)，
//      认证与参数一个都没改。
//

import SwiftUI

struct PowerSettingsView: View {

    @EnvironmentObject private var controller: SleepController

    /// 展示与编辑的设置项。单位统一为分钟（0 表示从不）。
    private struct Item: Identifiable {
        let key: String
        let title: String
        let detail: String
        /// 这项用哪种原生控件。
        let kind: Kind
        var id: String { key }
    }

    /// 一类设置项的显示方式。
    ///
    /// 三种形态对应三种原生控件，同一类里不混用：
    /// 时间类走 Stepper、开关类走 Switch、模式类走 Picker(.segmented)。
    private enum Kind {
        /// 分钟数，0 表示从不。
        case minutes
        /// 0 / 1 开关。
        case flag
        /// 枚举值。附带显示名。
        case mode([(value: String, label: String)])
    }

    private let items: [Item] = [
        Item(key: "sleep", title: "系统睡眠", detail: "无操作多久后进入睡眠，0 表示从不", kind: .minutes),
        Item(key: "displaysleep", title: "显示器睡眠", detail: "无操作多久后关闭显示器，0 表示从不", kind: .minutes),
        Item(key: "disksleep", title: "硬盘睡眠", detail: "无操作多久后让硬盘休眠，0 表示从不", kind: .minutes),
        Item(key: "hibernatemode", title: "休眠模式", detail: "休眠时把哪些内容写回磁盘",
             kind: .mode([("0", "仅内存"), ("3", "内存和磁盘"), ("25", "仅磁盘")])),
        Item(key: "powernap", title: "Power Nap", detail: "睡眠中仍执行后台任务", kind: .flag),
        Item(key: "womp", title: "网络唤醒", detail: "允许通过网络唤醒这台 Mac", kind: .flag),
        Item(key: "ttyskeepawake", title: "远程登录保持唤醒", detail: "有活动会话时阻止睡眠", kind: .flag),
        Item(key: "lowpowermode", title: "低电量模式", detail: "省电优先于性能", kind: .flag),
        Item(key: "autorestart", title: "断电后自动重启", detail: "来电恢复供电后自动开机", kind: .flag),
        Item(key: "lidwake", title: "开盖唤醒", detail: "打开盖子时唤醒", kind: .flag),
        Item(key: "networkoversleep", title: "网络保持服务", detail: "睡眠时保持网络连接", kind: .flag)
    ]

    /// 分钟类与模式类的草稿值。写成功前不动系统里的真值。
    @State private var drafts: [String: String] = [:]

    /// 分钟数的取值范围。0 表示从不；上限 7 天，够用又不至于写错单位。
    private static let minuteRange: ClosedRange<Int> = 0...10080

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            settingsCard
            advancedCard
        }
    }

    // MARK: - 系统电源设置

    private var settingsCard: some View {
        SectionCard(
            title: "系统电源设置",
            subtitle: controller.helperState.isReady
                ? "修改会立即写入系统。每项修改都需要 \(BiometricAuth.availableMethodDescription) 确认。"
                : "当前为只读模式。启用完全控制后才能修改这些设置。",
            symbol: "slider.horizontal.3",
            accessory: AnyView(
                Button {
                    Task { await controller.refreshPowerSettings() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            )
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                SubsectionHeader(title: "时间类（分钟）", symbol: "clock")
                ForEach(items.filter { isMinutes($0) }) { item in
                    minuteRow(item)
                }

                // 这两条说的是「睡眠设为 0」和「只想临时保持清醒」——
                // 放在时间类后面，用户改「系统睡眠」时正好会看到。
                BulletLine("系统睡眠设为 0 后不会自动休眠，重启后依然有效。")
                BulletLine("只想临时保持清醒，用总览页的「阻止睡眠的请求」，退出应用即自动恢复。")

                Divider()

                SubsectionHeader(title: "开关类（0 / 1）", symbol: "switch.2")
                ForEach(items.filter { isFlag($0) }) { item in
                    flagRow(item)
                }

                Divider()

                SubsectionHeader(title: "模式类", symbol: "slider.vertical.3")
                ForEach(items.filter { isMode($0) }) { item in
                    modeRow(item)
                }
            }
        }
    }

    // MARK: - 行

    /// 时间类：Stepper 改草稿，点「应用」才写系统 —— 每写一次都要一次本地确认，
    /// 不能让拖动 Stepper 时一路弹认证。
    private func minuteRow(_ item: Item) -> some View {
        LabeledContent {
            HStack(spacing: DS.Space.sm) {
                Text(currentValueText(item))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Stepper("", value: minuteBinding(item.key), in: Self.minuteRange, step: 1)
                    .labelsHidden()
                Button("应用") {
                    let value = drafts[item.key] ?? "\(minutesFromCurrent(item.key))"
                    Task { await controller.writePowerSetting(key: item.key, value: value) }
                }
                .controlSize(.small)
                .disabled(!controller.helperState.isReady
                          || drafts[item.key] == nil
                          || "\(drafts[item.key] ?? "")" == currentValue(item.key))
            }
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(item.title).font(.body.weight(.medium))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 开关类：Switch 直接读写 1 / 0。
    private func flagRow(_ item: Item) -> some View {
        LabeledContent {
            Toggle("", isOn: Binding(
                get: { currentValue(item.key) == "1" },
                set: { newValue in
                    Task {
                        await controller.writePowerSetting(key: item.key, value: newValue ? "1" : "0")
                        // 写入被取消时系统里的值没变，这里重读一次，
                        // 开关才会弹回真实状态。
                        await controller.refreshPowerSettings()
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!controller.helperState.isReady)
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(item.title).font(.body.weight(.medium))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 模式类：分段选择器，选中即写入。
    private func modeRow(_ item: Item) -> some View {
        LabeledContent {
            HStack(spacing: DS.Space.sm) {
                Text(currentValueText(item))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { drafts[item.key] ?? currentValue(item.key) },
                    set: { newValue in
                        drafts[item.key] = newValue
                        Task {
                            await controller.writePowerSetting(key: item.key, value: newValue)
                            await controller.refreshPowerSettings()
                        }
                    }
                )) {
                    ForEach(modeOptions(item), id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!controller.helperState.isReady)
            }
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(item.title).font(.body.weight(.medium))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 高级选项

    private var advancedCard: some View {
        SectionCard(
            title: "高级选项",
            subtitle: nil,
            symbol: "gearshape.2"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Toggle(isOn: Binding(
                    get: { controller.isManual(.preventDiskIdle) },
                    set: { newValue in
                        Task { await controller.setAssertion(.preventDiskIdle, enabled: newValue) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("阻止外部磁盘空闲休眠")
                            .font(.body)
                        Text("外置硬盘不进入低功耗态，避免传输中断。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                Text("这一项不需要完全控制权限。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 取值辅助

    private func isMinutes(_ item: Item) -> Bool {
        if case .minutes = item.kind { return true }
        return false
    }

    private func isFlag(_ item: Item) -> Bool {
        if case .flag = item.kind { return true }
        return false
    }

    private func isMode(_ item: Item) -> Bool {
        if case .mode = item.kind { return true }
        return false
    }

    private func modeOptions(_ item: Item) -> [(value: String, label: String)] {
        if case .mode(let options) = item.kind { return options }
        return []
    }

    /// 系统里的真值。读不到就是「—」，不拿 0 冒充。
    private func currentValue(_ key: String) -> String {
        controller.powerSettings[key] ?? "—"
    }

    private func currentValueText(_ item: Item) -> String {
        let value = currentValue(item.key)
        if isMinutes(item) {
            guard value != "—", let minutes = Int(value) else { return "当前 —" }
            return minutes == 0 ? "当前 0 分钟（从不）" : "当前 \(minutes) 分钟"
        }
        return "当前 \(value)"
    }

    private func minutesFromCurrent(_ key: String) -> Int {
        guard let value = Int(currentValue(key)) else { return 0 }
        return min(max(value, Self.minuteRange.lowerBound), Self.minuteRange.upperBound)
    }

    private func minuteBinding(_ key: String) -> Binding<Int> {
        Binding(
            get: {
                if let draft = drafts[key], let minutes = Int(draft) { return minutes }
                return minutesFromCurrent(key)
            },
            set: { drafts[key] = "\($0)" }
        )
    }
}
