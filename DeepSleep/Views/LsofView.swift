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
        case .port:      return "端口"
        case .pid:       return "进程"
        case .path:      return "路径"
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

struct LsofView: View {

    /// 最多渲染多少行。全量 lsof 能有 2 万多行，全部塞进视图树会卡。
    private static let maxRendered = 500

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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $mode) {
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
                    Text("列出所有 TCP 监听端口（等价于 lsof -nP -iTCP -sTCP:LISTEN）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .port:
                    inputField(
                        placeholder: "端口号，如 8080",
                        text: $portText,
                        isError: !portText.isEmpty && LsofService.parsePortText(portText) == nil
                    )
                case .pid:
                    inputField(
                        placeholder: "进程 PID，如 501",
                        text: $pidText,
                        isError: !pidText.isEmpty && LsofService.parsePIDText(pidText) == nil
                    )
                case .path:
                    inputField(
                        placeholder: "文件或目录路径，如 /tmp",
                        text: $pathText,
                        isError: false
                    )
                }

                HStack(spacing: 8) {
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
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func inputField(placeholder: String, text: Binding<String>, isError: Bool) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit { Task { await runQuery() } }
            if isError {
                Text("输入不合法")
                    .font(.caption)
                    .foregroundStyle(.red)
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
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(renderedEntries) { entry in
                                row(entry)
                                if entry.id != renderedEntries.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 420)

                    if totalCount > renderedEntries.count {
                        Text("共 \(totalCount) 条，已截断，只显示前 \(renderedEntries.count) 条。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.top, 6)
                    }
                }
            }
        }
    }

    /// 表头。宽度和下面的行对齐，方便扫读。
    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("进程").frame(width: 110, alignment: .leading)
            Text("PID").frame(width: 56, alignment: .trailing)
            Text("用户").frame(width: 80, alignment: .leading)
            Text("FD").frame(width: 56, alignment: .trailing)
            Text("类型").frame(width: 56, alignment: .leading)
            Text("名称 / 地址").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
    }

    private func row(_ entry: LsofEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.command)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(entry.pid)")
                .frame(width: 56, alignment: .trailing)
            Text(entry.user)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(entry.fd)
                .frame(width: 56, alignment: .trailing)
            Text(typeText(entry))
                .frame(width: 56, alignment: .leading)
                .lineLimit(1)
            Text(entry.name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, 4)
    }

    /// 类型列。网络条目把协议（TCP / UDP）也带出来 —— 同一个端口
    /// TCP 和 UDP 可能被不同进程占着，不标出来看不出来。
    private func typeText(_ entry: LsofEntry) -> String {
        if let proto = entry.protocolName, !proto.isEmpty {
            return proto
        }
        return entry.type
    }

    /// 实际渲染的条目 —— 只取前 N 条，别把 2 万行塞进视图树。
    private var renderedEntries: [LsofEntry] {
        Array(entries.prefix(LsofView.maxRendered))
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

    private var emptyMessage: String {
        if isQuerying { return "查询中…" }
        switch mode {
        case .listening:
            return "没有查到监听端口。"
        case .port:
            return "这个端口没有查到占用。非特权下能看到全部监听端口，所以「查不到」基本等于「确实没人占」。"
        case .pid:
            return "这个 PID 没查到打开的文件。非特权只能看到自己的进程 —— 如果这是别人的进程，root 才能看到。"
        case .path:
            return "这个路径没查到被打开的文件。非特权只能看到自己的进程打开的文件。"
        }
    }

    // MARK: - 权限说明

    private var permissionCard: some View {
        SectionCard(
            title: "权限边界",
            subtitle: "这一页没有提权，看到的就是系统愿意让你看的。",
            symbol: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                BulletLine("监听端口：非特权就能看到全部 TCP 监听套接字，不管是谁开的。")
                BulletLine("进程与文件：非特权只能看到自己的进程。别的用户（尤其 root）进程打开的文件读不出来。")
                BulletLine("想看别人的进程文件，需要完全控制（root）权限 —— 本页不做提权。")
                BulletLine("「查不到」有两种含义：真的没人占，或者占的人不是你能看的。")
                BulletLine("全量扫描有 2 万多行，页面只渲染前 \(LsofView.maxRendered) 条，其余按总数报。")
            }
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
