//
//  Components.swift
//  Deep Sleep
//
//  可复用的 UI 组件。
//

import SwiftUI

/// 统一样式的卡片容器。
struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var accent: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(accent)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

/// 小标签。
struct Tag: View {
    let text: String
    var color: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

/// 状态指示灯 + 文案。
struct StatusPill: View {
    let text: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            (isActive ? Color.green.opacity(0.14) : Color.secondary.opacity(0.12)),
            in: Capsule()
        )
    }
}

/// 一键式 assertion 开关行。
struct AssertionRow: View {
    let kind: AssertionKind
    @EnvironmentObject private var controller: SleepController

    private var isRuleDriven: Bool { controller.ruleAssertions.contains(kind) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 16))
                .frame(width: 26)
                .foregroundStyle(controller.activeAssertions.contains(kind) ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.title)
                        .font(.body.weight(.medium))
                    if kind.requiresPrivilege {
                        Tag(text: "需完全控制", color: .orange)
                    }
                    if isRuleDriven {
                        Tag(text: "自动化维持", color: .purple)
                    }
                }
                Text(kind.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { controller.activeAssertions.contains(kind) },
                set: { newValue in
                    Task { await controller.setAssertion(kind, enabled: newValue) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.vertical, 4)
    }
}

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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
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
        .padding(.vertical, 3)
        .onAppear { draft = currentValue }
        .onChange(of: currentValue) { _, newValue in draft = newValue }
    }

    private func apply() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        onApply(value)
    }
}

/// 顶部横幅，用于展示最近一次操作结果。
struct BannerView: View {
    let banner: Banner
    let onDismiss: () -> Void

    private var color: Color {
        switch banner.level {
        case .success: return .green
        case .error:   return .red
        case .info:    return .accentColor
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
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(banner.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(0.28))
        )
    }
}

extension View {
    /// 页面统一的内边距与最大宽度。
    func pageLayout() -> some View {
        self
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
