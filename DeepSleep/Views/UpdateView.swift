//
//  UpdateView.swift
//  Deep Sleep
//
//  「更新」页：应用自身的自动更新，以及特权助手的版本与更新。
//

import SwiftUI

struct UpdateView: View {

    @ObservedObject private var updates = UpdateManager.shared
    @ObservedObject private var helper = HelperVersionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            applicationCard
            helperCard
            mechanismCard
        }
    }

    // MARK: - 应用更新

    private var applicationCard: some View {
        SectionCard(
            title: "应用更新",
            subtitle: "从 GitHub Release 拉取 DeepSleep.zip，校验通过后由一个"
                + "临时目录里的更新器替换本应用并重新启动。",
            symbol: "arrow.down.circle",
            accent: .accentColor
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("当前版本 \(updates.currentVersion)")
                        .font(.callout.weight(.medium))
                    Tag(text: updates.phase.text,
                        color: phaseColor)
                    Spacer(minLength: 0)
                }

                Toggle("自动检查更新", isOn: Binding(
                    get: { updates.automaticallyChecks },
                    set: { updates.automaticallyChecks = $0 }
                ))
                Toggle("安装前先询问", isOn: Binding(
                    get: { updates.asksBeforeInstalling },
                    set: { updates.asksBeforeInstalling = $0 }
                ))
                Text(updates.asksBeforeInstalling
                     ? "发现新版本时会自动下载并校验，但不会自行重启，等你确认后再安装。"
                     : "发现新版本时会自动下载、校验并直接重启完成安装。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        Task { await updates.checkForUpdates() }
                    } label: {
                        Label("立即检查", systemImage: "arrow.clockwise")
                    }
                    .disabled(updates.phase.isBusy)

                    if case .ready = updates.phase {
                        Button {
                            updates.installAndRelaunch()
                        } label: {
                            Label("立即更新并重启", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)

                        Button("稍后") { updates.discardPreparedUpdate() }
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var phaseColor: Color {
        switch updates.phase {
        case .upToDate:   return .green
        case .ready:      return .orange
        case .failed:     return .red
        case .available:  return .accentColor
        default:          return .secondary
        }
    }

    // MARK: - 助手版本

    private var helperCard: some View {
        SectionCard(
            title: "特权助手版本",
            subtitle: "助手二进制装在系统目录里，可能与应用内置的那一份不同。"
                + "判据是两份文件的内容摘要 —— 助手代码没变就不会重装。"
                + "助手已经是 root，可以自己替换自己，所以这种更新不需要再输密码。",
            symbol: "lock.shield",
            accent: helper.state.needsAttention ? .orange : .green
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("与内置助手比对")
                        .font(.callout.weight(.medium))
                    Tag(text: helper.state.needsAttention ? "需要处理" : "正常",
                        color: helper.state.needsAttention ? .orange : .green)
                    Spacer(minLength: 0)
                }

                Text(helper.state.text)
                    .font(.caption)
                    .foregroundStyle(helper.state.needsAttention ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        Task { await helper.checkAndUpdateIfNeeded() }
                    } label: {
                        Label("立即检查并更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - 机制说明

    private var mechanismCard: some View {
        SectionCard(
            title: "这些更新都校验了什么",
            subtitle: nil,
            symbol: "checklist"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                bullet("应用更新只在 Release 版本号**严格更高**时进行；"
                       + "版本号解析不了一律当作「没有更新」，绝不当作「有更新」。")
                bullet("下载的 zip 必须能解开，里面的 .app 的 bundle id 必须是 "
                       + "com.skyc8266.deepsleep，版本号要与 Release 声称的一致，"
                       + "并通过 codesign 结构校验。")
                bullet("Release 若附带 DeepSleep.zip.sha256 会比对摘要；"
                       + "不一致就放弃安装。")
                bullet("助手自我更新的校验：来源必须是应用包内的固定路径，"
                       + "那个包的 bundle id 必须是 Deep Sleep，"
                       + "内容摘要要与调用方给的一致，且不能与当前这份完全相同。")
                bullet("助手是否需要更新，看的是两份二进制的**内容摘要是否相同**，"
                       + "而不是版本号 —— 不需要任何人维护额外的数字，"
                       + "而且摘要天然收敛：替换成功后两边必然一致，不会反复重装。")
                bullet("替换自己由临时目录里的脚本完成：它先等本进程退出，"
                       + "失败会把旧版本放回去，不会留下半残状态。")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Text(.init(text))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
