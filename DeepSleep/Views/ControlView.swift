//
//  ControlView.swift
//  Deep Sleep
//
//  「完全控制」页：特权助手的安装、状态与最彻底的睡眠禁用开关。
//

import SwiftUI

struct ControlView: View {

    @EnvironmentObject private var controller: SleepController
    @State private var isWorking = false
    @State private var showUninstallConfirm = false

    // 邮件告警：本地状态 + 操作。
    @State private var emailConfig: EmailConfig = EmailConfig.loadFromDefaults()
    @State private var emailPassword: String = ""
    @State private var emailIsWorking = false
    @State private var emailLastError: String?
    @State private var emailLastSummary: String?

    private var helperState: HelperState { controller.helperState }

    var body: some View {
        SectionCard(
            title: "特权助手",
            subtitle: helperState.detail,
            symbol: helperState.isReady ? "lock.shield.fill" : "lock.shield",
            accent: helperState.isReady ? .green : .orange
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    StatusPill(text: helperState.title, isActive: helperState.isReady)
                    if case .ready(let version) = helperState {
                        Tag(text: "协议 v\(version)", color: .green)
                    }
                    Spacer()
                }

                HStack(spacing: 10) {
                    if helperState.isReady {
                        Button {
                            showUninstallConfirm = true
                        } label: {
                            Label("停用并卸载", systemImage: "trash")
                        }
                        .disabled(isWorking)

                        Button {
                            isWorking = true
                            Task {
                                await controller.refreshHelperState()
                                isWorking = false
                            }
                        } label: {
                            Label("重新检测", systemImage: "arrow.clockwise")
                        }
                        .disabled(isWorking)
                    } else {
                        Button {
                            isWorking = true
                            Task {
                                await controller.installHelper()
                                isWorking = false
                            }
                        } label: {
                            Label("启用完全控制", systemImage: "lock.open")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                    }

                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }

                if helperState.isReady {
                    Text("后续所有提权操作都只需 \(BiometricAuth.availableMethodDescription) 确认，不会再要求输入管理员密码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .alert("停用完全控制？", isPresented: $showUninstallConfirm) {
            Button("取消", role: .cancel) {}
            Button("停用并卸载", role: .destructive) {
                isWorking = true
                Task {
                    await controller.uninstallHelper()
                    isWorking = false
                }
            }
        } message: {
            Text("将移除特权助手与对应的 launchd 任务，/Library 下的相关文件会被清理，系统回到安装前状态。")
        }

        SectionCard(
            title: "完全禁止系统睡眠",
            subtitle: "写入系统级设置（pmset disablesleep），效果是连合上盖子也不会睡眠。这是控制力最强、也最耗电的一档。开启后会同时持有一枚系统级断言，并在每 3 秒的对账中持续校验——被外部程序改回时立即恢复。",
            symbol: "exclamationmark.octagon",
            accent: .orange
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { controller.sleepDisabled },
                    set: { newValue in
                        Task { await controller.setSleepDisabled(newValue) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("完全禁止系统睡眠").font(.body.weight(.medium))
                        Text("退出 Deep Sleep 时会自动恢复为关闭，避免忘记后电池被耗尽。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!helperState.isReady)

                if !helperState.isReady {
                    Label("需要先启用完全控制", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }

        SectionCard(
            title: "退出 Deep Sleep 时的行为",
            subtitle: nil,
            symbol: "arrow.uturn.down.circle",
            accent: .accentColor
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $controller.preservesStateOnExit) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("保留 assertion 与 disablesleep").font(.body.weight(.medium))
                        Text("开启后退出应用时不释放系统级睡眠断言，也不恢复 `pmset disablesleep`。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if controller.preservesStateOnExit {
                    Label(
                        "进程退出后，Deep Sleep 无法再纠正外部对 disablesleep 或 assertion 的改动。"
                        + "需要手动停用「完全控制」或重启系统来恢复。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        SectionCard(
            title: "邮件告警",
            subtitle: emailSubtitle,
            symbol: "envelope",
            accent: .accentColor
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { emailConfig.enabled },
                    set: { newValue in
                        emailConfig.enabled = newValue
                        emailConfig.saveToDefaults()
                    }
                )) {
                    Text("启用邮件告警").font(.body.weight(.medium))
                }
                .toggleStyle(.switch)

                if emailConfig.enabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("SMTP 服务器").frame(width: 110, alignment: .leading)
                            TextField("如 smtp.qq.com", text: Binding(
                                get: { emailConfig.host },
                                set: { emailConfig.host = $0; emailConfig.saveToDefaults() }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("端口").frame(width: 110, alignment: .leading)
                            TextField("465", value: Binding(
                                get: { emailConfig.port },
                                set: { emailConfig.port = $0; emailConfig.saveToDefaults() }
                            ), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            Toggle("TLS", isOn: Binding(
                                get: { emailConfig.useTLS },
                                set: { emailConfig.useTLS = $0; emailConfig.saveToDefaults() }
                            ))
                            .toggleStyle(.checkbox)
                        }
                        HStack {
                            Text("用户名").frame(width: 110, alignment: .leading)
                            TextField("如 user@qq.com", text: Binding(
                                get: { emailConfig.username },
                                set: { emailConfig.username = $0; emailConfig.saveToDefaults() }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("密码").frame(width: 110, alignment: .leading)
                            SecureField("SMTP 密码 / app password", text: $emailPassword)
                                .textFieldStyle(.roundedBorder)
                            Button("保存密码") {
                                Task {
                                    do {
                                        try await EmailChannel.shared.savePassword(emailPassword)
                                        emailLastSummary = "密码已写入 Keychain"
                                        emailLastError = nil
                                    } catch {
                                        emailLastError = "保存失败：\(error.localizedDescription)"
                                    }
                                }
                            }
                            .controlSize(.small)
                            .disabled(emailPassword.isEmpty)
                        }
                        HStack {
                            Text("发件人").frame(width: 110, alignment: .leading)
                            TextField("如 noreply@qq.com", text: Binding(
                                get: { emailConfig.fromAddress },
                                set: { emailConfig.fromAddress = $0; emailConfig.saveToDefaults() }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("收件人").frame(width: 110, alignment: .leading)
                            TextField("如 me@example.com", text: Binding(
                                get: { emailConfig.toAddress },
                                set: { emailConfig.toAddress = $0; emailConfig.saveToDefaults() }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("主题前缀").frame(width: 110, alignment: .leading)
                            TextField("DeepSleep", text: Binding(
                                get: { emailConfig.subjectPrefix },
                                set: { emailConfig.subjectPrefix = $0; emailConfig.saveToDefaults() }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Button {
                                Task { await sendTestEmail() }
                            } label: {
                                if emailIsWorking {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("发送测试邮件", systemImage: "paperplane")
                                }
                            }
                            .controlSize(.small)
                            .disabled(emailIsWorking || !emailConfig.isConfigured)

                            Text(emailConfig.isConfigured
                                 ? "配置就绪。"
                                 : "还需填 host / 用户名 / 发件人 / 收件人才能发邮件。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .controlSize(.small)
                }

                if let err = emailLastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let summary = emailLastSummary {
                    Text(summary).font(.caption).foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        SectionCard(
            title: "权限模型",
            subtitle: nil,
            symbol: "key.horizontal"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                PermissionStep(
                    index: 1,
                    title: "一次性管理员授权",
                    detail: "启用完全控制时，系统弹出一次授权对话框（已配置 Touch ID 的机器可直接用指纹确认），用于写入特权助手。"
                )
                PermissionStep(
                    index: 2,
                    title: "此后仅需本地确认",
                    detail: "每次需要提权的操作（合盖防休眠、改电源设置、排定唤醒）只要求 \(BiometricAuth.availableMethodDescription) 确认。"
                )
                PermissionStep(
                    index: 3,
                    title: "可随时完全回退",
                    detail: "「停用并卸载」会移除 /Library 下的全部文件与 launchd 任务，系统回到安装前状态。"
                )

                Divider()

                AutoStartToggle()

                Divider()

                Toggle(isOn: $controller.requireConfirmationPerAction) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("每次提权操作都要求确认").font(.body.weight(.medium))
                        Text("关闭后提权操作将直接执行，不再弹出确认。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }

        SectionCard(
            title: "安全设计",
            symbol: "checkmark.seal"
        ) {
            VStack(alignment: .leading, spacing: 7) {
                BulletLine("助手通过 UNIX socket 通信，socket 归当前登录用户所有、权限 0600。")
                BulletLine("每个连接都用 getpeereid() 校验对端 uid，其他用户无法连接。")
                BulletLine("可写入的 pmset 键有白名单，取值必须是纯数字，杜绝参数注入。")
                BulletLine("助手只接受固定的命令行协议，不执行任何外部传入的 shell 字符串。")
            }
        }
    }

    // MARK: - 邮件

    private var emailSubtitle: String {
        if emailConfig.enabled {
            if emailConfig.isConfigured {
                return "已启用，告警将发到 \(emailConfig.toAddress)"
            }
            return "已启用，但配置不完整。下方填完后才能发送。"
        }
        return "未启用。监控告警可同时通过邮件渠道通知（独立于 macOS 通知）。"
    }

    private func sendTestEmail() async {
        emailLastError = nil
        emailLastSummary = nil
        emailIsWorking = true
        defer { emailIsWorking = false }
        let result = await EmailChannel.shared.sendTest()
        switch result {
        case .success:
            emailLastSummary = "已发送测试邮件，请到 \(emailConfig.toAddress) 收件箱查收"
        case .failure(let reason):
            emailLastError = "发送失败：\(reason)"
        }
    }
}

// MARK: - 子组件

struct PermissionStep: View {
    let index: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text("\(index)")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.16), in: Circle())
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct BulletLine: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
                .padding(.top, 4)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
