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
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(
                title: "Shell 启动文件",
                subtitle: listSubtitle,
                symbol: "terminal.fill",
                accent: .accentColor
            ) {
                HStack(alignment: .top, spacing: 14) {
                    fileList
                        .frame(width: 236, alignment: .leading)
                    Divider()
                    editor
                }
            }

            SectionCard(
                title: "加载顺序与注意事项",
                subtitle: nil,
                symbol: "info.circle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    BulletLine("zsh：.zshenv → .zprofile → .zshrc → .zlogin。改完新开终端窗口才生效。")
                    BulletLine("bash：.bash_profile → .bashrc。本机 .bash_profile 里通常自己 source 了 .bashrc。")
                    BulletLine(".profile 是 POSIX sh 的老写法，语法检查按 bash 走。")
                    BulletLine("保存时会在同目录留一份 <文件名>.deepsleep.bak，点「恢复备份」可以写回去。")
                    BulletLine("写入是原子的：先写临时文件再 rename，写到一半断电不会留下半截的 .zshrc。")
                    BulletLine("不想开新窗口的话，在当前窗口执行 source ~/.zshrc 立刻生效。")
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

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(file.name)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                    if !file.exists {
                        Tag(text: "不存在", color: .secondary)
                    }
                    Spacer(minLength: 0)
                }
                if file.exists {
                    Text(fileMetaText(file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("保存后新建")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fileMetaText(_ file: ShellConfigFile) -> String {
        let size = file.byteCount.map { "\($0) 字节" } ?? "大小未知"
        guard let modified = file.modifiedAt else { return size }
        return "\(size) · \(modified.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - 右侧编辑区

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(selectedName)
                    .font(.system(.headline, design: .monospaced))
                if let file = selectedFile {
                    Tag(text: file.shell.displayName, color: .purple)
                    if !file.exists {
                        Tag(text: "将新建", color: .orange)
                    }
                }
                Spacer(minLength: 8)
                if !draft.isEmpty || !original.isEmpty {
                    Text("\(draft.count) 字符 · \(lineCount) 行")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 300)
                .border(Color.primary.opacity(0.12), width: 1)
                .disabled(isSaving)

            HStack(spacing: 8) {
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("保存", systemImage: "square.and.arrow.down")
                    }
                }
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

                Spacer(minLength: 0)
            }

            if let syntaxWarning {
                syntaxWarningPanel(syntaxWarning)
            }

            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let lastNotice {
                Text(lastNotice)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 语法检查不通过的提示。带「仍然保存」——用户有权决定。
    private func syntaxWarningPanel(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("语法检查没通过")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
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
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
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
