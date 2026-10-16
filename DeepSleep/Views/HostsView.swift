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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(
                title: "Hosts 文件",
                subtitle: helperSubtitle,
                symbol: "doc.text.fill",
                accent: .accentColor
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button {
                            Task { await refresh() }
                        } label: {
                            if isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("重新加载", systemImage: "arrow.clockwise")
                            }
                        }
                        .controlSize(.small)
                        .disabled(isLoading)

                        Button {
                            Task { await restoreBackup() }
                        } label: {
                            Label("从备份恢复", systemImage: "arrow.uturn.backward")
                        }
                        .controlSize(.small)
                        .disabled(isLoading || isSaving || !hasBackup)

                        Spacer()

                        if !draft.isEmpty {
                            Text("\(byteCount) 字节 · \(lineCount) 行")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    TextEditor(text: $draft)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 280)
                        .border(Color.primary.opacity(0.12), width: 1)
                        .disabled(isLoading || isSaving)

                    HStack(spacing: 8) {
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
                        .disabled(!canSave)
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
            }

            SectionCard(
                title: "谁能修改 Hosts",
                subtitle: "空白名单表示任何 uid 都可改（默认开放）。填入 uid 后只有白名单内的用户能改 Hosts 与本白名单。uid 与用户名两组是独立的：填 uid 即便用户名不对也能通过；填用户名助手启动时会展开为 uid。",
                symbol: "person.crop.circle.badge.checkmark"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("uid（逗号分隔）")
                                .font(.caption.weight(.medium))
                            TextField("例如 501, 502", text: $editorUidsRaw)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isSavingEditors)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("用户名（逗号分隔）")
                                .font(.caption.weight(.medium))
                            TextField("例如 mofan, alice", text: $editorUsernamesRaw)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isSavingEditors)
                        }
                    }

                    HStack(spacing: 8) {
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
                        .disabled(isSavingEditors || !controller.helperState.isReady)

                        Button {
                            Task { await loadEditors() }
                        } label: {
                            Label("重新读取", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .disabled(isSavingEditors)
                    }

                    BulletLine("白名单为空时所有 uid 都能改 Hosts；写入第一个 uid 后立刻收紧。")
                    BulletLine("改 Hosts 与改本白名单共用同一份白名单 —— 这是为了让「加自己」这件事也得先得到现有白名单批准。")
                }
            }

            SectionCard(
                title: "注意事项",
                subtitle: nil,
                symbol: "info.circle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    BulletLine("写入后原文备份在 `/etc/hosts.deepsleep.bak`，下次写入会被覆盖。")
                    BulletLine("macOS 自带的 `sudo vi /etc/hosts` 不会改本白名单 —— 它直接走 root，与本工具无关。")
                    BulletLine("如果改了 Hosts 后浏览器 / `ping` 看不到效果，运行 `sudo dscacheutil -flushcache` 刷新 DNS 缓存（不在本工具职责范围）。")
                    BulletLine("白名单以 root 写入 `/Library/Application Support/com.skyc8266.deepsleep/hosts-editors.plist`，mode `0600`。")
                }
            }
        }
        .task {
            await refresh()
            await loadEditors()
        }
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