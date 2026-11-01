//
//  NiceView.swift
//  Deep Sleep
//
//  「进程优先级（nice）」页面：列出用户态进程、对单个进程改 nice。
//
//  v1.6.1 修复（v1.6.0 卡顿 + 弹窗 bug）：
//
//    - 「调整…」按钮之前直接调 applyNice 而不设 pendingPid，导致
//      `nicePromptBinding` 永不触发，弹窗永远不显示。v1.6.1 起按钮只设状态，
//      真正的弹窗由 `.alert("调整 nice", isPresented:)` 接管。
//
//    - v1.6.0 拉取一次要 4-5 秒、UI 冻住。原因是 `ProcessInventory.snapshot()`
//      在 MainActor 同步跑，~300 个 pid × `proc_pidpath` × `bundlePath` ×
//      `bundleIdentifier` 全部串行 —— 单次数千次系统调用 + 大量
//      `contents(atPath:)` 解析 Info.plist。
//      v1.6.1 起：
//        1. snapshot 改在后台 actor 跑，主线程只负责显示；
//        2. 「默认视图」只显示 pid / name / nice / 是否系统进程；
//        3. executablePath / bundlePath / bundleIdentifier **不**预读，
//           改在用户选中进程时才同步拉取（限流，每秒 4 个）。
//
//  v1.7 起（本次）：
//
//    - 「滚动卡顿」：进程数 ~300，原实现一个 VStack + ForEach 全部塞进视图树，
//      滚动时 SwiftUI 持续重排重绘所有 cell 高度 → 卡顿。
//      v1.7 起改分页：默认每页 20（用户可调 10–30），用 LazyVStack 仅渲染
//      当前页可见 cell；分页控件在卡片顶部 + 底部各一份；
//      搜索过滤后的结果也走同一套分页（页数随过滤结果重算）。
//
//    - 「进程名写全 + 路径可见」：之前主行只显示 name，路径只在选中后才显示
//      在 subtitle 行。这次让 executablePath 默认就在主行副标题里出现，
//      这样用户看到列表就能区分「同进程名多版本」之类的歧义。
//      bundlePath 仍然只在选中时显示（解析 Info.plist 仍然慢）。
//
//  v1.7.1 修复（Nice 弹窗无反应 + 名字截断 + 分页副作用）：
//
//    - 「调整…」按钮看似没反应：v1.6.1/v1.7 用 `.alert(_:isPresented:actions:)`
//      弹窗，actions 闭包里塞了 `Stepper`。SwiftUI alert 在 macOS 上的 actions
//      只接受 Button 系控件（Cancel/Default/Destructive），放 Stepper 会被
//      静默丢弃，整个 alert 不弹。
//      v1.7.1 起改用 `.sheet` 弹一个独立的 `NiceAdjustSheet`，原生支持任意
//      SwiftUI 视图，Stepper + Slider + 文本框都能放。
//
//    - 「进程名截断」：原 HStack 里 name 被 nice 数字（width 40）+ 两个按钮
//      + Spacer 挤到很窄，文本被截掉且不可换行。
//      v1.7.1 起把 ProcessRow 改成三行：
//        第 1 行 进程名（.lineLimit(nil) + .fixedSize 允许多行撑开）
//        第 2 行 路径副标题（仍 .lineLimit(1) + .truncationMode(.middle)）
//        第 3 行 nice + 默认/调整 按钮（HStack 右对齐）
//      进程名长就自然换行，长度信息不再丢失。
//
//    - 「分页副作用导致重绘浪费」：`pagedEntries` 是 computed property，
//      旧实现里直接写 `currentPage = 1` 做钳制，每次 body 求值都会触发
//      setter。视图高频重绘时 = 大量无谓写。
//      v1.7.1 起：钳制只发生在 refresh() / query 变化 / pageSize 变化
//      三个明确的时机，computed property 退化成纯计算。
//
//  2026-11 界面换新（本次）：
//
//    - 进程列表从「手搓 VStack + LazyVStack」换成原生 `Table`：
//      列 = 进程名 / PID / nice 值 / 用户，列头可点排序。
//      `Table` 内部是 NSTableView，自带虚拟化 —— 分页仍保留（用户可见的
//      「每页 N 条」设置在 MonitorConfig 里持久化），但滚动不再由视图树扛。
//    - nice 值直接用原生 `Stepper` 调整（每次步进都走原来的 applyNice，
//      极端值仍走二次确认）。原来只有弹窗里有 Stepper。
//    - 助手未就绪时：操作列整列置灰，页面顶部一行文字说明原因
//      （页面能进，但需要助手的按钮不可用 —— 既有约定）。
//
//  设计原则（与 ProcessInventory / ProcessGuard 的边界一致）：
//    - 不做"通用任务管理器"：只展示改 nice 这件事必需的字段。
//    - 系统进程在表里显示但**不让选**：保护名单 + 系统路径前缀两层过滤，
//      在 UI 上就把它们过滤掉；助手侧再做一次同样过滤以防越权。
//    - 改 nice 走助手（POSIX setpriority 需要 root）。所有"能不能改"的判断
//      不依赖应用侧是否诚实。
//

import SwiftUI
import Darwin

/// 后台 actor：跑 `ProcessInventory.snapshot()` 和 nice 读取，
/// 不污染主线程。
private actor NiceBackgroundActor {
    static let shared = NiceBackgroundActor()
    private init() {}

    func snapshot() -> [RunningProcess] {
        return ProcessInventory.snapshot()
    }

    func nice(of pid: pid_t) -> Int? {
        ProcessPriority.nice(of: pid)
    }

    /// 一次性批量读取一组 pid 的 nice。比按 pid 循环调少一次 actor 切换。
    func nice(ofPids pids: [pid_t]) -> [pid_t: Int?] {
        var result: [pid_t: Int?] = [:]
        for pid in pids {
            result[pid] = ProcessPriority.nice(of: pid)
        }
        return result
    }
}

struct NiceView: View {

    /// 进程表的固定高度。
    ///
    /// 页面本身在 ScrollView 里，Table 必须自己占一个确定的高度，
    /// 否则它会按内容撑开、把外层滚动条顶没。
    private static let processTableHeight: CGFloat = 420

    @EnvironmentObject private var controller: SleepController

    @State private var query: String = ""
    @State private var entries: [Entry] = []
    @State private var isRefreshing = false
    @State private var lastError: String?

    /// 弹窗用的状态。`pendingPid == nil` 时弹窗关闭。
    /// v1.7.1 起触发 .sheet 弹窗，不再用 .alert —— alert 的 actions
    /// 只接受 Button，放 Stepper 会整个被丢弃。
    @State private var pendingPid: pid_t?
    @State private var pendingInitialValue: Int = 0
    @State private var pendingLabel: String = ""

    /// 极端值二级确认
    @State private var pendingExtreme: ExtremePrompt?

    /// 选中行：detail 加载入口
    @State private var selectedPid: pid_t?

    /// 每页进程数。用户可调 10–30；MonitorConfig 持久化。
    @State private var pageSize: Int = NicePageSize.defaultValue

    /// 当前页（1-based）。过滤结果变化时由 refresh / onChange(of: query)
    /// 重置到 1，computed property 内部不再写状态。
    @State private var currentPage: Int = 1

    /// 原生 Table 的排序状态（点列头排序）。
    @State private var sortOrder: [KeyPathComparator<Entry>] = []

    /// Stepper 调整中的临时值。等助手回报成功后才落到 `Entry.nice`，
    /// 失败或取消时回落到真实值 —— 避免界面显示一个没生效的 nice。
    @State private var draftNice: [pid_t: Int] = [:]

    /// 已经拉过 bundle id 的 pid。防止同一条被反复解析 Info.plist。
    @State private var loadedDetailPids: Set<pid_t> = []

    /// 每个 pid 的写请求序号。
    ///
    /// Stepper 连点时会有多个写请求同时在飞；只有序号最新的那个结果才允许
    /// 写回界面，避免「先点的后到」把 nice 显示成旧值。
    @State private var niceApplyToken: [pid_t: Int] = [:]

    /// 简化版 Entry：默认视图装必要字段，路径 / bundle id 按需懒加载
    struct Entry: Identifiable, Equatable {
        let pid: pid_t
        let name: String
        var nice: Int?
        let systemProcess: Bool
        var systemReason: String?
        /// 懒加载：用户首次进入页面时一次性批量预填（`proc_pidpath` 廉价）；
        /// bundlePath 解析 Info.plist 昂贵，仍按需在选中时填。
        var executablePath: String?
        var bundleIdentifier: String?
        /// 属主 uid。快照自带，不额外查系统。
        let uid: uid_t
        /// 属主显示名。刷新时按 uid 算好存进来 —— 不做成 computed property，
        /// 否则排序时每比较一次就要问一次系统（几百行 × log n 次）。
        let ownerName: String
        var id: pid_t { pid }

        /// 排序用：读不到 nice 时排最后（不参与正常区间）。
        var niceSortKey: Int { nice ?? Int.max }

        /// 操作列的排序键。
        ///
        /// 单独一个 keypath（哪怕值就是 pid），是为了不和 PID 列共用同一个
        /// comparator —— 共用会让两列同时亮起排序箭头。
        var actionSortKey: Int { Int(pid) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionCard(
                title: "进程优先级（nice）",
                subtitle: helperSubtitle,
                symbol: "gauge.with.dots.needle.bottom.50percent",
                accent: .accentColor
            ) {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    // 助手未就绪 → 页面能进，但改 nice 的操作不可用。
                    // 原因写在一行里，不让用户猜按钮为什么是灰的。
                    if !controller.helperState.isReady {
                        Label(helperUnavailableReason, systemImage: "lock.shield")
                            .font(.callout)
                            .foregroundStyle(DS.Tone.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: DS.Space.sm) {
                        TextField("按名字或路径过滤", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: query) { _, _ in
                                // 过滤变化 → 页码回到 1
                                currentPage = 1
                            }
                        Button {
                            Task { await refresh() }
                        } label: {
                            if isRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("刷新", systemImage: "arrow.clockwise")
                            }
                        }
                        .controlSize(.small)
                        .disabled(isRefreshing)
                    }

                    PageBar(
                        pageSize: $pageSize,
                        currentPage: $currentPage,
                        totalCount: filteredEntries.count,
                        onPageSizeChange: persistPageSize,
                        onPageChange: { newPage in
                            // 仅当新页码与当前不同时才写，避免无谓 setter。
                            if newPage != currentPage { currentPage = newPage }
                        }
                    )

                    if let err = lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(DS.Tone.critical)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SectionCard(
                title: pageTitle,
                subtitle: pageSubtitle,
                symbol: "list.bullet.indent"
            ) {
                let paged = pagedEntries
                if paged.isEmpty {
                    EmptyStateView(
                        title: emptyTitle,
                        message: emptyMessage,
                        systemImage: "magnifyingglass",
                        actionTitle: "刷新进程列表",
                        action: { Task { await refresh() } }
                    )
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        Table(paged, selection: $selectedPid, sortOrder: $sortOrder) {
                            TableColumn("进程名", value: \.name) { entry in
                                processCell(entry)
                            }
                            TableColumn("PID", value: \.pid) { entry in
                                Text("\(entry.pid)")
                                    .monospacedDigit()
                            }
                            TableColumn("nice", value: \.niceSortKey) { entry in
                                niceCell(entry)
                            }
                            TableColumn("用户", value: \.ownerName) { entry in
                                Text(entry.ownerName)
                                    .lineLimit(1)
                            }
                            // 操作列本身不排序，按 PID 排（与应用内顺序一致）。
                            TableColumn("操作", value: \.actionSortKey) { entry in
                                actionCell(entry)
                            }
                        }
                        .frame(height: Self.processTableHeight)
                        .onChange(of: selectedPid) { _, newPid in
                            // 选中行 → 按需拉 bundle id（原来是在行内点击时触发）。
                            guard let newPid else { return }
                            Task { await ensureDetail(of: newPid) }
                        }

                        PageBar(
                            pageSize: $pageSize,
                            currentPage: $currentPage,
                            totalCount: filteredEntries.count,
                            onPageSizeChange: persistPageSize,
                            onPageChange: { newPage in
                                if newPage != currentPage { currentPage = newPage }
                            }
                        )
                    }
                }
            }

            SectionCard(
                title: "nice 值含义",
                subtitle: nil,
                symbol: "info.circle"
            ) {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    BulletLine("-20 最高优先级（抢 CPU 资源）；+19 最低优先级（让出 CPU）。")
                    BulletLine("正值（>0）也必须走 root —— POSIX 的硬约束，应用层无特权不能 setpriority。")
                    BulletLine("改错值会让系统变卡：负值会跟系统进程抢 CPU。系统进程一律被 Deep Sleep 拒绝。")
                    BulletLine("本工具等价于 `sudo renice <value> <pid>`。")
                }
            }
        }
        .task {
            // 一次性读取持久化的 pageSize（如果有）。
            pageSize = NicePageSize.clamp(MonitorConfig.load().nicePageSize)
            await refresh()
        }
        // v1.7.1：调整 nice 弹窗改用 .sheet（.alert 装不下 Stepper）。
        // .sheet 没有原生 title 参数 —— 自己用 HStack + 关闭按钮当 header。
        .sheet(
            isPresented: niceSheetBinding,
            onDismiss: { pendingPid = nil }
        ) {
            NiceAdjustSheet(
                title: "调整 \(pendingLabel) 的 nice",
                initialValue: pendingInitialValue,
                onApply: { newValue in
                    if let pid = pendingPid {
                        let v = newValue
                        let label = pendingLabel
                        pendingPid = nil
                        Task { await applyNice(pid: pid, value: v, label: label) }
                    }
                },
                onCancel: {
                    pendingPid = nil
                }
            )
        }
        .alert(item: $pendingExtreme) { prompt in
            Alert(
                title: Text("极端值确认"),
                message: Text(prompt.message + "\n\n确认要继续吗？"),
                primaryButton: .destructive(Text("仍然继续"), action: {
                    let pid = prompt.pid
                    let v = prompt.value
                    let token = prompt.token
                    pendingExtreme = nil
                    Task { await reallyApplyNice(pid: pid, value: v, token: token) }
                }),
                secondaryButton: .cancel(Text("取消"), action: {
                    let pid = prompt.pid
                    pendingExtreme = nil
                    // 取消 → 临时值回落到真实值，别让界面停在没生效的 nice 上。
                    draftNice[pid] = nil
                })
            )
        }
    }

    // MARK: - 表格单元

    /// 进程名列：名字 + 路径副标题。
    ///
    /// 名字允许多行撑开（长名字不再被截掉），路径单行 + 中间省略。
    @ViewBuilder
    private func processCell(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Text(entry.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if entry.systemProcess {
                    Tag(text: "系统", color: DS.Tone.idle)
                }
            }
            Text(subtitle(for: entry))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            // bundle id 只在选中后展开（解析 Info.plist 昂贵）。
            if let bundle = entry.bundleIdentifier, !bundle.isEmpty {
                Text("bundle: \(bundle)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    /// nice 列：数值 + 语义词（颜色 + 文字双编码）+ 原生 Stepper。
    @ViewBuilder
    private func niceCell(_ entry: Entry) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(niceDisplay(entry))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(niceColor(entry))
            Text(niceStatus(entry))
                .font(.caption2)
                .foregroundStyle(niceColor(entry))
                .lineLimit(1)
            Stepper("", value: niceStepperBinding(entry), in: NiceLevel.minValue...NiceLevel.maxValue)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("调整 \(entry.name) 的 nice")
                .disabled(!canAdjust(entry))
        }
    }

    /// 操作列：恢复默认 + 打开精确调整弹窗。
    ///
    /// 助手未就绪或系统进程时整列置灰。
    @ViewBuilder
    private func actionCell(_ entry: Entry) -> some View {
        HStack(spacing: DS.Space.xs) {
            Button("默认") {
                Task { await applyNice(pid: entry.pid, value: NiceLevel.defaultValue, label: entry.name) }
            }
            .controlSize(.small)
            .disabled(!canAdjust(entry))
            Button("调整…") {
                pendingPid = entry.pid
                pendingInitialValue = entry.nice ?? NiceLevel.defaultValue
                pendingLabel = entry.name
            }
            .controlSize(.small)
            .disabled(!canAdjust(entry))
        }
        .opacity(canAdjust(entry) ? 1 : 0.45)
    }

    // MARK: - 派生

    /// .sheet 用 binding。`pendingPid != nil` 时弹起；onDismiss 把 pendingPid 清空。
    private var niceSheetBinding: Binding<Bool> {
        Binding(
            get: { pendingPid != nil },
            set: { if !$0 { pendingPid = nil } }
        )
    }

    /// 助手没就绪时的一行说明（不是错误，是「还没开权限」）。
    private var helperUnavailableReason: String {
        "助手未就绪（\(controller.helperState.title)）：可以查看，改 nice 需要先在「完全控制」页启用。"
    }

    private var helperSubtitle: String {
        if !controller.helperState.isReady {
            return "助手未就绪：当前只能看，改 nice 需要先启用「完全控制」。"
        }
        if entries.isEmpty {
            return "点击「刷新」拉取进程列表。"
        }
        return "共 \(entries.count) 个用户态进程可调整 nice。"
    }

    private var pageTitle: String {
        filteredEntries.isEmpty
            ? "可选进程"
            : "可选进程（第 \(currentPage) / \(totalPages) 页）"
    }

    private var pageSubtitle: String {
        if filteredEntries.isEmpty {
            return "系统进程与保护名单里的应用已过滤掉；改 nice 走特权助手，需要先启用「完全控制」。"
        }
        let showing = pagedEntries.count
        let first = (currentPage - 1) * pageSize + 1
        let last = first + showing - 1
        return "本页 \(first)–\(last)，共 \(filteredEntries.count) 个匹配。"
    }

    private var emptyTitle: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "没有可调整的进程"
            : "没有匹配的进程"
    }

    private var emptyMessage: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "系统进程与保护名单里的应用已被过滤掉，点「刷新」重新拉一次进程列表。"
        }
        return "没有匹配「\(query)」的进程，换个关键字试试。"
    }

    /// 过滤后的全量条目（不分页）。纯计算，不写状态。
    private var filteredEntries: [Entry] {
        filter(entries)
    }

    /// 当前页的条目。纯计算。
    ///
    /// v1.7.1 起：钳制 currentPage 的逻辑移到了 refresh / query.onChange /
    /// pageSize.onChange（详见 PageBar 的 binding setter）。这里只读，
    /// 避免每次 body 求值都触发 setter。
    ///
    /// 2026-11 起：排序也在这一层做 —— 先按 Table 的排序状态排全量，
    /// 再切出当前页，这样点列头排序是全局排序而不是页内排序。
    private var pagedEntries: [Entry] {
        let sorted = sortedEntries
        guard !sorted.isEmpty else { return [] }
        let totalPages = max(1, (sorted.count + pageSize - 1) / pageSize)
        let page = max(1, min(currentPage, totalPages))
        let start = (page - 1) * pageSize
        let end = min(start + pageSize, sorted.count)
        return Array(sorted[start..<end])
    }

    /// 按 Table 的列头排序状态排全量。纯计算。
    private var sortedEntries: [Entry] {
        let base = filteredEntries
        guard let comparator = sortOrder.first else { return base }
        return base.sorted { comparator.compare($0, $1) == .orderedAscending }
    }

    private var totalPages: Int {
        max(1, (filteredEntries.count + pageSize - 1) / pageSize)
    }

    private func filter(_ list: [Entry]) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.name.lowercased().contains(q)
                || ($0.executablePath?.lowercased().contains(q) ?? false)
                || ($0.bundleIdentifier?.lowercased().contains(q) ?? false)
        }
    }

    /// 这个进程能不能改 nice。
    ///
    /// 两个条件：助手就绪（POSIX setpriority 需要 root）+ 不是系统进程。
    private func canAdjust(_ entry: Entry) -> Bool {
        controller.helperState.isReady && !entry.systemProcess
    }

    /// Stepper 的绑定：步进即提交（走原来的 applyNice 路径）。
    ///
    /// 临时值先落在 `draftNice`，助手回报成功后才写回 `Entry.nice`；
    /// 失败或用户取消 → 回落显示真实值。
    private func niceStepperBinding(_ entry: Entry) -> Binding<Int> {
        Binding(
            get: { draftNice[entry.pid] ?? entry.nice ?? NiceLevel.defaultValue },
            set: { newValue in
                draftNice[entry.pid] = newValue
                let pid = entry.pid
                let label = entry.name
                // 连点 Stepper 时多个请求会同时在飞，用序号保证「最后一次点击赢」。
                let token = (niceApplyToken[pid] ?? 0) + 1
                niceApplyToken[pid] = token
                Task {
                    await applyNice(pid: pid, value: newValue, label: label, token: token)
                }
            }
        )
    }

    private func subtitle(for entry: Entry) -> String {
        if let path = entry.executablePath, !path.isEmpty {
            return path
        }
        return "pid \(entry.pid)"
    }

    private func niceDisplay(_ entry: Entry) -> String {
        guard let n = entry.nice else { return "—" }
        return NiceLevel.format(n)
    }

    /// nice 的语义词。状态永远「颜色 + 文字」双编码，不能只靠颜色。
    private func niceStatus(_ entry: Entry) -> String {
        guard let n = entry.nice else { return "未知" }
        switch n {
        case ..<0:  return "抢 CPU"
        case 0:     return "默认"
        default:    return "让出 CPU"
        }
    }

    private func niceColor(_ entry: Entry) -> Color {
        guard let n = entry.nice else { return DS.Tone.idle }
        if n < 0 { return DS.Tone.caution }
        if n > 0 { return DS.Tone.info }
        return .primary
    }

    /// 把"每页进程数"的变更持久化到 MonitorConfig。
    /// 监听方只持久化 nicePageSize 这一个字段，其他字段不动。
    private func persistPageSize(_ newSize: Int) {
        var config = MonitorConfig.load()
        config.nicePageSize = NicePageSize.clamp(newSize)
        config.saveIfNotDefault()
    }

    /// 后台拉取进程列表。
    ///
    /// 关键路径：
    ///   - snapshot 在 actor 里跑（不阻塞主线程）；
    ///   - 一次性批量读 nice（少一次 actor 往返）；
    ///   - `executablePath` 已在 snapshot 里附上（`RunningProcess` 自带），
    ///     直接填进 Entry；bundlePath / bundleIdentifier 仍按需懒加载。
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let snapshot = await NiceBackgroundActor.shared.snapshot()
        let pids = snapshot.map(\.pid)
        let niceMap = await NiceBackgroundActor.shared.nice(ofPids: pids)

        var mapped: [Entry] = []
        mapped.reserveCapacity(snapshot.count)
        // 属主名按 uid 去重后算一次：几百个进程通常只有一两个 uid，
        // 逐个查用户名是白费力气（排序时还要反复用）。
        var ownerNames: [uid_t: String] = [:]
        for p in snapshot {
            let reason = ProcessGuard.niceRefusalReason(for: p)
            let owner: String
            if let cached = ownerNames[p.uid] {
                owner = cached
            } else {
                owner = NiceView.ownerName(for: p.uid)
                ownerNames[p.uid] = owner
            }
            mapped.append(Entry(
                pid: p.pid,
                name: p.name,
                nice: niceMap[p.pid] ?? nil,
                systemProcess: reason != nil,
                systemReason: reason,
                executablePath: p.executablePath.isEmpty ? nil : p.executablePath,
                bundleIdentifier: nil,
                uid: p.uid,
                ownerName: owner
            ))
        }

        entries = mapped.sorted { lhs, rhs in
            if lhs.systemProcess != rhs.systemProcess {
                return !lhs.systemProcess
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        // 拉一次新数据回到首页 —— 旧页码在新数据下很可能越界。
        currentPage = 1
        // 旧进程可能已经消失，临时值与已加载的详情一并清掉。
        draftNice = [:]
        loadedDetailPids = []
    }

    /// 属主的显示名。root / 当前用户给名字，其余给 uid。
    ///
    /// 只在刷新时按 uid 去重后调用，不在排序路径里反复问系统。
    private static func ownerName(for uid: uid_t) -> String {
        if uid == 0 { return "root" }
        if uid == getuid() { return NSUserName() }
        return "uid \(uid)"
    }

    /// 选中某行 → 懒加载它的 bundle id。
    ///
    /// executablePath 已经从 snapshot 自带，这里直接复用；
    /// bundleIdentifier 仍然按需拉（解析 Info.plist 昂贵）。
    ///
    /// 2026-11 起不再重新跑一次 `ProcessInventory.snapshot()`：
    /// 原来为了让 executablePath 最新而重扫全表（4-5 秒），但路径在
    /// 刷新时就已经拿到了，这里只需要路径本身。同一进程也不会被解析两次。
    private func ensureDetail(of pid: pid_t) async {
        guard !loadedDetailPids.contains(pid),
              let idx = entries.firstIndex(where: { $0.pid == pid }),
              let path = entries[idx].executablePath, !path.isEmpty else { return }
        loadedDetailPids.insert(pid)
        let bundle: String? = await Task.detached(priority: .utility) {
            ProcessInventory.bundleIdentifier(forExecutablePath: path)
        }.value
        // 限流：Info.plist 解析是 IO 密集的，连续选行时别把磁盘打满。
        try? await Task.sleep(nanoseconds: 100_000_000)
        if let idx = entries.firstIndex(where: { $0.pid == pid }) {
            entries[idx].bundleIdentifier = bundle
        }
    }

    /// 写 nice 的入口。
    ///
    /// `token` 是本次写请求的序号（Stepper 连点时用）；只有序号最新的那次
    /// 结果才写回界面。业务逻辑与之前完全一致：极端值先弹二次确认。
    private func applyNice(pid: pid_t, value: Int, label: String = "", token: Int? = nil) async {
        lastError = nil
        if value <= -10 || value >= 15 {
            let suffix = label.isEmpty ? "" : "（\(label)）"
            let message = "目标 nice = \(NiceLevel.format(value)) \(suffix)。"
                + (value < 0
                   ? "\n负值会跟系统进程抢 CPU，可能让 macOS 整体变卡。"
                   : "\n正值会让进程几乎拿不到 CPU 时间片，长时间运行可能假死。")
            pendingExtreme = ExtremePrompt(pid: pid, value: value, message: message, token: token)
            return
        }
        await reallyApplyNice(pid: pid, value: value, token: token)
    }

    /// 真实写 nice —— applyNice 与极端值确认共用。
    private func reallyApplyNice(pid: pid_t, value: Int, token: Int? = nil) async {
        do {
            let verified = try await ProcessNiceService.shared.setNice(value, of: pid)
            controller.appendLog("已将 pid \(pid) 的 nice 设为 \(NiceLevel.format(verified))")
            // 已经有更新的请求在飞 → 这次结果作废，不写界面。
            if let token, niceApplyToken[pid] != token { return }
            if let idx = entries.firstIndex(where: { $0.pid == pid }) {
                entries[idx].nice = verified
            }
            // 临时值与真实值对齐，Stepper 显示助手回报的那个值。
            draftNice[pid] = verified
        } catch {
            lastError = "\(error)"
            // 失败 → 回落显示真实值，别让界面停在没生效的 nice 上。
            if let token, niceApplyToken[pid] != token { return }
            draftNice[pid] = nil
            controller.appendLog("改 nice 失败：\(error)", isError: true)
        }
    }

    struct ExtremePrompt: Identifiable, Equatable {
        let pid: pid_t
        let value: Int
        let message: String
        /// 发起这次确认时的写请求序号。确认后按它判定结果是否仍然有效。
        var token: Int?
        var id: String { "\(pid)-\(value)" }
    }
}

/// 调整 nice 的 sheet 弹窗。
///
/// v1.7.1 起单独抽出来，因为：
///   - `.alert` 的 actions 闭包只接受 Button，放 Stepper 整个 alert 不弹；
///   - 独立视图便于将来加 Slider / 自定义预设按钮 / 极端值提示。
///
/// 不主动弹额外 alert；极端值二级确认仍走宿主页的 `.alert(item:)`。
private struct NiceAdjustSheet: View {
    let title: String
    let initialValue: Int
    let onApply: (Int) -> Void
    let onCancel: () -> Void

    @State private var value: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            // sheet 没有原生 title，自己组 header
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }

            Text("合法范围 [\(NiceLevel.minValue), \(NiceLevel.maxValue)]。"
                 + "负值会让进程抢更多 CPU，请确认无误后再应用。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Text("\(NiceLevel.format(value))")
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(niceColor)
                    .frame(minWidth: 88, alignment: .leading)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(hintText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("起点：\(NiceLevel.format(initialValue))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            Stepper(value: $value,
                    in: NiceLevel.minValue...NiceLevel.maxValue) {
                Text("步进调节")
                    .font(.callout)
            }
            .labelsHidden()
            .accessibilityLabel("nice 值步进调节")
            .frame(maxWidth: 260, alignment: .leading)

            // 文本输入兜底：极客可以直接敲数字 + 回车应用，
            // 解决 Stepper 一次一格点 39 次的痛苦。
            HStack(spacing: DS.Space.sm) {
                Text("或直接输入：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("如 5 / -10", text: textFieldValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                Button("用这个值") {
                    if let v = NiceLevel.parse(textFieldValue.wrappedValue) {
                        value = v
                    }
                }
                .controlSize(.small)
                .disabled(NiceLevel.parse(textFieldValue.wrappedValue) == nil)
            }

            HStack(spacing: DS.Space.md) {
                Spacer()
                Button("取消", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("应用") { onApply(value) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 360)
        .onAppear { value = initialValue }
    }

    /// 把 Int 转成 String 给 TextField 用，受控双向。
    private var textFieldValue: Binding<String> {
        Binding(
            get: { NiceLevel.format(value) },
            set: { newText in
                // 用户敲数字时实时同步给 @State value（非法则保留旧值）。
                if let parsed = NiceLevel.parse(newText) {
                    value = parsed
                }
            }
        )
    }

    private var niceColor: Color {
        if value < 0 { return DS.Tone.caution }
        if value > 0 { return DS.Tone.info }
        return .primary
    }

    private var hintText: String {
        switch value {
        case ..<0:
            return "负值会跟系统进程抢 CPU。"
        case 0:
            return "默认值，不争不抢。"
        case 1...10:
            return "轻度让出 CPU，对前台用户无感。"
        case 11...:
            return "让出大量 CPU，长时间运行可能假死。"
        default:
            return ""
        }
    }
}

/// 顶/底两处分页控件：每页数调节 + 翻页。
///
/// 设计：
///   - 每页数用 Stepper，范围 [10, 30]（与 NicePageSize.clamp 一致）；
///     改后调用 `onPageSizeChange` 让宿主持久化。
///   - 翻页按钮 + 当前/总页数；首页 / 末页时禁用对应方向。
///   - 改成受控组件：宿主持有 pageSize / currentPage，避免组件内部状态
///     与宿主页码计算规则打架。
///   - v1.7.1 起把「写 currentPage」集中到 onPageChange 回调，宿主可
///     在 setter 里加 `if newValue != currentPage` 防抖；翻页上下按钮
///     和首页/末页都走同一个出口。
private struct PageBar: View {
    @Binding var pageSize: Int
    @Binding var currentPage: Int
    let totalCount: Int
    let onPageSizeChange: (Int) -> Void
    let onPageChange: (Int) -> Void

    private var totalPages: Int {
        max(1, (totalCount + pageSize - 1) / pageSize)
    }

    private var clampedPage: Int {
        max(1, min(currentPage, totalPages))
    }

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.xs) {
                Text("每页")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(value: Binding(
                    get: { pageSize },
                    set: { newValue in
                        let clamped = NicePageSize.clamp(newValue)
                        if clamped != pageSize {
                            pageSize = clamped
                            onPageSizeChange(clamped)
                            onPageChange(1)
                        }
                    }
                ), in: NicePageSize.minValue...NicePageSize.maxValue, step: 1) {
                    Text("\(pageSize)")
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 28, alignment: .trailing)
                }
                .labelsHidden()
            }

            Spacer()

            HStack(spacing: DS.Space.xs) {
                Button {
                    onPageChange(max(1, clampedPage - 1))
                } label: {
                    Image(systemName: "chevron.left")
                }
                .controlSize(.small)
                .disabled(clampedPage <= 1 || totalCount == 0)

                Text(totalCount == 0
                     ? "0 / 0"
                     : "\(clampedPage) / \(totalPages)")
                    .font(.system(.caption, design: .monospaced))
                    .frame(minWidth: 56)

                Button {
                    onPageChange(min(totalPages, clampedPage + 1))
                } label: {
                    Image(systemName: "chevron.right")
                }
                .controlSize(.small)
                .disabled(clampedPage >= totalPages || totalCount == 0)
            }
        }
        .font(.caption)
        .padding(.vertical, DS.Space.xs)
    }
}
