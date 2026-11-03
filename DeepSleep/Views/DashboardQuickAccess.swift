//
//  DashboardQuickAccess.swift
//  Deep Sleep
//
//  仪表盘上的「快速访问」：把工具箱里置顶的工具直接摆出来，点一下就进去。
//
//  设计约束（改动前先读）：
//  - 数据源是工具箱的同一份布局（`ToolboxStore.load()`），不另存一份。
//    用户在工具箱页改置顶，回到仪表盘就生效。
//  - **只显示置顶的**。没有置顶时整块不出现 —— 不放空态占位，
//    仪表盘是「一屏看完」的页面，多一块空的比没有更糟。
//  - 每格只放图标 + 标题。工具的说明文字（desc）在这里是噪音：
//    想知道就点进去。
//  - 卡片是唯一的容器单位 —— 每格用 `glassCard()`，不自己造第二种背景。
//  - 间距、圆角只用 `DS` 令牌。
//
//

import SwiftUI

// MARK: - 快速访问区块

/// 置顶工具的快捷入口网格。
///
/// 放在仪表盘的状态卡与「保持清醒」之间：状态看完，接下来最常做的事
/// 就是进某个工具，入口摆在这一段比藏在工具箱里少两步。
struct DashboardQuickAccess: View {

    /// 要显示的工具（调用方给的是置顶的那些，按置顶顺序）。
    let tools: [ToolboxTool]

    /// 点某个工具。由调用方负责切到对应页面。
    let onOpen: (ToolboxTool) -> Void

    /// 自适应列宽：窄窗一行两个，宽窗一行四个。放得下就放，不切固定列数。
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: DS.Space.md)]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            header

            LazyVGrid(columns: columns, spacing: DS.Space.md) {
                ForEach(tools) { tool in
                    QuickAccessTile(tool: tool) {
                        onOpen(tool)
                    }
                }
            }
        }
    }

    /// 区块标题。跟 SectionCard 的标题同一套写法（图标 + 标题），
    /// 但这里不带卡片外壳 —— 外壳是每一格自己的。
    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "pin.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Tone.info)
            Text("快速访问")
                .font(.headline)
            Spacer(minLength: DS.Space.sm)
        }
    }
}

// MARK: - 单个入口

/// 一格工具入口：图标 + 标题，可点。
///
/// 用 `.plain` 按钮样式：卡片本身已经是玻璃容器，再叠一层系统按钮
/// 外观会出现两重边框。按压反馈自己给。
struct QuickAccessTile: View {

    let tool: ToolboxTool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Tone.info)
                    .frame(width: 18)

                Text(tool.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovering ? 0.18 : 0))
            )
        }
        .buttonStyle(QuickAccessTileStyle())
        .onHover { isHovering = $0 }
        .accessibilityLabel(tool.title)
        .accessibilityHint("打开\(tool.title)工具")
    }
}

// MARK: - 按压反馈

/// 入口格子的按压反馈：轻微缩放。
///
/// 「减弱动态效果」开着时不缩放 —— 缩放只是锦上添花，不能替代状态本身。
struct QuickAccessTileStyle: ButtonStyle {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(DS.Animation.quick, value: configuration.isPressed)
    }
}
