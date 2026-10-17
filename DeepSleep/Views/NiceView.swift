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
//  设计原则（与 ProcessInventory / ProcessGuard 的边界一致）：
//    - 不做"通用任务管理器"：只展示改 nice 这件事必需的字段。
//    - 系统进程在表里显示但**不让选**：保护名单 + 系统路径前缀两层过滤，
//      在 UI 上就把它们过滤掉；助手侧再做一次同样过滤以防越权。
//    - 改 nice 走助手（POSIX setpriority 需要 root）。所有"能不能改"的判断
//      不依赖应用侧是否诚实。
//

import SwiftUI

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
        var id: pid_t { pid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(
                title: "进程优先级（nice）",
                subtitle: helperSubtitle,
                symbol: "gauge.with.dots.needle.bottom.50percent",
                accent: .accentColor
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
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
                        Text(err).font(.caption).foregroundStyle(.red)
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
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(paged) { entry in
                                ProcessRow(
                                    entry: entry,
                                    isSelected: selectedPid == entry.pid,
                                    onSelect: { Task { await ensureDetail(of: entry.pid) } },
                                    onReset: { Task { await applyNice(pid: entry.pid, value: NiceLevel.defaultValue) } },
                                    onAdjust: {
                                        pendingPid = entry.pid
                                        pendingInitialValue = entry.nice ?? NiceLevel.defaultValue
                                        pendingLabel = entry.name
                                    }
                                )
                                if entry != paged.last { Divider() }
                            }
                        }
                    }
                    .frame(maxHeight: 460)

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

            SectionCard(
                title: "nice 值含义",
                subtitle: nil,
                symbol: "info.circle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
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
                    pendingExtreme = nil
                    Task { await reallyApplyNice(pid: pid, value: v) }
                }),
                secondaryButton: .cancel(Text("取消"), action: {
                    pendingExtreme = nil
                })
            )
        }
    }

    /// .sheet 用 binding。`pendingPid != nil` 时弹起；onDismiss 把 pendingPid 清空。
    private var niceSheetBinding: Binding<Bool> {
        Binding(
            get: { pendingPid != nil },
            set: { if !$0 { pendingPid = nil } }
        )
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

    private var emptyMessage: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "没有可调整的进程。"
        }
        return "没有匹配「\(query)」的进程。"
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
    private var pagedEntries: [Entry] {
        let filtered = filteredEntries
        guard !filtered.isEmpty else { return [] }
        let totalPages = max(1, (filtered.count + pageSize - 1) / pageSize)
        let page = max(1, min(currentPage, totalPages))
        let start = (page - 1) * pageSize
        let end = min(start + pageSize, filtered.count)
        return Array(filtered[start..<end])
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
        for p in snapshot {
            let reason = ProcessGuard.niceRefusalReason(for: p)
            mapped.append(Entry(
                pid: p.pid,
                name: p.name,
                nice: niceMap[p.pid] ?? nil,
                systemProcess: reason != nil,
                systemReason: reason,
                executablePath: p.executablePath.isEmpty ? nil : p.executablePath,
                bundleIdentifier: nil
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
    }

    /// 选中某行 → 懒加载它的 bundle id。
    /// executablePath 已经从 snapshot 自带，这里只在没填过时才补；
    /// bundleIdentifier 仍然按需拉（解析 Info.plist 昂贵）。
    private func ensureDetail(of pid: pid_t) async {
        selectedPid = pid
        if let idx = entries.firstIndex(where: { $0.pid == pid }),
           entries[idx].bundleIdentifier != nil {
            return
        }
        let snapshot = await NiceBackgroundActor.shared.snapshot()
        guard let p = snapshot.first(where: { $0.pid == pid }) else { return }
        let bundle: String? = await Task.detached(priority: .utility) {
            ProcessInventory.bundleIdentifier(forExecutablePath: p.executablePath)
        }.value
        try? await Task.sleep(nanoseconds: 100_000_000)
        if let idx = entries.firstIndex(where: { $0.pid == pid }) {
            entries[idx].executablePath = p.executablePath.isEmpty ? entries[idx].executablePath : p.executablePath
            entries[idx].bundleIdentifier = bundle
        }
    }

    private func applyNice(pid: pid_t, value: Int, label: String = "") async {
        lastError = nil
        if value <= -10 || value >= 15 {
            let suffix = label.isEmpty ? "" : "（\(label)）"
            let message = "目标 nice = \(NiceLevel.format(value)) \(suffix)。"
                + (value < 0
                   ? "\n负值会跟系统进程抢 CPU，可能让 macOS 整体变卡。"
                   : "\n正值会让进程几乎拿不到 CPU 时间片，长时间运行可能假死。")
            pendingExtreme = ExtremePrompt(pid: pid, value: value, message: message)
            return
        }
        await reallyApplyNice(pid: pid, value: value)
    }

    /// 真实写 nice —— applyNice 与极端值确认共用。
    private func reallyApplyNice(pid: pid_t, value: Int) async {
        do {
            let verified = try await ProcessNiceService.shared.setNice(value, of: pid)
            controller.appendLog("已将 pid \(pid) 的 nice 设为 \(NiceLevel.format(verified))")
            if let idx = entries.firstIndex(where: { $0.pid == pid }) {
                entries[idx].nice = verified
            }
        } catch {
            lastError = "\(error)"
            controller.appendLog("改 nice 失败：\(error)", isError: true)
        }
    }

    struct ExtremePrompt: Identifiable, Equatable {
        let pid: pid_t
        let value: Int
        let message: String
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
        VStack(alignment: .leading, spacing: 16) {
            // sheet 没有原生 title，自己组 header
            HStack(spacing: 8) {
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

            HStack(spacing: 14) {
                Text("\(NiceLevel.format(value))")
                    .font(.system(size: 38, weight: .semibold, design: .monospaced))
                    .foregroundStyle(niceColor)
                    .frame(minWidth: 88, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
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
            HStack(spacing: 8) {
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

            HStack(spacing: 12) {
                Spacer()
                Button("取消", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("应用") { onApply(value) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
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
        if value < 0 { return .orange }
        if value > 0 { return .blue }
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

/// 单行：进程 + nice + 调整按钮。
///
/// v1.7.1 起改为三行布局：
///   - 第 1 行 进程名（允许多行撑开，长名字不再被截掉）
///   - 第 2 行 路径副标题（.lineLimit(1) + .truncationMode(.middle)，
///     整行可复制选中 textSelection）
///   - 第 3 行 nice 数字 + 默认 / 调整 按钮（右对齐）
///
/// bundle id 仍只在选中时展开（解析 Info.plist 昂贵）。
private struct ProcessRow: View {
    let entry: NiceView.Entry
    let isSelected: Bool
    let onSelect: () -> Void
    let onReset: () -> Void
    let onAdjust: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 第 1 行：名字 + 系统标签
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(entry.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if entry.systemProcess {
                    Text("系统")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            // 第 2 行：路径副标题
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            // 第 3 行：nice 数字 + 操作按钮
            HStack(spacing: 8) {
                Text(niceDisplay)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(niceColor)
                    .frame(minWidth: 40, alignment: .leading)
                Spacer()
                Button("默认") {
                    onReset()
                }
                .controlSize(.small)
                .disabled(entry.systemProcess)
                Button("调整…") {
                    onAdjust()
                }
                .controlSize(.small)
                .disabled(entry.systemProcess)
            }

            if isSelected, let bundle = entry.bundleIdentifier, !bundle.isEmpty {
                Text("bundle: \(bundle)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    /// 主行副标题：有路径就显示路径，否则回落到 pid。
    /// 这一行整行可复制选中（`.textSelection(.enabled)` 在父级）。
    private var subtitle: String {
        if let path = entry.executablePath, !path.isEmpty {
            return path
        }
        return "pid \(entry.pid)"
    }

    private var niceDisplay: String {
        guard let n = entry.nice else { return "—" }
        return NiceLevel.format(n)
    }

    private var niceColor: Color {
        guard let n = entry.nice else { return .secondary }
        if n < 0 { return .orange }
        if n > 0 { return .blue }
        return .primary
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
        HStack(spacing: 10) {
            HStack(spacing: 4) {
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

            HStack(spacing: 4) {
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
        .padding(.vertical, 4)
    }
}
