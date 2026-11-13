//
//  DesignSystem.swift
//  Deep Sleep
//
//  设计系统：唯一的令牌来源 + 容器与动效规范。
//
//  改页面之前先读这五条：
//  1. 页面里**不再出现字面量的间距、圆角、阴影** —— 一律走
//     `DS.Space` / `DS.Radius` / `DS.Depth`。以前 27 个页面里散着
//     12 种圆角、6 种水平内边距，全靠人记，是 UI 不一致的根因。
//  2. **颜色只表达语义**（好 / 注意 / 危险 / 中性 / 强调），不做装饰。
//     不要为了好看给某个卡片挑颜色。
//  3. **卡片是唯一的容器单位**。页面上不要再自己造第二种卡片背景
//     （自己写的 `.background(.regularMaterial)`、`.fill(.quaternary)` 都算）。
//  4. **状态永远用「颜色 + 文字」双编码**，不能只靠颜色区分 —— 无障碍要求。
//     例：温度分档要写「正常 / 偏高 / 过高 / 紧急」，不能只把字染红。
//  5. 动效尊重 `accessibilityReduceMotion`，统一用 `DS.Animation`。
//
//  层级（玻璃分层）：
//    L0  窗口背景      系统默认
//    L1  卡片         `glassCard`  —— 页面上的主容器
//    L2  卡内分区     `insetPanel` —— 卡片内部的次级块
//    L3  控件         SwiftUI 原生控件（Toggle / Picker / Slider / Gauge / Table）
//

import SwiftUI

// MARK: - 设计令牌

enum DS {

    // MARK: 间距

    /// 间距刻度。基数 4，允许 2（图标与文字之间）。
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    // MARK: 圆角

    enum Radius {
        /// 输入框、按钮、图标底板
        static let control: CGFloat = 8
        /// 小标签底板
        static let chip: CGFloat = 12
        /// 卡片
        static let card: CGFloat = 16
        /// 页面焦点卡（首屏 hero）
        static let hero: CGFloat = 20
    }

    // MARK: 语义色

    /// 状态色。取用时必须同时给出文字说明（见文件头规则 4）。
    enum Tone {
        /// 正常 / 生效中
        static let good = Color.green
        /// 需要注意 / 降级运行
        static let caution = Color.orange
        /// 失败 / 危险阈值
        static let critical = Color.red
        /// 注意，但还没到危险。
        ///
        /// 为什么单独加这一档：温度是四档（正常 / 偏高 / 过高 / 紧急），
        /// 四档必须彼此可分 —— 而 good / caution / critical 已经被
        /// 「正常 / 过高 / 紧急」占掉了，「偏高」这一档原本没有落点，
        /// 只能直接用 Color.yellow 写在页面里（装饰色漏进页面）。
        ///
        /// 不能拿 caution 顶替：那样「偏高」和「过高」就同色，
        /// 颜色 + 文字的双编码只剩一半意思，用户分不出两档。
        static let notice = Color.yellow
        /// 强调、进行中
        static let info = Color.accentColor
        /// 未启用 / 静默
        static let idle = Color.secondary

        /// 卡片描边（细）
        static let hairline = Color.primary.opacity(0.10)
        /// 需要强调时的描边
        static let hairlineStrong = Color.primary.opacity(0.18)
    }

    // MARK: 尺寸

    /// 固定尺寸。跟间距一样是「不能写死」的量 —— 写进令牌里，
    /// 换尺寸时只改一处，页面里不会出现第二个魔法数字。
    enum Metric {
        /// 环形仪表的直径。仪表盘顶部那个圈。
        ///
        /// 从 72 调到 84：仪表盘改成「一屏装得下」之后，顶部状态卡
        /// 跟下方内容之间的视觉权重差变小了，72 的圈看起来偏小、
        /// 不像这一页的主状态。84 跟旁边 title2 的标题大小配得上。
        static let gaugeDiameter: CGFloat = 84

        /// 图标按钮里**图标本体**的边长。
        ///
        /// 只是把「图标画多大」收进令牌：视觉尺寸不变（还是 24），
        /// 但页面里不再散着 24 这个字面量 —— 同一个图标在几个页面
        /// 长得不一样，根源就是每处各写各的数字。
        static let iconButtonSize: CGFloat = 24

        /// 触控目标的最小边长。
        ///
        /// 图标本体可以小（见 iconButtonSize），但**热区**不能小：
        /// 24pt 的图标在触控板上很难点中。热区统一抬到 44pt，
        /// 视觉尺寸保持不变 —— 用户看到的是同一个图标，
        /// 只是手不用瞄那么准。
        static let minimumTouchTarget: CGFloat = 44

        /// 工具箱卡片里图标徽板的边长。
        ///
        /// 徽板是装饰，30pt 就够；但它的热区另有尺寸
        /// （见 minimumTouchTarget），两者分开是因为「画多大」和
        /// 「点得准不准」是两个问题。
        static let toolIconSize: CGFloat = 30

        /// 「应用无响应」提示面板里的图标边长。
        static let alertIconSize: CGFloat = 40

        /// 「应用无响应」提示面板的宽度。
        ///
        /// 面板是固定宽度的（宿主视图也按这个宽度约束），所以这个数
        /// 同时被 SwiftUI 视图和 AppKit 约束引用 —— 收进令牌是为了
        /// 两边不会各写各的、宽度对不上。
        static let alertPanelWidth: CGFloat = 340
    }

    // MARK: 动效

    enum Animation {
        /// 状态切换、hover
        static let quick = SwiftUI.Animation.easeOut(duration: 0.15)
        /// 布局重排（置顶、增删）
        static let bouncy = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.85)
    }
}

// MARK: - 容器

extension View {

    /// L1 卡片容器：液态玻璃 + 细描边。
    ///
    /// 页面上的每一个独立区块都套它，不要自己写 `.background(.regularMaterial)`。
    ///
    /// 玻璃材质的细节（类型 / 描边 / 圆角）由 `GlassLevel.card` 统一决定 ——
    /// 见 `GlassDesign.swift`。页面不直接调 `glassEffect`。
    func glassCard(cornerRadius: CGFloat = DS.Radius.card) -> some View {
        self
            .glassSurface(level: .card, cornerRadius: cornerRadius)
    }

    /// L2 卡片内分区：比卡片再低一层，用于卡内成组的次级信息。
    func insetPanel(cornerRadius: CGFloat = DS.Radius.insetRadius) -> some View {
        self
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }

    /// 焦点容器：macOS 26 玻璃材质。
    ///
    /// **只用在页面上最该被看见的一两个元素**（首屏状态卡、浮层、
    /// 侧边栏底部摘要）。整页都用玻璃会互相干扰，反而更乱。
    func glassSurface(cornerRadius: CGFloat = DS.Radius.hero) -> some View {
        self.glassSurface(level: .hero, cornerRadius: cornerRadius)
    }
}

extension DS.Radius {
    /// 卡片内分区的圆角。
    static let insetRadius: CGFloat = 12
}

// MARK: - 排版

extension View {
    /// 数值排版：等宽数字，避免读数跳动时抖来抖去。
    func metricNumber(_ size: CGFloat = 22) -> some View {
        self
            .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
    }

    /// 次要说明文字。
    func caption2() -> some View {
        self.font(.caption2).foregroundStyle(.secondary)
    }
}

// MARK: - 组件：指标块

/// 一个大数值 + 标题 + 状态词。
///
/// 状态词是**必须**的：只有颜色区分不了「偏高」和「过高」（规则 4）。
struct MetricTile: View {

    let title: String
    let value: String
    /// 值的单位，例如 "°C"、"%"。没有就传 nil。
    var unit: String?
    /// 状态词，例如「正常」「偏高」。没有就传 nil。
    var status: String?
    /// 状态色。传 nil 时用 primary。
    var tint: Color?
    /// 0...1 的进度。传 nil 时不画进度条。
    var progress: Double?
    var symbol: String?

    private var valueColor: Color { tint ?? .primary }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(valueColor)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .metricNumber()
                    .foregroundStyle(valueColor)
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(valueColor)
            }

            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .controlSize(.small)
                    .tint(valueColor)
                    .padding(.top, DS.Space.xxs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.md)
        .insetPanel()
    }
}

// MARK: - 组件：空态

/// 空态 / 无数据。
///
/// 用系统的 `ContentUnavailableView`，不要自己画一个图标加一行字。
struct EmptyStateView: View {

    let title: String
    var message: String?
    var systemImage: String = "tray"
    /// 可选的主操作。
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 组件：页面内小标题

/// 卡片内的一组小标题（用于卡片里再分组时）。
struct SubsectionHeader: View {

    let title: String
    var symbol: String?
    var accessory: String?

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: DS.Space.sm)
            if let accessory {
                Text(accessory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
