//
//  UpdateView.swift
//  Deep Sleep
//
//  「更新」页：应用自身的自动更新，以及特权助手的版本与更新。
//
//  界面约定：
//    - 版本信息用 MetricTile + StatusPill：数字一眼可见，状态另有文字。
//    - 「立即检查」是次要操作；真正要点的「立即更新并重启」才用主按钮。
//    - 校验细节（edDSA 签名、摘要比对等）收进说明文字，不抢主线的注意力。
//

import SwiftUI

struct UpdateView: View {

    @ObservedObject private var updates = UpdateManager.shared
    @ObservedObject private var helper = HelperVersionManager.shared

    /// 检测到的助手差异，等待用户决定要不要更新。
    @State private var helperDifference: HelperVersionManager.State?
    @State private var showHelperDifference = false

    /// 操作结束后的回话。每一个分支都必须有话说 ——
    /// 用户点了按钮却什么都没弹，会被理解成「功能坏了」。
    @State private var helperReply: HelperReply?
    @State private var showHelperReply = false

    private struct HelperReply {
        let title: String
        let message: String
        let isError: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
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
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(spacing: DS.Space.md) {
                    MetricTile(
                        title: "当前版本",
                        value: updates.currentVersion,
                        status: "已安装",
                        tint: .primary
                    )
                    MetricTile(
                        title: "最新版本",
                        value: latestVersion,
                        status: latestVersionStatus,
                        tint: latestVersionTint
                    )
                }

                HStack(spacing: DS.Space.sm) {
                    StatusPill(text: updates.phase.text, isActive: updates.phase.isBusy, color: phaseColor)
                    Spacer(minLength: 0)
                }

                Toggle(isOn: Binding(
                    get: { updates.automaticallyChecks },
                    set: { updates.automaticallyChecks = $0 }
                )) {
                    Text("自动检查更新").font(.body.weight(.medium))
                }
                .toggleStyle(.switch)

                Toggle(isOn: Binding(
                    get: { updates.asksBeforeInstalling },
                    set: { updates.asksBeforeInstalling = $0 }
                )) {
                    Text("安装前先询问").font(.body.weight(.medium))
                }
                .toggleStyle(.switch)

                Text(updates.asksBeforeInstalling
                     ? "发现新版本时会自动下载并校验，但不会自行重启，等你确认后再安装。"
                     : "发现新版本时会自动下载、校验并直接重启完成安装。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: Binding(
                    get: { updates.skipPrereleaseUpdates },
                    set: { updates.skipPrereleaseUpdates = $0 }
                )) {
                    Text("跳过预发布版本（仅装正式版）").font(.body.weight(.medium))
                }
                .toggleStyle(.switch)

                Text(updates.skipPrereleaseUpdates
                     ? "只升级版本号严格更高且不是 Pre-release 的 Release。"
                     : "包括 Pre-release 版本（仓库当前发布习惯是标 Pre-release）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 下载进度：phase 是 downloading 时显示；其它阶段不显示。
                if case .downloading(_, let progress) = updates.phase {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text(String(format: "%.0f%%", progress * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: DS.Space.sm) {
                    // 检查是次要操作：不做主按钮样式。
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

    /// 最新可用版本。还没查过就是「—」，不拿当前版本冒充。
    private var latestVersion: String {
        switch updates.phase {
        case .upToDate(let current):   return current
        case .available(let version):  return version
        case .downloading(let version, _): return version
        case .ready(let version):      return version
        default:                       return "—"
        }
    }

    private var latestVersionStatus: String {
        switch updates.phase {
        case .upToDate:                return "已是最新"
        case .available:               return "可更新"
        case .downloading:             return "下载中"
        case .ready:                  return "已就绪"
        case .checking:                return "正在检查"
        case .failed:                 return "检查失败"
        default:                      return "尚未检查"
        }
    }

    private var latestVersionTint: Color {
        switch updates.phase {
        case .upToDate:  return DS.Tone.good
        case .available, .ready: return DS.Tone.caution
        case .failed:    return DS.Tone.critical
        case .checking, .downloading: return DS.Tone.info
        default:         return DS.Tone.idle
        }
    }

    private var phaseColor: Color {
        switch updates.phase {
        case .upToDate:   return DS.Tone.good
        case .ready:      return DS.Tone.caution
        case .failed:     return DS.Tone.critical
        case .available:  return DS.Tone.info
        default:          return DS.Tone.idle
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
            accent: helper.state.needsAttention ? DS.Tone.caution : DS.Tone.good
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(spacing: DS.Space.md) {
                    MetricTile(
                        title: "助手状态",
                        value: helperShortVersion,
                        status: helper.state.needsAttention ? "需要处理" : "正常",
                        tint: helper.state.needsAttention ? DS.Tone.caution : DS.Tone.good
                    )
                }

                HStack(spacing: DS.Space.sm) {
                    StatusPill(
                        text: helper.state.needsAttention ? "需要处理" : "正常",
                        isActive: !helper.state.needsAttention,
                        color: helper.state.needsAttention ? DS.Tone.caution : DS.Tone.good
                    )
                    Spacer(minLength: 0)
                }

                Text(helper.state.text)
                    .font(.caption)
                    .foregroundStyle(helper.state.needsAttention ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: DS.Space.sm) {
                    Button {
                        Task { await checkHelper() }
                    } label: {
                        Label(helper.isUpdating ? "正在更新…" : "立即检查并更新",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(helper.isUpdating)

                    if helper.isUpdating {
                        ProgressView().controlSize(.small)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        // 发现差异时先问一句再动手：替换的是 root 二进制，
        // 闷头替换会让用户不知道刚才发生了什么 —— 那正是这次要修的问题。
        .alert("助手版本与内置的不同", isPresented: $showHelperDifference,
               presenting: helperDifference) { _ in
            Button("现在更新") { Task { await applyHelperUpdate() } }
            Button("暂不更新", role: .cancel) { }
        } message: { difference in
            Text(differenceMessage(difference))
        }
        // 结果一律回话：成功、已是最新、需要重装、失败，各有各的说法。
        .alert(helperReply.map { $0.isError ? "⚠︎ \($0.title)" : $0.title } ?? "",
               isPresented: $showHelperReply, presenting: helperReply) { _ in
            Button("好", role: .cancel) { }
        } message: { reply in
            Text(reply.message)
        }
        // 打开这一页就先探一次：状态是上一次探测的快照，
        // 不刷新的话刚启动那几秒会显示成「未安装」。
        .task { _ = await helper.refresh() }
    }

    /// 助手的版本标识：装好的那份与内置的那份的摘要前缀。
    private var helperShortVersion: String {
        switch helper.state {
        case .upToDate(let installed):
            return HelperVersionManager.State.short(installed)
        case .outdated(let installed, let target):
            return "\(HelperVersionManager.State.short(installed)) → \(HelperVersionManager.State.short(target))"
        case .notInstalled:
            return "未安装"
        case .unreachable:
            return "无响应"
        case .needsReinstall:
            return "旧版"
        case .updateFailed:
            return "更新失败"
        }
    }

    // MARK: - 助手版本：检查与更新

    /// 先只看不动，再根据看到的结果决定下一步说什么、做什么。
    private func checkHelper() async {
        switch await helper.refresh() {
        case .outdated:
            // 有差异：交给确认对话框，用户点了才更新。
            helperDifference = helper.state
            showHelperDifference = true
        case .upToDate(let digest):
            reply(title: "已经是最新",
                  message: "已安装的助手与内置的那一份内容一致"
                      + "（摘要 \(HelperVersionManager.State.short(digest))），不需要更新。",
                  isError: false)
        case .notInstalled:
            reply(title: "尚未启用完全控制",
                  message: "没有检测到已安装的特权助手。到「完全控制」页启用之后会把它装上。",
                  isError: false)
        case .needsReinstall:
            reply(title: "需要重新授权安装一次",
                  message: "装着的助手是旧版本，不认识自动更新命令，无法就地替换。"
                      + "请到「完全控制」页先「停用并卸载」，再点「启用完全控制」——"
                      + "只需一次管理员授权。",
                  isError: true)
        case .unreachable:
            reply(title: "助手没有响应",
                  message: "助手已安装但没有回应，这属于 launchd 层面的问题，"
                      + "对它发更新命令也不会有结果。可尝试在「完全控制」页停用再启用一次。",
                  isError: true)
        case .updateFailed(let reason):
            reply(title: "上一次更新没成功", message: reason, isError: true)
        }
    }

    /// 用户确认后的真正更新。
    private func applyHelperUpdate() async {
        switch await helper.updateNow() {
        case .updated(let digest):
            reply(title: "助手已更新",
                  message: "助手已替换为内置的那一份"
                      + "（摘要 \(HelperVersionManager.State.short(digest))）并重新启动，"
                      + "原有的断言与设置会自动重建。",
                  isError: false)
        case .noChange(let digest):
            reply(title: "不需要更新",
                  message: "再确认时两边已经一致"
                      + "（摘要 \(HelperVersionManager.State.short(digest))）。",
                  isError: false)
        case .needsReinstall:
            reply(title: "需要重新授权安装一次",
                  message: "这个助手是旧版本，不认识自动更新命令。"
                      + "请到「完全控制」页先「停用并卸载」，再点「启用完全控制」。",
                  isError: true)
        case .notInstalled:
            reply(title: "尚未启用完全控制",
                  message: "没有检测到已安装的特权助手，无需更新。", isError: false)
        case .unreachable:
            reply(title: "助手没有响应",
                  message: "助手没有回应，更新没有开始。"
                      + "可尝试在「完全控制」页停用再启用一次。",
                  isError: true)
        case .failed(let reason):
            reply(title: "更新失败", message: reason, isError: true)
        }
    }

    private func reply(title: String, message: String, isError: Bool) {
        helperReply = HelperReply(title: title, message: message, isError: isError)
        showHelperReply = true
    }

    private func differenceMessage(_ state: HelperVersionManager.State) -> String {
        guard case .outdated(let installed, let target) = state else { return "" }
        return "已安装的助手摘要 \(HelperVersionManager.State.short(installed))，"
            + "应用内置的是 \(HelperVersionManager.State.short(target))。\n\n"
            + "更新由助手就地替换自己的二进制完成（它已经是 root，不需要再输密码），"
            + "替换期间它会重启一次，随后自动恢复原有的断言与设置。\n\n"
            + "通常出现在刚升级过应用、或应用与助手的版本错开的时候。"
    }

    // MARK: - 机制说明

    private var mechanismCard: some View {
        SectionCard(
            title: "这些更新都校验了什么",
            subtitle: nil,
            symbol: "checklist"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
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
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(.secondary)
                .padding(.top, DS.Space.xs)
            Text(.init(text))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
