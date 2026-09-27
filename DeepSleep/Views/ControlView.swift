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
