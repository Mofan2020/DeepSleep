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
}

struct NiceView: View {

    @EnvironmentObject private var controller: SleepController

    @State private var query: String = ""
    @State private var entries: [Entry] = []
    @State private var isRefreshing = false
    @State private var lastError: String?

    /// 弹窗用的状态。`pendingPid == nil` 时弹窗关闭。
    @State private var pendingPid: pid_t?
    @State private var pendingValue: Int = 0
    @State private var pendingLabel: String = ""

    /// 极端值二级确认
    @State private var pendingExtreme: ExtremePrompt?

    /// 选中行：detail 加载入口
    @State private var selectedPid: pid_t?

    /// 简化版 Entry：默认视图只装必要字段，路径 / bundle id 按需懒加载
    struct Entry: Identifiable, Equatable {
        let pid: pid_t
        let name: String
        var nice: Int?
        let systemProcess: Bool
        var systemReason: String?
        /// 懒加载：用户选中该行后才填这两个字段
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
                        TextField("按名字过滤", text: $query)
                            .textFieldStyle(.roundedBorder)
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

                    if let err = lastError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            SectionCard(
                title: "可选进程",
                subtitle: "系统进程与保护名单里的应用已过滤掉；改 nice 走特权助手，需要先启用「完全控制」。",
                symbol: "list.bullet.indent"
            ) {
                let filtered = filter(entries)
                if filtered.isEmpty {
                    Text("没有匹配的进程。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            ProcessRow(
                                entry: entry,
                                isSelected: selectedPid == entry.pid,
                                onSelect: { Task { await ensureDetail(of: entry.pid) } },
                                onReset: { Task { await applyNice(pid: entry.pid, value: NiceLevel.defaultValue) } },
                                onAdjust: {
                                    pendingPid = entry.pid
                                    pendingValue = entry.nice ?? NiceLevel.defaultValue
                                    pendingLabel = entry.name
                                }
                            )
                            if entry != filtered.last { Divider() }
                        }
                    }
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
            await refresh()
        }
        .alert(
            "调整 \(pendingLabel) 的 nice",
            isPresented: nicePromptBinding
        ) {
            Stepper(value: $pendingValue,
                    in: NiceLevel.minValue...NiceLevel.maxValue) {
                Text("\(NiceLevel.format(pendingValue))")
            }
            Button("应用") {
                if let pid = pendingPid {
                    let v = pendingValue
                    let label = pendingLabel
                    pendingPid = nil
                    Task { await applyNice(pid: pid, value: v, label: label) }
                }
            }
            Button("取消", role: .cancel) {
                pendingPid = nil
            }
        } message: {
            Text("合法范围 [\(NiceLevel.minValue), \(NiceLevel.maxValue)]。负值会让进程抢更多 CPU，请确认无误后再应用。")
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

    private var nicePromptBinding: Binding<Bool> {
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

    private func filter(_ list: [Entry]) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.name.lowercased().contains(q)
                || ($0.executablePath?.lowercased().contains(q) ?? false)
                || ($0.bundleIdentifier?.lowercased().contains(q) ?? false)
        }
    }

    /// 后台拉取进程列表。同步构建"轻量 Entry"（不读路径 / bundle id）；
    /// 路径 / bundle id 在用户选中时才懒加载。
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let snapshot = await NiceBackgroundActor.shared.snapshot()

        var mapped: [Entry] = []
        mapped.reserveCapacity(snapshot.count)
        for p in snapshot {
            let nice = await NiceBackgroundActor.shared.nice(of: p.pid)
            let reason = ProcessGuard.niceRefusalReason(for: p)
            mapped.append(Entry(
                pid: p.pid,
                name: p.name,
                nice: nice,
                systemProcess: reason != nil,
                systemReason: reason,
                executablePath: nil,
                bundleIdentifier: nil
            ))
        }

        entries = mapped.sorted { lhs, rhs in
            if lhs.systemProcess != rhs.systemProcess {
                return !lhs.systemProcess
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// 选中某行 → 懒加载它的路径 / bundle id。
    private func ensureDetail(of pid: pid_t) async {
        selectedPid = pid
        if let idx = entries.firstIndex(where: { $0.pid == pid }),
           entries[idx].executablePath != nil {
            return
        }
        let snapshot = await NiceBackgroundActor.shared.snapshot()
        guard let p = snapshot.first(where: { $0.pid == pid }) else { return }
        let bundle: String? = await Task.detached(priority: .utility) {
            ProcessInventory.bundleIdentifier(forExecutablePath: p.executablePath)
        }.value
        try? await Task.sleep(nanoseconds: 100_000_000)
        if let idx = entries.firstIndex(where: { $0.pid == pid }) {
            entries[idx].executablePath = p.executablePath
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

/// 单行：进程 + nice + 调整按钮。
private struct ProcessRow: View {
    let entry: NiceView.Entry
    let isSelected: Bool
    let onSelect: () -> Void
    let onReset: () -> Void
    let onAdjust: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.system(.body, design: .monospaced))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(niceDisplay)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(niceColor)
                    .frame(width: 40, alignment: .trailing)
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
            if isSelected, let path = entry.executablePath, !path.isEmpty {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            if isSelected, let bundle = entry.bundleIdentifier {
                Text("bundle: \(bundle)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private var subtitle: String {
        if let bundle = entry.bundleIdentifier {
            return bundle
        }
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
        if n > 0 { return .secondary }
        return .primary
    }
}
