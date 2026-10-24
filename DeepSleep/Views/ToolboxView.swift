//
//  ToolboxView.swift
//  Deep Sleep
//
//  工具箱页：把散在侧边栏的工具收进一张卡片网格，支持置顶。
//
//  设计约束（改动前先读）：
//  - 进入方式是**切换 detail 列的 selection**，不是 NavigationLink 推栈。
//    NavigationSplitView 的 detail 列没有 NavigationStack，要推就得把整个
//    detail 列包成 NavigationStack —— 那会影响应用里每一个页面的导航行为。
//    所以工具卡片只是换 selection，三个旧工具页一行都不用改。
//  - 工具箱页只读轻量状态（助手状态、保活引擎）。
//    **不触发任何重 IO**：进程快照要 4~5 秒，放在这一页会卡住整页。
//    「共 N 个进程」这种元信息因此不做 —— 详见 docs/notes.md。
//  - 置顶机制已解决「常用的放前面」，所以不提供拖拽排序。
//

import SwiftUI

// MARK: - 工具的界面属性

extension ToolboxTool {

    /// 目标页对应的侧边栏项。工具箱页通过切 selection 进入目标页。
    var sidebarItem: SidebarItem {
        switch self {
        case .nice:           return .nice
        case .hosts:          return .hosts
        case .quarantine:     return .quarantine
        case .aiKeepAlive:    return .aiKeepAlive
        }
    }
}

// MARK: - 工具箱页

/// 工具箱页。挂在 ContentView 的 detail 列（selection = .toolbox）。
struct ToolboxView: View {

    @EnvironmentObject private var controller: SleepController
    @ObservedObject private var keepAlive = KeepAliveEngine.shared

    /// 选中某个工具。调用方（ContentView）负责切 selection。
    let onSelect: (ToolboxTool) -> Void

    @State private var layout = ToolboxStore.load()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topBar
            if tools.isEmpty {
                emptyState
            } else {
                grid
            }
        }
    }

    // MARK: - 顶部细行

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("\(tools.count) 个工具")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("重置排序") {
                layout = .default
                ToolboxStore.save(layout)
            }
            .controlSize(.small)
            .disabled(layout.isDefault)
            .help("恢复默认顺序并清空置顶")
        }
        .frame(height: 24)
    }

    // MARK: - 网格

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280), spacing: 14)],
            spacing: 14
        ) {
            ForEach(tools) { tool in
                card(for: tool)
            }
        }
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.15)
                : .spring(response: 0.3, dampingFraction: 0.85),
            value: layout
        )
    }

    private func card(for tool: ToolboxTool) -> some View {
        ToolCard(
            title: tool.title,
            desc: tool.desc,
            symbol: tool.symbol,
            status: status(for: tool),
            meta: meta(for: tool),
            isPinned: layout.isPinned(tool),
            onOpen: { onSelect(tool) },
            onTogglePin: {
                layout = layout.togglingPin(tool)
                ToolboxStore.save(layout)
            }
        )
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("当前没有可用的工具")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 状态

    private var tools: [ToolboxTool] { layout.orderedTools }

    /// 状态行。数据源全部是只读、单次、廉价的。
    private func status(for tool: ToolboxTool) -> ToolCard.Status {
        switch tool {
        case .nice, .hosts:
            // 助手未就绪时卡片仍然可点（进页面后按钮置灰 + 副标题解释，
            // 这是 NiceView / HostsView 的既有约定），所以只改徽章不改可点性。
            return controller.helperState.isReady
                ? ToolCard.Status(text: "可用", isActive: true, color: .green)
                : ToolCard.Status(text: "助手未就绪", isActive: false, color: .orange)
        case .quarantine:
            return ToolCard.Status(text: "可用", isActive: true, color: .green)
        case .aiKeepAlive:
            switch keepAlive.status {
            case .running:
                return ToolCard.Status(text: "运行中", isActive: true, color: .green)
            case .paused:
                return ToolCard.Status(text: "已暂停", isActive: false, color: .secondary)
            case .notConfigured:
                return ToolCard.Status(text: "未配置", isActive: false, color: .secondary)
            case .unavailable:
                return ToolCard.Status(text: "引擎未就绪", isActive: false, color: .orange)
            }
        }
    }

    /// 状态行右侧的元信息。只承载非关键预期信息。
    private func meta(for tool: ToolboxTool) -> String? {
        switch tool {
        case .nice:
            // 进程数只做 `proc_listpids`（0.1 毫秒级）。
            // **不跑** `ProcessInventory.snapshot()` —— 那个要对每个进程做
            // proc_pidinfo + proc_pidpath + 读 nice，历史要 4~5 秒，
            // 放在这一页会卡住整页。
            return "共 \(ToolboxProcessCounter.count) 个进程"
        case .hosts, .quarantine:
            return nil
        case .aiKeepAlive:
            if case .unavailable = keepAlive.status { return nil }
            return "\(keepAlive.tasks.count) 个任务"
        }
    }
}

// MARK: - 进程计数

/// 只数进程个数，不取任何进程详情。
///
/// `proc_listpids` 本身是 0.1 毫秒级的系统调用，与 `ProcessInventory.snapshot()`
/// 完全不同 —— 后者要对每个进程跑 proc_pidinfo + proc_pidpath + 读 nice，
/// 历史上要 4~5 秒。工具箱页只需要一个数字，用后者会把整页拖死。
enum ToolboxProcessCounter {

    /// 当前进程数。读不到时返回 0。
    static var count: Int {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return 0 }
        return Int(bytes) / MemoryLayout<pid_t>.size
    }
}

// MARK: - 工具卡片

/// 工具箱里的一张卡。
///
/// 结构上的两个硬性要求：
///  - ZStack 的子视图顺序必须是 [卡片 Button, pin Button]。后画的在上层 →
///    pin 抢鼠标命中；VoiceOver 焦点按视图树顺序 → 卡片先、pin 后。
///  - pin 按钮不能放进卡片 Button 的 label 里（SwiftUI 里嵌套 Button 行为未定义，
///    VoiceOver 也会把两者合成一个元素）。
struct ToolCard: View {

    /// 状态行内容。
    struct Status {
        let text: String
        let isActive: Bool
        /// 颜色只作用于圆点与底色，文字始终是 primary。
        var color: Color?
    }

    let title: String
    let desc: String
    let symbol: String
    var status: Status
    var meta: String?
    var isPinned: Bool
    /// 视觉降级（图标变灰）。**不等于禁用**。
    var isInactive: Bool = false

    let onOpen: () -> Void
    let onTogglePin: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                onOpen()
            } label: {
                cardBody
            }
            .buttonStyle(ToolCardButtonStyle())
            .accessibilityLabel(title)
            .accessibilityValue(status.text)
            .accessibilityHint("打开\(title)工具")

            Button {
                onTogglePin()
            } label: {
                pinIcon
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPinned ? "取消置顶\(title)" : "置顶\(title)")
            .accessibilityHint("置顶后这张卡会排在工具箱最前面")
            .opacity(isPinned || isHovering ? 1 : 0)
            // 看不见的按钮不该出现在 VoiceOver 焦点序列里。
            .accessibilityHidden(!(isPinned || isHovering))
        }
        .accessibilityElement(children: .contain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button {
                onTogglePin()
            } label: {
                Label(
                    isPinned ? "取消置顶" : "置顶",
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
        }
    }

    // MARK: - 卡片本体

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                iconContainer

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(desc)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(minHeight: 32, alignment: .top)
                }

                Spacer(minLength: 28)
            }

            Divider().padding(.vertical, 12)

            HStack(spacing: 8) {
                StatusPill(
                    text: status.text,
                    isActive: status.isActive,
                    color: status.color
                )
                if let meta {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovering ? 0.16 : 0.08))
        )
    }

    private var iconContainer: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(isInactive ? Color.secondary : Color.accentColor)
            .frame(width: 30, height: 30)
            .background(
                (isInactive ? Color.secondary : Color.accentColor).opacity(0.14),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }

    private var pinIcon: some View {
        Image(systemName: isPinned ? "pin.fill" : "pin")
            .font(.system(size: 14))
            .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .help(isPinned ? "取消置顶" : "置顶")
    }
}

// MARK: - 卡片按钮样式

/// 卡片按钮的按下反馈：轻微缩放 + 背景压一层 primary。
///
/// 用普通 ButtonStyle（不是 PrimitiveButtonStyle）—— 后者的 Configuration
/// 只有 `trigger`，拿不到 `isPressed`，按压反馈就没法自己做。
struct ToolCardButtonStyle: ButtonStyle {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.985 : 1))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.06 : 0))
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
