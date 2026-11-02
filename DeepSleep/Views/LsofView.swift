//
//  LsofView.swift
//  Deep Sleep
//
//  「lsof 查询」页面：查端口被谁占了、查某个进程打开了什么文件。
//
//  与其它工具页的差别 —— 这一页的权限是「半截」的，必须在页面上写清楚：
//    - 监听端口：非特权就能看到全部 LISTEN 套接字（不管是谁开的）；
//    - 进程 / 文件：非特权只能看到**自己的**进程。别的用户（尤其 root）
//      的进程打开的文件读不出来 —— 实测 `lsof -nP -p 1` 非特权输出为空，
//      这不是 bug，是内核不允许。
//    所以「查不到」有两种完全不同的含义：真的没人占，和占的人不是你能看的。
//    界面上把这条边界写在明面上，不假装能看全。
//
//  与 HostsView / ShellConfigView 的对齐：
//    - SectionCard 分块，页面根视图 .pageLayout()；
//    - 错误用内联 message（lastError），不用弹窗打断。
//
//  2026-11 界面换新：
//    - 查询方式仍用原生 `Picker(.segmented)`，按端口查与按文件查分开；
//    - 结果从「手搓表头 + HStack 行」换成原生 `Table`（进程 / PID / 类型 / 描述），
//      列头可点排序；
//    - 空结果用 `EmptyStateView`，不再是一行灰字。
//

import SwiftUI

/// 查询方式。
enum LsofQueryMode: String, CaseIterable, Identifiable {
    /// 监听端口（TCP LISTEN）
    case listening
    /// 按端口号查
    case port
    /// 按 PID 查
    case pid
    /// 按文件路径查
    case path

    var id: String { rawValue }

    var title: String {
        switch self {
        case .listening: return "监听端口"
        case .port:      return "按端口"
        case .pid:       return "按进程"
        case .path:      return "按文件"
        }
    }

    var symbol: String {
        switch self {
        case .listening: return "network"
        case .port:      return "number.square"
        case .pid:       return "cpu"
        case .path:      return "folder"
        }
    }

    /// 这一模式需要用户填什么。
    var needsInput: Bool { self != .listening }
}

/// 结果表的一行。
///
/// 包一层是为了让「排序」和「显示」说的是同一件事：
/// 类型列显示的是协议（TCP / UDP），拿 lsof 的原始类型（IPv4 / IPv6）去排
/// 会和看到的文字对不上。`LsofEntry` 在 Core 里不能动，所以这层包装放在视图里。
private struct NtLsofRow: Identifiable {
    let id: String
    let command: String
    let user: String
    let pid: Int
    let typeText: String
    let name: String
    let fd: String

    init(entry: LsofEntry) {
        self.id = entry.id
        self.command = entry.command
        self.user = entry.user
        self.pid = entry.pid
        // 网络条目把协议（TCP / UDP）也带出来 —— 同一个端口
        // TCP 和 UDP 可能被不同进程占着，不标出来看不出来。
        if let proto = entry.protocolName, !proto.isEmpty {
            self.typeText = proto
        } else {
            self.typeText = entry.type
        }
        self.name = entry.name
        self.fd = entry.fd
    }
}

struct LsofView: View {

    /// 最多渲染多少行。全量 lsof 能有 2 万多行，全部塞进视图树会卡。
    private static let maxRendered = 500

    /// 结果表的固定高度。
    ///
    /// 页面本身在 ScrollView 里，Table 必须自己占一个确定的高度，
    /// 否则它会按内容撑开、把外层滚动条顶没。
    private static let resultTableHeight: CGFloat = 420

    @State private var mode: LsofQueryMode = .listening
    @State private var portText: String = ""
    @State private var pidText: String = ""
    @State private var pathText: String = ""

    @State private var entries: [LsofEntry] = []
    @State private var isQuerying = false
    @State private var lastError: String?
    /// 上次查询耗时（秒），给用户一个「快还是慢」的直观感受。
    @State private var elapsed: Double?
    /// 上次查询的条数（渲染前）。
    @State private var totalCount: Int = 0

    /// 结果表的排序状态（点列头排序）。
    @State private var sortOrder: [KeyPathComparator<NtLsofRow>] = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            queryCard
            resultCard
            permissionCard
        }
        .pageLayout()
        // 进来先查一次监听端口 —— 这是最常用的一屏。
        .task { await runQuery() }
    }

    // MARK: - 查询

    private var queryCard: some View {
        SectionCard(
            title: "lsof 查询",
            subtitle: "查端口占用、查进程打开的文件、查某个路径被谁占用。",
            symbol: "network",
            accent: .accentColor
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Picker("查询方式", selection: $mode) {
                    ForEach(LsofQueryMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: mode) { _, _ in
                    lastError = nil
                }

                switch mode {
                case .listening:
                    Label("列出所有 TCP 监听端口（等价于 lsof -nP -iTCP -sTCP:LISTEN）。",
                          systemImage: mode.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .port:
                    LabeledContent("端口号") {
                        inputField(
                            placeholder: "如 8080",
                            text: $portText,
                            isError: !portText.isEmpty && LsofService.parsePortText(portText) == nil
                        )
                    }
                case .pid:
                    LabeledContent("进程 PID") {
                        inputField(
                            placeholder: "如 501",
                            text: $pidText,
                            isError: !pidText.isEmpty && LsofService.parsePIDText(pidText) == nil
                        )
                    }
                case .path:
                    LabeledContent("文件或目录路径") {
                        inputField(
                            placeholder: "如 /tmp",
                            text: $pathText,
                            isError: false
                        )
                    }
                }

                HStack(spacing: DS.Space.sm) {
                    Button {
                        Task { await runQuery() }
                    } label: {
                        if isQuerying {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("查询", systemImage: "magnifyingglass")
                        }
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isQuerying)

                    if isQuerying {
                        Text("查询中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(DS.Tone.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func inputField(placeholder: String, text: Binding<String>, isError: Bool) -> some View {
        HStack(spacing: DS.Space.sm) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit { Task { await runQuery() } }
            if isError {
                Text("输入不合法")
                    .font(.caption)
                    .foregroundStyle(DS.Tone.critical)
            }
        }
    }

    // MARK: - 结果

    private var resultCard: some View {
        SectionCard(
            title: "结果",
            subtitle: resultSubtitle,
            symbol: "list.bullet.rectangle"
        ) {
            if entries.isEmpty {
                EmptyStateView(
                    title: emptyTitle,
                    message: emptyMessage,
                    systemImage: "magnifyingglass"
                )
            } else {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    Table(resultRows, sortOrder: $sortOrder) {
                        TableColumn("进程", value: \.command) { row in
                            processCell(row)
                        }
                        TableColumn("PID", value: \.pid) { row in
                            Text("\(row.pid)")
                                .monospacedDigit()
                        }
                        TableColumn("类型", value: \.typeText) { row in
                            Text(row.typeText)
                                .lineLimit(1)
                        }
                        TableColumn("描述", value: \.name) { row in
                            descriptionCell(row)
                        }
                    }
                    .frame(height: Self.resultTableHeight)

                    if totalCount > resultRows.count {
                        Label("共 \(totalCount) 条，已截断，只显示前 \(resultRows.count) 条。",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(DS.Tone.caution)
                    }
                }
            }
        }
    }

    /// 进程列：命令名 + 登录用户名。
    @ViewBuilder
    private func processCell(_ row: NtLsofRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(row.command)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(row.user)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// 描述列：FD + 名称 / 地址。
    @ViewBuilder
    private func descriptionCell(_ row: NtLsofRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(row.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if !row.fd.isEmpty {
                Text("FD \(row.fd)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 实际渲染的条目 —— 只取前 N 条，别把 2 万行塞进视图树。
    private var resultRows: [NtLsofRow] {
        entries.prefix(LsofView.maxRendered).map(NtLsofRow.init(entry:))
    }

    private var resultSubtitle: String {
        if entries.isEmpty {
            return "还没有结果。"
        }
        var text = "共 \(totalCount) 条"
        if let elapsed {
            text += String(format: "，耗时 %.2f 秒", elapsed)
        }
        return text + "。"
    }

    private var emptyTitle: String {
        switch mode {
        case .listening: return "没有监听端口"
        case .port:      return "这个端口没有占用"
        case .pid:       return "这个进程没有打开的文件"
        case .path:      return "这个路径没有被打开"
        }
    }

    private var emptyMessage: String {
        if isQuerying { return "查询中…" }
        switch mode {
        case .listening:
            return "没有查到监听端口。"
        case .port:
            return "这个端口确实没人占。"
        case .pid:
            return "这个 PID 没查到打开的文件。非特权只能看到自己的进程。"
        case .path:
            return "这个路径没查到被打开的文件。非特权只能看到自己的进程。"
        }
    }

    // MARK: - 权限

    private var permissionCard: some View {
        SectionCard(
            title: "权限",
            subtitle: nil,
            symbol: "info.circle"
        ) {
            Label("本页不提权：进程与文件只看得到当前用户自己的，监听端口不受限制。",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 执行

    private func runQuery() async {
        guard !isQuerying else { return }
        isQuerying = true
        lastError = nil
        let start = Date()
        defer {
            isQuerying = false
            elapsed = Date().timeIntervalSince(start)
        }

        do {
            let result: [LsofEntry]
            switch mode {
            case .listening:
                result = try await LsofService.listening()
            case .port:
                guard let port = LsofService.parsePortText(portText) else {
                    lastError = "端口号必须是 \(LsofService.portRange.lowerBound)–\(LsofService.portRange.upperBound) 之间的整数。"
                    entries = []
                    totalCount = 0
                    return
                }
                result = try await LsofService.port(port)
            case .pid:
                guard let pid = LsofService.parsePIDText(pidText) else {
                    lastError = "PID 必须是正整数。"
                    entries = []
                    totalCount = 0
                    return
                }
                result = try await LsofService.pid(pid)
            case .path:
                let trimmed = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard LsofService.isValidPath(trimmed) else {
                    lastError = "请填写要查的文件或目录路径。"
                    entries = []
                    totalCount = 0
                    return
                }
                result = try await LsofService.path(trimmed)
            }
            entries = result
            totalCount = result.count
        } catch {
            lastError = "\(error)"
            entries = []
            totalCount = 0
        }
    }
}
