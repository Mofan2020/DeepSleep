//
//  QuarantineView.swift
//  Deep Sleep
//
//  Apple Quarantine 属性管理页面。
//
//  路径：选目录 → 扫描带 quarantine 属性的文件 → 勾选 / 全选 → 批量清除。
//  一切操作走本进程，不需完全控制（xattr 不需要 root）。
//
//  安全说明：
//    - 不动 symlink —— 源文件的 quarantine 是否该删取决于它真正的来源，
//      不属于「扫描当前目录」的判定范围；
//    - 只删 `com.apple.quarantine`，其他属性（`com.apple.metadata:_kMDItem*`、
//      下载来源的 Spotlight 元数据等）一律不碰；
//    - 单个属性删除是 libc 级原子操作，不存在「删了一半」的状态。
//

import SwiftUI
import UniformTypeIdentifiers

struct QuarantineView: View {

    @EnvironmentObject private var controller: SleepController

    @State private var rootPath: String = ""
    @State private var includeHidden: Bool = false
    @State private var recursive: Bool = true

    @State private var entries: [QuarantineService.Entry] = []
    @State private var selection: Set<String> = []
    @State private var isScanning = false
    @State private var isClearing = false
    @State private var lastError: String?
    @State private var lastSummary: String?
    @State private var lastReport: QuarantineService.Report?

    @State private var showFileImporter = false

    /// 快速修复：当前被修复的 .app 路径与结果。
    @State private var repairingPath: String?
    @State private var repairOutcomes: [QuarantineService.RepairOutcome] = []
    @State private var showRepairSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(
                title: "Quarantine 属性管理",
                subtitle: rootSubtitle,
                symbol: "lock.shield",
                accent: .accentColor
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("选择目录…", systemImage: "folder")
                        }
                        .controlSize(.small)

                        if !rootPath.isEmpty {
                            Button {
                                Task { await scan() }
                            } label: {
                                if isScanning {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("扫描", systemImage: "magnifyingglass")
                                }
                            }
                            .controlSize(.small)
                            .disabled(isScanning || isClearing)

                            Button {
                                Task { await clearAll() }
                            } label: {
                                if isClearing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("清除全部", systemImage: "trash")
                                }
                            }
                            .controlSize(.small)
                            .disabled(isClearing || entries.isEmpty)
                        }
                        Spacer()
                    }

                    HStack(spacing: 16) {
                        Toggle("包含子目录", isOn: $recursive)
                            .toggleStyle(.checkbox)
                            .disabled(isScanning || isClearing)
                        Toggle("包含隐藏文件", isOn: $includeHidden)
                            .toggleStyle(.checkbox)
                            .disabled(isScanning || isClearing)
                    }
                    .controlSize(.small)

                    if !rootPath.isEmpty {
                        Text(rootPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    if let lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let lastSummary {
                        Text(lastSummary)
                            .font(.caption)
                            .foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !rootPath.isEmpty {
                SectionCard(
                    title: scanSectionTitle,
                    subtitle: scanSectionSubtitle,
                    symbol: "list.bullet.rectangle"
                ) {
                    if entries.isEmpty {
                        if isScanning {
                            Text("正在扫描…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            Text("这个目录下没有带 quarantine 属性的文件。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        }
                    } else {
                        VStack(spacing: 0) {
                            HStack {
                                Text("已选 \(selection.count) / \(entries.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(selection.count == entries.count ? "取消全选" : "全选") {
                                    if selection.count == entries.count {
                                        selection.removeAll()
                                    } else {
                                        selection = Set(entries.map(\.path))
                                    }
                                }
                                .controlSize(.small)
                                .disabled(isScanning || isClearing)

                                Button {
                                    Task { await clearSelected() }
                                } label: {
                                    Label("清除所选", systemImage: "trash.slash")
                                }
                                .controlSize(.small)
                                .disabled(selection.isEmpty || isClearing)
                            }
                            .padding(.bottom, 6)

                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(entries) { entry in
                                        EntryRow(
                                            entry: entry,
                                            selected: selection.contains(entry.path),
                                            onToggle: {
                                                if selection.contains(entry.path) {
                                                    selection.remove(entry.path)
                                                } else {
                                                    selection.insert(entry.path)
                                                }
                                            },
                                            onRepair: entry.isAppBundle ? {
                                                Task { await runRepair(for: entry.path) }
                                            } : nil
                                        )
                                        if entry != entries.last { Divider() }
                                    }
                                }
                            }
                            .frame(maxHeight: 360)
                        }
                    }
                }
            }

            SectionCard(
                title: "什么是 Quarantine 属性",
                subtitle: nil,
                symbol: "info.circle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    BulletLine("macOS 给从浏览器 / 解压工具下载下来的文件加 `com.apple.quarantine` 扩展属性，双击时 Gatekeeper 会弹「未知开发者」提示。")
                    BulletLine("去掉这个属性后，文件下次双击会走「非隔离」分支（不再提示）；不会绕过签名校验与 notarization。")
                    BulletLine("常见场景：自己写的脚本、解压好的工具包、用 codesign --sign - 自签名的 .app。")
                    BulletLine("软链 / 硬链不会被本工具处理 —— 你看到的 `target` 才是真正的隔离对象。")
                }
            }
        }
        .task {
            if rootPath.isEmpty {
                rootPath = defaultRoot()
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let resolved = url.resolvingSymlinksInPath().path
                rootPath = resolved
                selection.removeAll()
                entries = []
                Task { await scan() }
            case .failure(let error):
                lastError = "选择目录失败：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showRepairSheet) {
            if let path = repairingPath {
                RepairResultSheet(
                    path: path,
                    outcomes: repairOutcomes,
                    onDone: {
                        repairingPath = nil
                        repairOutcomes = []
                        showRepairSheet = false
                        Task { await scan() }
                    }
                )
            }
        }
    }

    // MARK: - 派生

    private var rootSubtitle: String {
        if rootPath.isEmpty {
            return "选择一个目录开始扫描。无需启用「完全控制」。"
        }
        if !entries.isEmpty {
            return "共 \(entries.count) 个文件带 quarantine 属性，已选 \(selection.count) 个。"
        }
        return "目录已选，点击「扫描」开始。"
    }

    private var scanSectionTitle: String {
        entries.isEmpty ? "扫描结果" : "扫描结果（\(entries.count)）"
    }

    private var scanSectionSubtitle: String {
        if isScanning {
            return "扫描中…"
        }
        if entries.isEmpty {
            return "勾选要清除的文件，或点「清除全部」。"
        }
        if let report = lastReport, report.totalCleared > 0 {
            return "上一次清除：\(report.totalCleared) / \(report.totalScanned)"
        }
        return "勾选要清除的文件，或点「清除全部」。"
    }

    /// 默认起始目录：~/Downloads（最常见场景）。
    private func defaultRoot() -> String {
        let home = NSHomeDirectory()
        let downloads = (home as NSString).appendingPathComponent("Downloads")
        return FileManager.default.fileExists(atPath: downloads)
            ? downloads : home
    }

    // MARK: - 操作

    private func scan() async {
        guard !rootPath.isEmpty else { return }
        lastError = nil
        lastSummary = nil
        isScanning = true
        defer { isScanning = false }
        // 捕获到本地常量再传进 detached task，
        // 避开「跨 actor 访问 @State 需 await」的 strict concurrency 警告。
        let capturedRoot = rootPath
        let capturedRecursive = recursive
        let capturedHidden = includeHidden
        let result = await Task.detached(priority: .utility) {
            try? QuarantineService.shared.scan(
                root: capturedRoot,
                recursive: capturedRecursive,
                includeHidden: capturedHidden
            )
        }.value ?? []
        entries = result
        selection = Set(result.map(\.path))
        controller.appendLog("扫描 quarantine 完成：\(result.count) 个文件")
    }

    private func clearSelected() async {
        let targets = entries.filter { selection.contains($0.path) }
        guard !targets.isEmpty else { return }
        lastError = nil
        isClearing = true
        defer { isClearing = false }
        let result = await Task.detached(priority: .utility) {
            // 区分 .app / 普通文件：
            //   - 普通文件 → removexattr 单条
            //   - .app → 还要清包内所有文件
            var totalCleared = 0
            var failed: [(String, String)] = []
            for entry in targets {
                let result = QuarantineService.shared.clearAppBundle(at: entry.path)
                totalCleared += (result.clearedApp ? 1 : 0) + result.clearedInside
                failed.append(contentsOf: result.failed)
            }
            return (cleared: totalCleared, failed: failed)
        }.value
        let cleared = result.cleared
        let failed = result.failed
        entries.removeAll { targets.map(\.path).contains($0.path) }
        selection.removeAll()
        if failed.isEmpty {
            lastSummary = "已清除 \(cleared) 个文件的 quarantine 属性"
        } else {
            lastError = "清除 \(cleared) 个，失败 \(failed.count) 个：\(failed.first?.1 ?? "")"
            lastSummary = "已清除 \(cleared) 个（另有 \(failed.count) 个失败）"
        }
        controller.appendLog("清除 quarantine：\(cleared) 成功")
    }

    private func clearAll() async {
        lastError = nil
        isClearing = true
        defer { isClearing = false }
        let capturedRoot = rootPath
        let capturedRecursive = recursive
        let capturedHidden = includeHidden
        let report = await Task.detached(priority: .utility) {
            let entries: [QuarantineService.Entry]
            do {
                entries = try QuarantineService.shared.scan(
                    root: capturedRoot,
                    recursive: capturedRecursive,
                    includeHidden: capturedHidden
                )
            } catch {
                return nil as QuarantineService.Report?
            }
            var totalCleared = 0
            for entry in entries {
                let r = QuarantineService.shared.clearAppBundle(at: entry.path)
                totalCleared += (r.clearedApp ? 1 : 0) + r.clearedInside
            }
            return QuarantineService.Report(
                root: capturedRoot,
                entries: entries,
                totalScanned: entries.count,
                totalCleared: totalCleared
            )
        }.value
        if let report {
            entries = []
            selection = []
            lastReport = report
            lastSummary = "已清除 \(report.totalCleared) / \(report.totalScanned) 个文件"
            controller.appendLog("清除 quarantine 全部：\(report.totalCleared) / \(report.totalScanned)")
        } else {
            lastError = "清除失败：扫描过程中出错"
            controller.appendLog("清除 quarantine 失败：扫描过程中出错", isError: true)
        }
    }

    /// 跑对一个 .app 的多方案修复，结果用 sheet 展示。
    private func runRepair(for path: String) async {
        let outcomes = await Task.detached(priority: .userInitiated) {
            QuarantineService.shared.repairDamagedApp(at: path)
        }.value
        await MainActor.run {
            self.repairingPath = path
            self.repairOutcomes = outcomes
            self.showRepairSheet = true
            self.controller.appendLog("已对 \(path) 跑多方案修复，共 \(outcomes.count) 步")
        }
    }
}

private struct EntryRow: View {
    let entry: QuarantineService.Entry
    let selected: Bool
    let onToggle: () -> Void
    let onRepair: (() -> Void)?

    init(entry: QuarantineService.Entry,
         selected: Bool,
         onToggle: @escaping () -> Void,
         onRepair: (() -> Void)? = nil) {
        self.entry = entry
        self.selected = selected
        self.onToggle = onToggle
        self.onRepair = onRepair
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { selected },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text((entry.path as NSString).lastPathComponent)
                            .font(.system(.body, design: .monospaced))
                        if entry.isAppBundle {
                            Tag(text: ".app", color: .accentColor)
                        }
                        if entry.isAppBundle, entry.appContentsQuarantined > 0 {
                            Text("包内另有 \(entry.appContentsQuarantined) 个")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.isAppBundle {
                        Text(entry.detailDescription)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)

                if entry.isAppBundle, let onRepair {
                    Button {
                        onRepair()
                    } label: {
                        Label("快速修复", systemImage: "wrench.and.screwdriver")
                    }
                    .controlSize(.small)
                }

                Text(byteString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    private var subtitle: String {
        var parts: [String] = []
        parts.append(entry.path)
        if let date = entry.modifiedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            parts.append(formatter.string(from: date))
        }
        let summary = quarantineSummary(entry.value)
        if !summary.isEmpty {
            parts.append(summary)
        }
        return parts.joined(separator: " · ")
    }

    private var byteString: String {
        let bytes = entry.size
        if bytes < 0 { return "—" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        }
        if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
        return String(format: "%.2f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
    }

    /// 解析 quarantine 值的语义段：flag;timestamp;agent;UUID。
    /// 完整 value 还是保留在 entry.value，需要细节的人自取。
    private func quarantineSummary(_ raw: String) -> String {
        let segments = raw.split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)
        guard segments.count >= 3 else { return raw }
        // 第 3 段（agent）是给 UI 看的关键：哪个应用打上的隔离标记。
        return "agent=\(segments[2])"
    }
}

// MARK: - 修复结果 sheet

struct RepairResultSheet: View {

    let path: String
    let outcomes: [QuarantineService.RepairOutcome]
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("修复「.app 损坏」")
                    .font(.title3.weight(.semibold))
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: outcome.success ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(outcome.success ? Color.green : Color.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(outcome.step).font(.body.weight(.medium))
                            Text(outcome.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("完成") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}