//
//  NiceView.swift
//  Deep Sleep
//
//  「进程优先级（nice）」页面：列出所有用户态进程、对单个进程改 nice。
//
//  设计原则（与 ProcessInventory / ProcessGuard 的边界一致）：
//    - 不做「通用任务管理器」：只展示改 nice 这件事必需的字段
//      （pid / name / 路径 / bundle id / 当前 nice / 拒绝理由）。
//    - 系统进程在表里显示但**不让选**：保护名单 + 系统路径前缀两层过滤，
//      在 UI 上就把它们过滤掉；助手侧再做一次同样过滤以防越权。
//    - 改 nice 走助手（POSIX setpriority 需要 root）。UI 上点按钮 →
//      走 Service → 助手收到命令 → 自己重新读快照 → 重新判定能否改 →
//      执行。所有「能不能改」的判断不依赖应用侧是否诚实。
//

import SwiftUI

struct NiceView: View {

    @EnvironmentObject private var controller: SleepController

    @State private var query: String = ""
    @State private var entries: [Entry] = []
    @State private var lastError: String?
    @State private var pendingPid: pid_t?
    @State private var pendingValue: Int = 0
    @State private var isRefreshing = false

    struct Entry: Identifiable, Equatable {
        let pid: pid_t
        let name: String
        let executablePath: String
        let bundleIdentifier: String?
        var nice: Int?
        var systemProcess: Bool
        var systemReason: String?
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
                            ProcessRow(entry: entry,
                                       onSubmit: { value in
                                Task { await applyNice(pid: entry.pid, value: value) }
                            })
                            if entry != filtered.last {
                                Divider()
                            }
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
                    BulletLine("正值（>0）也必须走 root —— POSIX 的硬约束，应用层无特权不能 `setpriority`。")
                    BulletLine("改错值会让系统变卡：负值会跟系统进程抢 CPU。系统进程一律被 Deep Sleep 拒绝。")
                    BulletLine("本工具等价于 `sudo renice <value> <pid>`。")
                }
            }
        }
        .task {
            await refresh()
        }
        .alert("调整 nice", isPresented: nicePromptBinding) {
            Stepper(value: $pendingValue,
                    in: NiceLevel.minValue...NiceLevel.maxValue) {
                Text("\(NiceLevel.format(pendingValue))")
            }
            Button("应用") {
                if let pid = pendingPid {
                    let v = pendingValue
                    pendingPid = nil
                    Task { await applyNice(pid: pid, value: v) }
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
                || $0.executablePath.lowercased().contains(q)
                || ($0.bundleIdentifier?.lowercased().contains(q) ?? false)
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = ProcessInventory.snapshot()
        var mapped: [Entry] = []
        for p in snapshot {
            let reason = ProcessGuard.niceRefusalReason(for: p)
            mapped.append(Entry(
                pid: p.pid,
                name: p.name,
                executablePath: p.executablePath,
                bundleIdentifier: p.bundleIdentifier,
                nice: p.nice,
                systemProcess: reason != nil,
                systemReason: reason
            ))
        }
        entries = mapped.sorted { lhs, rhs in
            if lhs.systemProcess != rhs.systemProcess {
                return !lhs.systemProcess
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func applyNice(pid: pid_t, value: Int) async {
        lastError = nil
        // 极端值（≤ -10 或 ≥ +15）会显著改变进程在调度器里的位置：
        // 负值会跟系统进程抢资源、正值会让进程几乎拿不到时间片。
        // 已经是 root 调用，不强制拦下 —— 给一个二级确认，由用户自己拍板。
        if value <= -10 || value >= 15 {
            let message = "目标 nice = \(NiceLevel.format(value))。"
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

    /// 极端值二级确认弹窗的状态。
    struct ExtremePrompt: Identifiable, Equatable {
        let pid: pid_t
        let value: Int
        let message: String
        var id: String { "\(pid)-\(value)" }
    }

    @State private var pendingExtreme: ExtremePrompt?
}

/// 单行：进程 + nice + 调整按钮。
private struct ProcessRow: View {
    let entry: NiceView.Entry
    let onSubmit: (Int) -> Void

    var body: some View {
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
            Button {
                onSubmit(NiceLevel.defaultValue)
            } label: {
                Text("默认")
            }
            .controlSize(.small)
            .disabled(entry.systemProcess)
            Button("调整…") {
                onSubmit(entry.nice ?? NiceLevel.defaultValue)
            }
            .controlSize(.small)
            .disabled(entry.systemProcess)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        if let bundle = entry.bundleIdentifier {
            return bundle
        }
        return entry.executablePath.isEmpty ? "pid \(entry.pid)" : entry.executablePath
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
