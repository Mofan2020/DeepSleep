//
//  ControlView.swift
//  Deep Sleep
//
//  「完全控制」页：特权助手的安装、状态与最彻底的睡眠禁用开关。
//
//  界面约定：
//    - 安装流程的每一步状态（未安装 / 安装中 / 已就绪 / 失败原因）都用
//      「StatusPill + 文字」双编码，不靠颜色单独区分。
//    - 「完全禁止系统睡眠」是危险开关：橙色 + 明确后果说明，
//      在视觉上与页面里的普通开关分开。
//    - 认证流程的文案一个字都不改 —— 它是用户判断「要不要授权」的唯一依据。
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
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            helperCard
            disableSleepCard
            exitBehaviourCard
            emailCard
            permissionCard
            securityCard
        }
    }

    // MARK: - 特权助手

    private var helperCard: some View {
        SectionCard(
            title: "特权助手",
            subtitle: helperStateSubtitle,
            symbol: helperState.isReady ? "lock.shield.fill" : "lock.shield",
            accent: helperStatusColor,
            accessory: AnyView(
                StatusPill(
                    text: helperStatusText,
                    isActive: helperState.isReady,
                    color: helperStatusColor
                )
            )
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                // 协议版本 / 安装中的进度提示。
                HStack(spacing: DS.Space.sm) {
                    if case .ready(let version) = helperState {
                        Tag(text: "协议 v\(version)", color: DS.Tone.good)
                    }
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在请求管理员授权…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                // 失败原因：单独一行醒目显示，不塞在副标题里被弱化。
                if case .failed(let reason) = helperState {
                    Label("安装失败：\(reason)", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(DS.Tone.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: DS.Space.sm) {
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

                    Spacer(minLength: 0)
                }

                if helperState.isReady {
                    Text("后续所有提权操作都只需 \(BiometricAuth.availableMethodDescription) 确认，不会再要求输入管理员密码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
    }

    /// 助手状态词。颜色之外必须带文字 —— 状态不能只靠颜色区分。
    private var helperStatusText: String {
        if isWorking { return "安装中…" }
        switch helperState {
        case .unknown:             return "正在检测…"
        case .notInstalled:        return "未安装"
        case .installedNotRunning: return "已安装但未运行"
        case .ready:               return "已就绪"
        case .versionMismatch:     return "版本不匹配"
        case .failed:              return "安装失败"
        }
    }

    private var helperStatusColor: Color {
        if isWorking { return DS.Tone.info }
        switch helperState {
        case .unknown:             return DS.Tone.info
        case .notInstalled:        return DS.Tone.idle
        case .installedNotRunning: return DS.Tone.caution
        case .ready:               return DS.Tone.good
        case .versionMismatch:     return DS.Tone.caution
        case .failed:              return DS.Tone.critical
        }
    }

    /// 失败原因单独用醒目的正文显示，副标题就不重复它了。
    private var helperStateSubtitle: String? {
        if case .failed = helperState { return nil }
        return helperState.detail
    }

    // MARK: - 完全禁止系统睡眠（危险开关）

    private var disableSleepCard: some View {
        SectionCard(
            title: "完全禁止系统睡眠",
            subtitle: "写入系统级设置（pmset disablesleep），效果是连合上盖子也不会睡眠。这是控制力最强、也最耗电的一档。开启后会同时持有一枚系统级断言，并在每 3 秒的对账中持续校验——被外部程序改回时立即恢复。",
            symbol: "exclamationmark.octagon",
            accent: DS.Tone.caution
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                // 后果说明单独成块：这一页里只有它带警告色，
                // 用户一眼就知道这个开关跟别的不一样。
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Label("危险开关：开启后系统不再睡眠，合上盖子也不睡，电量会一直掉。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(DS.Tone.caution)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("退出 Deep Sleep 时会自动恢复为关闭，避免忘记后电池被耗尽。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .insetPanel()

                Toggle(isOn: Binding(
                    get: { controller.sleepDisabled },
                    set: { newValue in
                        Task { await controller.setSleepDisabled(newValue) }
                    }
                )) {
                    Text("完全禁止系统睡眠").font(.body.weight(.medium))
                }
                .toggleStyle(.switch)
                .tint(DS.Tone.caution)
                .disabled(!helperState.isReady)

                if !helperState.isReady {
                    Label("需要先启用完全控制", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(DS.Tone.caution)
                }
            }
        }
    }

    // MARK: - 退出时的行为

    private var exitBehaviourCard: some View {
        SectionCard(
            title: "退出 Deep Sleep 时的行为",
            subtitle: nil,
            symbol: "arrow.uturn.down.circle",
            accent: .accentColor
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Toggle(isOn: $controller.preservesStateOnExit) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("保留 assertion 与 disablesleep").font(.body.weight(.medium))
                        Text("开启后退出应用时不释放系统级睡眠断言，也不恢复 `pmset disablesleep`。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                    .foregroundStyle(DS.Tone.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DS.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .insetPanel()
                }
            }
        }
    }

    // MARK: - 邮件告警

    private var emailCard: some View {
        SectionCard(
            title: "邮件告警",
            subtitle: emailSubtitle,
            symbol: "envelope",
            accent: .accentColor
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
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
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        LabeledContent("SMTP 服务器") {
                            TextField("如 smtp.qq.com", text: Binding(
                                get: { emailConfig.host },
                                set: { emailConfig.host = $0; emailConfig.saveToDefaults() }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }

                        LabeledContent("端口") {
                            HStack(spacing: DS.Space.sm) {
                                TextField("465", value: Binding(
                                    get: { emailConfig.port },
                                    set: { emailConfig.port = $0; emailConfig.saveToDefaults() }
                                ), format: .number)
                                .textFieldStyle(.roundedBorder)
                                Toggle("TLS", isOn: Binding(
                                    get: { emailConfig.useTLS },
                                    set: { emailConfig.useTLS = $0; emailConfig.saveToDefaults() }
                                ))
                                .toggleStyle(.switch)
                            }
                        }

                        LabeledContent("用户名") {
                            TextField("如 user@qq.com", text: Binding(
                                get: { emailConfig.username },
                                set: { emailConfig.username = $0; emailConfig.saveToDefaults() }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }

                        LabeledContent("密码") {
                            HStack(spacing: DS.Space.sm) {
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
                        }

                        LabeledContent("发件人") {
                            TextField("如 noreply@qq.com", text: Binding(
                                get: { emailConfig.fromAddress },
                                set: { emailConfig.fromAddress = $0; emailConfig.saveToDefaults() }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }

                        LabeledContent("收件人") {
                            TextField("如 me@example.com", text: Binding(
                                get: { emailConfig.toAddress },
                                set: { emailConfig.toAddress = $0; emailConfig.saveToDefaults() }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }

                        LabeledContent("主题前缀") {
                            TextField("DeepSleep", text: Binding(
                                get: { emailConfig.subjectPrefix },
                                set: { emailConfig.subjectPrefix = $0; emailConfig.saveToDefaults() }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }

                        HStack(spacing: DS.Space.sm) {
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
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DS.Tone.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let summary = emailLastSummary {
                    Label(summary, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(DS.Tone.good)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 权限模型

    private var permissionCard: some View {
        SectionCard(
            title: "权限模型",
            subtitle: nil,
            symbol: "key.horizontal"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
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
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("每次提权操作都要求确认").font(.body.weight(.medium))
                        Text("关闭后提权操作将直接执行，不再弹出确认。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    // MARK: - 安全设计

    private var securityCard: some View {
        SectionCard(
            title: "安全设计",
            symbol: "checkmark.seal"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
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
        HStack(alignment: .top, spacing: DS.Space.md) {
            Text("\(index)")
                .font(.system(size: 12, weight: .bold))
                .frame(width: DS.Space.xl, height: DS.Space.xl)
                .background(Color.accentColor.opacity(0.16), in: Circle())
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
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
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.Tone.good)
                .padding(.top, DS.Space.xs)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
