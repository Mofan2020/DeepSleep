//
//  Components.swift
//  Deep Sleep
//
//  跨页面复用的界面组件。
//
//  约束（改之前先读）：
//  - 所有尺寸、圆角、颜色都走 `DesignSystem.swift` 里的令牌，
//    这里不再出现字面量间距。
//  - 组件签名保持向后兼容：现有 27 个页面的调用点零改动即可继续编译。
//    新增能力用**带默认值的可选参数**加，不要重排参数顺序
//    —— `content` 必须永远是最后一个参数，否则所有尾随闭包调用点会错位。
//  - 容器一律用 `glassCard` / `insetPanel`，不要在这里另造背景。
//

import SwiftUI

// MARK: - 卡片

/// 统一样式的卡片容器。
struct SectionCard<Content: View>: View {

    let title: String
    var subtitle: String?
    var symbol: String?
    var accent: Color = .accentColor
    /// 标题栏右侧的附加控件。默认没有。
    var accessory: AnyView?

    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        accent: Color = .accentColor,
        accessory: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.accent = accent
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(accent)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(title)
                    .font(.headline)
                Spacer(minLength: DS.Space.sm)
                if let accessory {
                    accessory
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

// MARK: - 小标签

/// 小标签。
struct Tag: View {

    let text: String
    var color: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.xxs)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - 状态指示

/// 状态指示灯 + 文案。
struct StatusPill: View {

    let text: String
    let isActive: Bool
    /// 状态色。**只作用于圆点与底色** —— 文字始终是 primary。
    ///
    /// 传 nil 时行为与从前完全一致（运行中绿 / 已停止灰）。
    var color: Color?

    private var dotColor: Color {
        if let color { return color }
        return isActive ? DS.Tone.good : DS.Tone.idle.opacity(0.5)
    }

    private var backgroundColor: Color {
        if let color { return color.opacity(0.14) }
        return isActive ? DS.Tone.good.opacity(0.14) : DS.Tone.idle.opacity(0.12)
    }

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.xs)
        .background(backgroundColor, in: Capsule())
    }
}

// MARK: - 断言开关行

/// 一键式 assertion 开关行。
struct AssertionRow: View {

    let kind: AssertionKind
    @EnvironmentObject private var controller: SleepController

    private var isRuleDriven: Bool { controller.ruleAssertions.contains(kind) }
    /// 「完全禁止系统睡眠」会额外持有一枚 PreventSystemSleep 断言作为加固。
    private var isSleepDisabledBacking: Bool {
        controller.sleepDisabledBacking && kind == .preventSystemSleep
    }

    /// 标记合并成一个胶囊。
    ///
    /// 从前一行最多挂三个 Tag（"需完全控制" / "自动化维持" / "由完全禁止睡眠加固"），
    /// 四个断言就是十二个小胶囊，屏幕上的噪声比信息多。合并成一个之后，
    /// 一行最多一个胶囊。
    private var badgeText: String? {
        var parts: [String] = []
        if kind.requiresPrivilege { parts.append("需完全控制") }
        if isRuleDriven { parts.append("自动化维持") }
        if isSleepDisabledBacking { parts.append("睡眠加固") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var badgeColor: Color {
        if isSleepDisabledBacking { return .orange }
        if kind.requiresPrivilege { return .orange }
        return .purple
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.md) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 15))
                .frame(width: 24)
                .foregroundStyle(controller.activeAssertions.contains(kind) ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.sm) {
                    Text(kind.title)
                        .font(.body.weight(.medium))
                    if let badgeText {
                        Tag(text: badgeText, color: badgeColor)
                    }
                }
                Text(kind.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DS.Space.sm)

            Toggle("", isOn: Binding(
                get: { controller.activeAssertions.contains(kind) },
                set: { newValue in
                    Task { await controller.setAssertion(kind, enabled: newValue) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.vertical, DS.Space.xxs)
    }
}

// MARK: - 设置行

/// 键值设置行，可附带「应用」按钮。
struct SettingRow: View {

    let title: String
    let detail: String
    let key: String
    let currentValue: String
    let isEditable: Bool
    let onApply: (String) -> Void

    @State private var draft: String = ""

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.sm)
            TextField("", text: $draft)
                .frame(width: 74)
                .textFieldStyle(.roundedBorder)
                .disabled(!isEditable)
                .onSubmit { apply() }
            Text("当前 \(currentValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Button("应用") { apply() }
                .disabled(!isEditable || draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.vertical, DS.Space.xxs)
        .onAppear { draft = currentValue }
        .onChange(of: currentValue) { _, newValue in draft = newValue }
    }

    private func apply() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        onApply(value)
    }
}

// MARK: - 横幅

/// 顶部横幅，用于展示最近一次操作结果。
struct BannerView: View {

    let banner: Banner
    let onDismiss: () -> Void

    private var color: Color {
        switch banner.level {
        case .success: return DS.Tone.good
        case .error:   return DS.Tone.critical
        case .info:    return DS.Tone.info
        }
    }

    private var symbol: String {
        switch banner.level {
        case .success: return "checkmark.circle.fill"
        case .error:   return "exclamationmark.triangle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(banner.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.sm)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.md)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .strokeBorder(color.opacity(0.28))
        )
    }
}

// MARK: - 页面布局

extension View {
    /// 页面统一的内边距与最大宽度。
    ///
    /// `maxWidth` 默认 760 —— 与从前一致，其他页面调用点零改动。
    /// 工具箱页要排 3 列卡片，需要更宽的内容区（980）。
    func pageLayout(maxWidth: CGFloat = 760) -> some View {
        self
            .padding(DS.Space.xl)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
