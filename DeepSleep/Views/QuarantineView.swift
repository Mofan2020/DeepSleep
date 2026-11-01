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
//  2026-11 界面换新：
//    - 扫描结果从手搓 HStack 行换成紧凑行列表（路径 / 是否带 quarantine /
//      下载来源），每行保留原生 Toggle 勾选；
//    - 「清除全部」是本页主操作，prominent 按钮；
//    - 空态用 `EmptyStateView`。
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
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionCard(
                title: "Quarantine 属性管理",
                subtitle: rootSubtitle,
                symbol: "lock.shield",
                accent: .accentColor
            ) {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    HStack(spacing: DS.Space.sm) {
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
                        }
                        Spacer()
                    }

                    HStack(spacing: DS.Space.lg) {
                        Toggle("包含子目录", isOn: $recursive)
                            .toggleStyle(.switch)
                            .disabled(isScanning || isClearing)
                        Toggle("包含隐藏文件", isOn: $includeHidden)
                            .toggleStyle(.switch)
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
                            .foregroundStyle(DS.Tone.critical)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let lastSummary {
                        Text(lastSummary)
                            .font(.caption)
                            .foregroundStyle(DS.Tone.good)
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
                            EmptyStateView(
                                title: "正在扫描…",
                                message: "扫描过程中会逐个读取扩展属性，稍等。",
                                systemImage: "magnifyingglass"
                            )
                        } else {
                            EmptyStateView(
                                title: "没有带 quarantine 的文件",
                                message: "这个目录下没有找到带 quarantine 属性的文件。换一个目录，或打开「包含隐藏文件 / 子目录」再扫一次。",
                                systemImage: "checkmark.shield"
                            )
                        }
                    } else {
                        VStack(alignment: .leading, spacing: DS.Space.md) {
                            HStack(spacing: DS.Space.sm) {
                                Text("已选 \(selection.count) / \(entries.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button(selection.count == entries.count ? "取消全选" : "全选") {
                                    if selection.count == entries.count {
                                        selection.removeAll()
                                    } else {
                                        selection = Set(entries.map(\.path))
                                    }
                                }
                                .controlSize(.small)
                                .disabled(isScanning || isClearing)

                                Spacer()

                                // 主操作：批量清除。
                                Button {
                                    Task { await clearSelected() }
                                } label: {
                                    Label("清除所选（\(selection.count)）", systemImage: "trash.slash")
                                }
                                .controlSize(.regular)
                                .buttonStyle(.borderedProminent)
                                .disabled(selection.isEmpty || isClearing)

                                Button {
                                    Task { await clearAll() }
                                } label: {
                                    if isClearing {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Label("清除全部", systemImage: "trash")
                                    }
                                }
                                .controlSize(.regular)
                                .disabled(isClearing || entries.isEmpty)
                            }

                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(entries) { entry in
                                        NtQuarantineEntryRow(
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
                VStack(alignment: .leading, spacing: DS.Space.sm) {
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

/// 扫描结果的单行：路径 / 是否带 quarantine / 下载来源。
///
/// 2026-11 起从 `EntryRow` 换成本类型（`Nt` 前缀，避免与其他页面重名）。
/// bundle id 仍只在选中时展开（解析 Info.plist 昂贵）。
private struct NtQuarantineEntryRow: View {
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
        HStack(alignment: .center, spacing: DS.Space.md) {
            Toggle("", isOn: Binding(
                get: { selected },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xs) {
                    Text((entry.path as NSString).lastPathComponent)
                        .font(.system(.body, design: .monospaced))
                    if entry.isAppBundle {
                        Tag(text: ".app", color: DS.Tone.info)
                    }
                    if entry.isAppBundle, entry.appContentsQuarantined > 0 {
                        Tag(text: "包内另有 \(entry.appContentsQuarantined) 个", color: DS.Tone.caution)
                    }
                }
                Text(entry.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if entry.isAppBundle {
                    Text(entry.detailDescription)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: DS.Space.sm)

            VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                // 状态用「颜色 + 文字」双编码：颜色只是辅助，文字才说清是什么。
                Label(quarantineStateText, systemImage: quarantineStateSymbol)
                    .font(.caption)
                    .foregroundStyle(quarantineStateColor)
                    .lineLimit(1)
                if let source = downloadSource {
                    Text("来源 \(source)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(byteString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if entry.isAppBundle, let onRepair {
                Button {
                    onRepair()
                } label: {
                    Label("快速修复", systemImage: "wrench.and.screwdriver")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    /// 是否带 quarantine 属性。本页扫出来的都带，但 .app 包内可能还有更多。
    private var quarantineStateText: String {
        if entry.isAppBundle, entry.appContentsQuarantined > 0 {
            return "已隔离（包内 \(entry.appContentsQuarantined) 个）"
        }
        return "已隔离"
    }

    private var quarantineStateSymbol: String {
        "lock.shield.fill"
    }

    private var quarantineStateColor: Color {
        DS.Tone.caution
    }

    /// 下载来源：quarantine 值的第 3 段（agent）。
    ///
    /// 解析失败时回落到原始 value 自己切段 —— 完整 value 仍然保留在
    /// `entry.value` 里，需要细节的人自己看。
    private var downloadSource: String? {
        var segments = entry.valueSegments
        if segments.count < 3 {
            segments = entry.value
                .split(separator: ";", omittingEmptySubsequences: false)
                .map(String.init)
        }
        guard segments.count >= 3 else { return nil }
        let agent = segments[2].trimmingCharacters(in: .whitespaces)
        return agent.isEmpty ? nil : agent
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
}

// MARK: - 修复结果 sheet

struct RepairResultSheet: View {

    let path: String
    let outcomes: [QuarantineService.RepairOutcome]
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
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

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                    HStack(alignment: .top, spacing: DS.Space.sm) {
                        Image(systemName: outcome.success ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(outcome.success ? DS.Tone.good : DS.Tone.idle)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
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
        .padding(DS.Space.xl)
        .frame(width: 520)
    }
}
