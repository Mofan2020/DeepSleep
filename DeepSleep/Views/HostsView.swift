//
//  HostsView.swift
//  Deep Sleep
//
//  Hosts 编辑页面：显示当前 `/etc/hosts` 内容，保存修改并支持「谁能改 hosts」
//  白名单管理。
//
//  设计：
//    - 编辑器是单文件多行 TextEditor（非 diff/patch），提交时整体写回；
//      与助手协议（writeHosts 接收完整 content）一致。
//    - 「保存」按钮先在本地验证（UTF-8 / 非空），再发给助手；
//    - 「恢复默认」按钮把当前内容回滚到最近一次备份（`/etc/hosts.deepsleep.bak`）。
//      没有备份就灰显。
//    - 白名单编辑：uid / 用户名两组文本框，逗号分隔；
//      应用侧只做整理 + 发送，是否允许写由助手判定。
//
//  与其他页面的对齐：
//    - 助手未就绪时整页仍可见（不阻塞 UI 渲染），按钮置灰 + 副标题解释；
//    - 错误用 banner + 内联 message 两路（与 NiceView 等一致）。
//
//  2026-11 界面换新：
//    - 编辑器本身保留（不换成别的控件），周边布局改用原生控件重排：
//      LabeledContent 说明当前文件状态，按钮用 LabeledContent 分组；
//    - 「谁能改 hosts」的白名单条目改成紧凑行列表（每行一个 uid 或用户名），
//      配原生 Toggle；文本框仍然保留用于录入原始值；
//    - 保存 / 还原按钮主次分明：保存是 prominent，还原是次级。
//

import SwiftUI

struct HostsView: View {

    @EnvironmentObject private var controller: SleepController

    @State private var original: String = ""
    @State private var draft: String = ""
    @State private var lastError: String?
    @State private var lastNotice: String?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var byteCount: Int = 0
    @State private var hasBackup: Bool = false

    @State private var editors: HostsAllowedEditors.Snapshot = .init(uids: [], usernames: [])
    @State private var editorUidsRaw: String = ""
    @State private var editorUsernamesRaw: String = ""
    @State private var isSavingEditors = false

    /// 被开关关掉、暂时移出草稿的条目。
    ///
    /// 留着是为了让那一行还在列表里（显示「已移出白名单」），用户反悔时
    /// 能直接打开，不用去文本框里重敲一遍。
    @State private var removedUids: Set<Int> = []
    @State private var removedNames: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionCard(
                title: "Hosts 文件",
                subtitle: helperSubtitle,
                symbol: "doc.text.fill",
                accent: .accentColor
            ) {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    // 当前文件状态：行数 / 字节数 / 备份。
                    LabeledContent("当前文件") {
                        HStack(spacing: DS.Space.sm) {
                            Text(byteCount > 0 ? "\(byteCount) 字节 · \(lineCount) 行" : "尚未读取")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if hasBackup {
                                Tag(text: "有备份", color: DS.Tone.good)
                            } else {
                                Tag(text: "无备份", color: DS.Tone.idle)
                            }
                        }
                    }

                    TextEditor(text: $draft)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 280)
                        .insetPanel(cornerRadius: DS.Radius.control)
                        .disabled(isLoading || isSaving)

                    // 主次分明：保存是主动作（prominent，靠右），还原与重新加载是次级动作。
                    HStack(spacing: DS.Space.sm) {
                        Button {
                            Task { await refresh() }
                        } label: {
                            if isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("重新加载", systemImage: "arrow.clockwise")
                            }
                        }
                        .controlSize(.regular)
                        .disabled(isLoading)

                        Spacer()

                        Button {
                            Task { await restoreBackup() }
                        } label: {
                            Label("从备份还原", systemImage: "arrow.uturn.backward")
                        }
                        .controlSize(.regular)
                        .disabled(isLoading || isSaving || !hasBackup)

                        Button {
                            Task { await save() }
                        } label: {
                            if isSaving {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("保存到 /etc/hosts", systemImage: "square.and.arrow.down")
                            }
                        }
                        .controlSize(.regular)
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                    }

                    if let lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(DS.Tone.critical)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let lastNotice {
                        Text(lastNotice)
                            .font(.caption)
                            .foregroundStyle(DS.Tone.good)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 两条「用户要动手才能解决」的信息：备份在哪、缓存怎么刷。
                    // 不单独开一张「注意事项」卡 —— 放回它所属的这张卡里，
                    // 用户改 Hosts 时正好会看到。
                    BulletLine("原文备份在 `/etc/hosts.deepsleep.bak`，下次写入会覆盖。")
                    BulletLine("改了 Hosts 后浏览器 / `ping` 没变化，运行 `sudo dscacheutil -flushcache` 刷新 DNS 缓存。")
                }
            }

            SectionCard(
                title: "谁能修改 Hosts",
                subtitle: "留空表示谁都能改。填了之后只有名单里的人能改。uid 和用户名可以分开填。",
                symbol: "person.crop.circle.badge.checkmark"
            ) {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    HStack(alignment: .top, spacing: DS.Space.md) {
                        LabeledContent("uid（逗号分隔）") {
                            TextField("例如 501, 502", text: $editorUidsRaw)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isSavingEditors)
                        }
                        LabeledContent("用户名（逗号分隔）") {
                            TextField("例如 mofan, alice", text: $editorUsernamesRaw)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isSavingEditors)
                        }
                    }

                    // 白名单条目：紧凑行列表 + 原生开关。
                    // 开关只改本地草稿（uidsRaw / usernamesRaw），真正生效仍靠
                    // 下面的「保存白名单」走助手 —— 不绕过助手授权。
                    SubsectionHeader(title: "白名单条目", symbol: "person.text.rectangle")
                    whitelistList

                    HStack(spacing: DS.Space.sm) {
                        Button {
                            Task { await saveEditors() }
                        } label: {
                            if isSavingEditors {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("保存白名单", systemImage: "person.badge.shield.checkmark")
                            }
                        }
                        .controlSize(.regular)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSavingEditors || !controller.helperState.isReady)

                        Button {
                            Task { await loadEditors() }
                        } label: {
                            Label("重新读取", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.regular)
                        .disabled(isSavingEditors)

                        Spacer()
                    }
                }
            }
        }
        .task {
            await refresh()
            await loadEditors()
        }
    }

    // MARK: - 白名单列表

    /// 白名单条目的紧凑行列表。
    ///
    /// 每行 = 一个 uid 或一个用户名 + 一个原生开关。开关只改本地草稿
    /// （uidsRaw / usernamesRaw），真正生效仍靠下面的「保存白名单」走助手 ——
    /// 白名单写入本来就需要助手授权，这里不绕过那条路径。
    ///
    /// 关掉的条目不从列表消失，而是留在原地显示为「已移出白名单」，
    /// 这样随时能再打开；打开时把它加回草稿，保存后才会真的生效。
    private var whitelistList: some View {
        let uids = HostsAllowedEditors.parseUids(editorUidsRaw)
        let names = HostsAllowedEditors.parseUsernames(editorUsernamesRaw)
        // 列表 = 草稿里有的 + 之前被关掉的（关掉的不再写进草稿，但保留可见）。
        let allUids = uids + removedUids.filter { !uids.contains($0) }
        let allNames = names + removedNames.filter { !names.contains($0) }

        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            if allUids.isEmpty && allNames.isEmpty {
                Label("空白名单：任何人都能改 Hosts。", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(DS.Tone.caution)
            } else {
                ForEach(allUids, id: \.self) { uid in
                    whitelistRow(
                        title: "uid \(uid)",
                        subtitle: uids.contains(uid) ? "用户 ID · 已在白名单" : "用户 ID · 已移出白名单",
                        isOn: Binding(
                            get: { uids.contains(uid) },
                            set: { newValue in
                                if newValue {
                                    removedUids.remove(uid)
                                    editorUidsRaw = (HostsAllowedEditors.parseUids(editorUidsRaw) + [uid])
                                        .map(String.init)
                                        .joined(separator: ", ")
                                } else {
                                    removedUids.insert(uid)
                                    editorUidsRaw = HostsAllowedEditors.parseUids(editorUidsRaw)
                                        .filter { $0 != uid }
                                        .map(String.init)
                                        .joined(separator: ", ")
                                }
                            }
                        )
                    )
                }
                ForEach(allNames, id: \.self) { name in
                    whitelistRow(
                        title: name,
                        subtitle: names.contains(name) ? "用户名 · 已在白名单" : "用户名 · 已移出白名单",
                        isOn: Binding(
                            get: { names.contains(name) },
                            set: { newValue in
                                if newValue {
                                    removedNames.remove(name)
                                    editorUsernamesRaw = (HostsAllowedEditors.parseUsernames(editorUsernamesRaw) + [name])
                                        .joined(separator: ", ")
                                } else {
                                    removedNames.insert(name)
                                    editorUsernamesRaw = HostsAllowedEditors.parseUsernames(editorUsernamesRaw)
                                        .filter { $0 != name }
                                        .joined(separator: ", ")
                                }
                            }
                        )
                    )
                }
            }
        }
        .padding(DS.Space.md)
        .insetPanel(cornerRadius: DS.Radius.control)
    }

    /// 白名单行：标题 + 说明 + 原生开关。
    private func whitelistRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title)
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.sm)
            Toggle("允许修改 Hosts", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("允许 \(title) 修改 Hosts")
        }
        .padding(.vertical, DS.Space.xxs)
    }

    // MARK: - 派生属性

    private var helperSubtitle: String {
        if !controller.helperState.isReady {
            return "助手未就绪：需要先在「完全控制」页启用（首次启用需要管理员授权）。"
        }
        if original.isEmpty {
            return "点击「重新加载」读取 /etc/hosts。"
        }
        return "当前 /etc/hosts 共 \(lineCount) 行、\(byteCount) 字节。"
    }

    private var canSave: Bool {
        guard controller.helperState.isReady else { return false }
        guard !isSaving else { return false }
        guard !draft.isEmpty else { return false }
        guard draft != original else { return false }
        return true
    }

    private var lineCount: Int {
        draft.isEmpty ? 0 : draft.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    // MARK: - 操作

    private func refresh() async {
        lastError = nil
        lastNotice = nil
        guard controller.helperState.isReady else {
            original = ""
            draft = ""
            byteCount = 0
            hasBackup = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await HostsService.shared.read()
            original = snapshot.content
            draft = snapshot.content
            byteCount = snapshot.byteCount
            hasBackup = FileManager.default.fileExists(atPath: "/etc/hosts.deepsleep.bak")
            controller.appendLog("已读取 /etc/hosts（\(snapshot.byteCount) 字节）")
        } catch {
            lastError = "\(error)"
            controller.appendLog("读取 hosts 失败：\(error)", isError: true)
        }
    }

    private func save() async {
        guard canSave else { return }
        lastError = nil
        lastNotice = nil
        isSaving = true
        defer { isSaving = false }
        let pending = draft
        do {
            let summary = try await HostsService.shared.write(pending)
            original = pending
            byteCount = pending.utf8.count
            hasBackup = true
            lastNotice = summary
            controller.appendLog("已写入 /etc/hosts")
        } catch {
            lastError = "\(error)"
            controller.appendLog("写入 hosts 失败：\(error)", isError: true)
        }
    }

    private func restoreBackup() async {
        guard hasBackup else { return }
        let backup = "/etc/hosts.deepsleep.bak"
        guard let content = try? String(contentsOfFile: backup, encoding: .utf8) else {
            lastError = "无法读取备份 \(backup)"
            return
        }
        // 写入当前 hosts（用同一个 writeHosts 路径，自动备份当前 + chown/chmod）
        lastError = nil
        lastNotice = nil
        isSaving = true
        defer { isSaving = false }
        do {
            let summary = try await HostsService.shared.write(content)
            original = content
            draft = content
            byteCount = content.utf8.count
            lastNotice = "已从备份恢复：\(summary)"
            controller.appendLog("从备份恢复 hosts")
        } catch {
            lastError = "\(error)"
            controller.appendLog("从备份恢复失败：\(error)", isError: true)
        }
    }

    private func loadEditors() async {
        guard controller.helperState.isReady else { return }
        do {
            let snapshot = try await HostsService.shared.editors()
            editors = snapshot
            editorUidsRaw = snapshot.uids.map(String.init).joined(separator: ", ")
            editorUsernamesRaw = snapshot.usernames.joined(separator: ", ")
            // 重新读取 = 放弃本地改动，被关掉的条目也不再保留。
            removedUids = []
            removedNames = []
        } catch {
            lastError = "读取白名单失败：\(error)"
            controller.appendLog("读取 hosts 白名单失败：\(error)", isError: true)
        }
    }

    private func saveEditors() async {
        guard controller.helperState.isReady else { return }
        lastError = nil
        isSavingEditors = true
        defer { isSavingEditors = false }
        let uids = HostsAllowedEditors.parseUids(editorUidsRaw)
        let usernames = HostsAllowedEditors.parseUsernames(editorUsernamesRaw)
        do {
            let snapshot = try await HostsService.shared.setEditors(
                uids: uids, usernames: usernames)
            editors = snapshot
            editorUidsRaw = snapshot.uids.map(String.init).joined(separator: ", ")
            editorUsernamesRaw = snapshot.usernames.joined(separator: ", ")
            removedUids = []
            removedNames = []
            lastNotice = snapshot.isEmpty
                ? "白名单已清空：任何 uid 都可改 Hosts"
                : "白名单已保存：uid=\(snapshot.uids)，names=\(snapshot.usernames)"
            controller.appendLog("hosts 白名单已更新")
        } catch {
            lastError = "\(error)"
            controller.appendLog("保存 hosts 白名单失败：\(error)", isError: true)
        }
    }
}
