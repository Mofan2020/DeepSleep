//
//  ShellConfigView.swift
//  Deep Sleep
//
//  Shell 启动文件编辑页：左侧选文件，右侧改内容，保存前做语法检查。
//
//  设计要点：
//    - 直接读写家目录里的文件，不需要「完全控制」助手 —— 这些文件本来
//      就是用户自己的，走 root 反而会留下 root 拥有的文件让用户下次改不动。
//    - 保存顺序是「备份 → 语法检查 → 原子写入 → 回读校验」。
//      语法检查不通过时**不直接拒绝**，而是把错误原文摆出来让用户决定
//      要不要强行保存：有的 .zshrc 用到了当前 shell 不认识的语法
//      （比如别的 shell 的语法、或者故意写错的实验代码），直接拦死太霸道。
//    - 改完不会自动生效：新开终端窗口，或在当前窗口 `source ~/.zshrc`。
//
//  与 HostsView 的对齐：
//    - 用 SectionCard 分块，页面根视图 .pageLayout()；
//    - 错误用内联 message（lastError / lastNotice），不用弹窗打断。
//
//  2026-11 界面换新：
//    - 间距、圆角全部走 DS.Space / DS.Radius，不再有字面量。
//    - 文件列表压成紧凑行；编辑区用原生 TextEditor。
//    - 「保存」按钮直接写明会写哪个文件（~/.zshrc），不再让人猜。
//

import SwiftUI

struct ShellConfigView: View {

    @EnvironmentObject private var controller: SleepController

    @State private var files: [ShellConfigFile] = []
    @State private var selectedID: String?
    @State private var original: String = ""
    @State private var draft: String = ""
    @State private var lastError: String?
    @State private var lastNotice: String?
    /// 语法检查没通过时的警告内容。非 nil 时显示「仍然保存 / 取消」。
    @State private var syntaxWarning: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionCard(
                title: "Shell 启动文件",
                subtitle: listSubtitle,
                symbol: "terminal.fill",
                accent: .accentColor
            ) {
                if files.isEmpty {
                    EmptyStateView(
                        title: "没有可编辑的启动文件",
                        message: "候选清单是空的，稍后重进这一页再试。",
                        systemImage: "doc.text"
                    )
                } else {
                    HStack(alignment: .top, spacing: DS.Space.md) {
                        fileList
                            .frame(width: 220, alignment: .leading)
                        Divider()
                        editor
                    }
                }
            }
        }
        .pageLayout()
        .task {
            reloadFiles()
            if let first = files.first(where: { $0.exists }) ?? files.first {
                select(first)
            }
        }
    }

    // MARK: - 左侧文件列表

    /// 紧凑行列表：一行一个文件名 + 一行元信息。
    ///
    /// 不用 List：文件只有 7 个候选，行列表更省地方，也不会在卡片里
    /// 再套一层系统侧边栏背景（卡片是页面上唯一的容器）。
    private var fileList: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            ForEach(files) { file in
                fileRow(file)
            }
            Spacer(minLength: 0)
        }
    }

    private func fileRow(_ file: ShellConfigFile) -> some View {
        let isSelected = file.id == selectedID
        return Button {
            select(file)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Text(file.name)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                if !file.exists {
                    Tag(text: "不存在", color: DS.Tone.idle)
                }
                Spacer(minLength: DS.Space.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DS.Space.xs)
            .padding(.horizontal, DS.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(isSelected ? DS.Tone.info.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(isSelected ? DS.Tone.info.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.exists ? file.url.path : "\(file.url.path)（保存后新建）")
        .accessibilityLabel(file.name)
        .accessibilityValue(isSelected ? "已选中" : (file.exists ? "已存在" : "不存在"))
    }

    private func fileMetaText(_ file: ShellConfigFile) -> String {
        let size = file.byteCount.map { "\($0) 字节" } ?? "大小未知"
        guard let modified = file.modifiedAt else { return size }
        return "\(size) · \(modified.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - 右侧编辑区

    @ViewBuilder
    private var editor: some View {
        if let file = selectedFile {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    Text(selectedName)
                        .font(.system(.headline, design: .monospaced))
                    Tag(text: file.shell.displayName, color: .purple)
                    if !file.exists {
                        Tag(text: "将新建", color: DS.Tone.caution)
                    }
                    Spacer(minLength: DS.Space.sm)
                    if !draft.isEmpty || !original.isEmpty {
                        Text("\(draft.count) 字符 · \(lineCount) 行")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 文件自身的元信息：大小与最后修改时间。
                Text(file.exists
                     ? "\(fileMetaText(file))"
                     : "文件还不存在，保存时新建。")
                    .caption2()

                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 320)
                    .scrollContentBackground(.hidden)
                    .padding(DS.Space.sm)
                    .insetPanel(cornerRadius: DS.Radius.control)
                    .disabled(isSaving)

                saveBar(file)

                if let syntaxWarning {
                    syntaxWarningPanel(syntaxWarning)
                }

                if let lastError {
                    messageRow(lastError, symbol: "exclamationmark.triangle.fill", tone: DS.Tone.critical)
                }
                if let lastNotice {
                    messageRow(lastNotice, symbol: "checkmark.circle.fill", tone: DS.Tone.good)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyStateView(
                title: "未选择文件",
                message: "从左边选一个启动文件开始改。",
                systemImage: "doc.text"
            )
        }
    }

    /// 保存区。按钮标题直接写明会写哪个文件 —— 保存的是用户家目录里的
    /// 真实启动文件，藏起来不说是拿用户文件冒险。
    private func saveBar(_ file: ShellConfigFile) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("保存到 ~/\(file.name)", systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave || isSaving)

                Button {
                    restoreBackup()
                } label: {
                    Label("恢复备份", systemImage: "arrow.uturn.backward")
                }
                .controlSize(.small)
                .disabled(!hasBackup || isSaving)

                Button {
                    reloadCurrent()
                } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(isSaving)

                Spacer(minLength: DS.Space.sm)
            }

            Text(file.exists
                 ? "保存会写入家目录下的 \(file.name)，并在同目录留一份 \(file.name).deepsleep.bak。"
                 : "保存会新建家目录下的 \(file.name)，并在同目录留一份 \(file.name).deepsleep.bak。")
                .caption2()

            // 「改完怎么生效」是用户下一步要做什么，放回编辑器里，
            // 不单开一张「生效方式」卡。
            BulletLine("改完新开终端窗口生效。")
            BulletLine("不想开新窗口，在当前窗口执行 `source ~/<文件名>` 立刻生效。")
        }
    }

    /// 内联消息。颜色 + 图标 + 文字三重编码，不靠颜色单独区分。
    private func messageRow(_ text: String, symbol: String, tone: Color) -> some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Image(systemName: symbol)
                .foregroundStyle(tone)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// 语法检查不通过的提示。带「仍然保存」——用户有权决定。
    private func syntaxWarningPanel(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Tone.caution)
                    .font(.system(size: 12, weight: .semibold))
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("语法检查没通过")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.Tone.caution)
                    Text(message)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: DS.Space.sm) {
                Button("仍然保存") {
                    performSave()
                }
                .controlSize(.small)
                Button("取消", role: .cancel) {
                    syntaxWarning = nil
                }
                .controlSize(.small)
            }
        }
        .padding(DS.Space.md)
        .background(DS.Tone.caution.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Tone.caution.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - 派生属性

    private var selectedFile: ShellConfigFile? {
        guard let selectedID else { return nil }
        return files.first { $0.id == selectedID }
    }

    private var selectedName: String {
        selectedFile?.name ?? "未选择文件"
    }

    private var listSubtitle: String {
        if files.isEmpty {
            return "正在读取候选文件……"
        }
        let existing = files.filter { $0.exists }.count
        return "共 \(files.count) 个候选文件，其中 \(existing) 个已存在。按 shell 的加载顺序排列。"
    }

    private var canSave: Bool {
        guard selectedFile != nil else { return false }
        guard !isSaving else { return false }
        return draft != original
    }

    private var hasBackup: Bool {
        guard let file = selectedFile else { return false }
        return ShellConfigService.hasBackup(for: file)
    }

    private var lineCount: Int {
        draft.isEmpty ? 0 : draft.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    // MARK: - 操作

    private func reloadFiles() {
        files = ShellConfigService.candidates()
    }

    private func select(_ file: ShellConfigFile) {
        selectedID = file.id
        lastError = nil
        lastNotice = nil
        syntaxWarning = nil
        reloadCurrent()
    }

    /// 从磁盘重新读当前文件。文件不存在时当成空内容（保存会新建）。
    private func reloadCurrent() {
        guard let file = selectedFile else { return }
        if !file.exists {
            original = ""
            draft = ""
            return
        }
        do {
            let content = try ShellConfigService.read(file)
            original = content
            draft = content
        } catch {
            original = ""
            draft = ""
            lastError = "\(error)"
        }
    }

    /// 点「保存」：先语法检查，通过了才真写。
    private func save() {
        guard let file = selectedFile else { return }
        lastError = nil
        lastNotice = nil
        syntaxWarning = nil
        guard canSave else { return }

        if let problem = ShellConfigService.syntaxCheck(content: draft, shell: file.shell, label: file.name) {
            syntaxWarning = problem
            return
        }
        performSave()
    }

    /// 真正写盘：备份 → 原子写入 → 回读校验（都在 service 里）。
    private func performSave() {
        guard let file = selectedFile else { return }
        isSaving = true
        defer { isSaving = false }
        syntaxWarning = nil
        do {
            try ShellConfigService.write(draft, to: file)
            original = draft
            lastNotice = file.exists
                ? "已保存 \(file.name)。新开终端窗口或执行 source ~/\(file.name) 后生效。"
                : "已创建 \(file.name)。新开终端窗口或执行 source ~/\(file.name) 后生效。"
            reloadFiles()
            controller.appendLog("已写入 shell 配置 \(file.name)")
        } catch {
            lastError = "\(error)"
            controller.appendLog("写入 \(file.name) 失败：\(error)", isError: true)
        }
    }

    private func restoreBackup() {
        guard let file = selectedFile else { return }
        lastError = nil
        lastNotice = nil
        syntaxWarning = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try ShellConfigService.restoreBackup(for: file)
            reloadCurrent()
            lastNotice = "已从备份恢复 \(file.name)。新开终端窗口或执行 source ~/\(file.name) 后生效。"
            controller.appendLog("已恢复 shell 配置备份 \(file.name)")
        } catch {
            lastError = "\(error)"
            controller.appendLog("恢复 \(file.name) 备份失败：\(error)", isError: true)
        }
    }
}
