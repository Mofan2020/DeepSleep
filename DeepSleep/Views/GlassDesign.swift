//
//  GlassDesign.swift
//  Deep Sleep
//
//  液态玻璃层：macOS 26 的 `glassEffect` 在全 App 的统一用法。
//
//  ## 与 DesignSystem.swift 的分工
//
//  `DesignSystem.swift` 是**令牌**（间距 / 圆角 / 语义色 / 动效）与
//  基础容器（`glassCard` / `insetPanel` / `glassSurface`）。
//  本文件是**玻璃质感**这一层：把「要多强的玻璃」变成几个具名的档位，
//  页面只写档位名，不直接碰 `glassEffect` 的参数。
//
//  ## 为什么单独一层
//
//  `glassEffect` 有四个维度：玻璃类型（regular / clear / identity）、
//  着色（tint）、是否交互（interactive）、形状。四个维度自由组合
//  就是四个维度的自由发挥 —— 27 个页面各写各的，界面必然不统一。
//  所以在这里定死四档，每一档有明确的用途。
//
//  ## 四档的用途
//
//    - `.hero`      页面上最该被看见的那一个（首屏状态卡）。
//                  regular + 强描边，最「实」，放最上面。
//    - `.card`      页面上的主要容器（SectionCard）。regular，
//                  系统会随内容滚动自动变形，是液态玻璃的主用法。
//    - `.panel`     卡片内部的次级块。clear，比卡片更透，
//                  用来表达「这是卡片里面的一部分」。
//    - `.button`    可点的东西。regular + interactive，
//                  鼠标压上去会有玻璃的物理反馈。
//
//  ## 一条硬规则：玻璃不能当底色铺满
//
//  玻璃材质会折射背后的东西。满屏玻璃 = 满屏扭曲 = 看不清字。
//  所以：玻璃只用在**有边界的容器**上（卡片 / 面板 / 按钮），
//  页面背景仍然是系统默认底色。这是 Apple 自己的用法（设置、
//  工具栏都是「玻璃浮在普通背景上」），不是「整页玻璃」。
//

import SwiftUI

// MARK: - 玻璃档位

/// 玻璃质感的档位。
///
/// 页面只写档位，不写 `glassEffect` 的参数 —— 这样玻璃的强度在
/// 全 App 是统一的，改一处全 App 跟着变。
enum GlassLevel {

    /// 首屏焦点容器（首屏状态卡）。最实的玻璃。
    case hero
    /// 页面主要容器（卡片）。
    case card
    /// 卡片内的次级分区。更透。
    case panel
    /// 可点元素。有交互反馈。
    case button

    /// 这一档的玻璃类型。
    var glass: Glass {
        switch self {
        case .hero:      return .regular
        case .card:      return .regular
        case .panel:     return .clear
        case .button:    return .regular
        }
    }

    /// 这一档是否带交互反馈（鼠标压上去玻璃会跟着动）。
    var isInteractive: Bool {
        self == .button
    }

    /// 这一档的描边强度。
    ///
    /// 玻璃本身没有边框，靠描边把边界画出来。越「浮」的层次
    /// 描边越淡 —— 描边是「这里有个边界」的信号，不是装饰。
    var strokeOpacity: Double {
        switch self {
        case .hero:      return 0.22
        case .card:      return 0.14
        case .panel:     return 0.08
        case .button:    return 0.16
        }
    }

    /// 这一档的圆角。
    var cornerRadius: CGFloat {
        switch self {
        case .hero:      return DS.Radius.hero
        case .card:      return DS.Radius.card
        case .panel:     return DS.Radius.insetRadius
        case .button:    return DS.Radius.control
        }
    }
}

// MARK: - 应用玻璃

extension View {

    /// 给视图套上液态玻璃。
    ///
    /// - Parameters:
    ///   - level: 玻璃档位。决定玻璃类型、描边强度与圆角。
    ///   - tint: 着色。nil 表示不着色（默认的玻璃色）。
    ///   - cornerRadius: 覆盖档位自带的圆角。默认 nil = 用档位的。
    func glassSurface(
        level: GlassLevel,
        tint: Color? = nil,
        cornerRadius: CGFloat? = nil
    ) -> some View {
        let radius = cornerRadius ?? level.cornerRadius
        var glass = level.glass
        if let tint {
            glass = glass.tint(tint)
        }
        if level.isInteractive {
            glass = glass.interactive()
        }
        return self
            .glassEffect(glass, in: .rect(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(level.strokeOpacity))
            )
    }

    /// 一块玻璃面板（带内边距）。
    ///
    /// 页面上最常用的形态：一个有边界、有层次的块。
    func glassPanel(
        level: GlassLevel = .card,
        tint: Color? = nil,
        padding: CGFloat = DS.Space.md
    ) -> some View {
        self
            .padding(padding)
            .glassSurface(level: level, tint: tint)
    }
}

// MARK: - 玻璃容器

/// 把一组玻璃元素放进同一个 `GlassEffectContainer`。
///
/// **为什么要这个**：系统默认把每个玻璃元素当成独立的形状渲染。
/// 放在一起时相邻的玻璃会各自折射，边界处出现难看的接缝。
/// `GlassEffectContainer` 让它们在同一个层里融合，接缝消失 ——
/// 这正是「液态」的关键。
///
/// 用法：把并列的玻璃卡片包进去。**不要**为了融合而把不相邻的东西
/// 硬塞进同一个容器 —— 那会让不相干的元素之间也出现融合关系。
struct GlassGroup<Content: View>: View {

    /// 元素之间的间距。nil 表示用系统的默认值。
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content
        }
    }
}

// MARK: - 玻璃按钮

/// 玻璃按钮。
///
/// 用在「次要但可点」的位置（工具卡片的次级动作、仪表盘快捷入口）。
/// 主操作仍然用系统的 `.borderedProminent` —— 那是有品牌色的实心按钮，
/// 玻璃按钮抢不走它的注意力层级。
struct GlassButtonStyle: ButtonStyle {

    /// 按钮里的内容。默认 nil = 不额外着色。
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassSurface(level: .button, tint: tint)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
