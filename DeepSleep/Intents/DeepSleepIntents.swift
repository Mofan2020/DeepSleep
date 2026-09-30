//
//  DeepSleepIntents.swift
//  Deep Sleep
//
//  App Intents：让 Siri、快捷指令、聚焦、控制中心能够操作 Deep Sleep。
//
//  几条必须知道的约束（都是这个框架的硬性要求，不是风格选择）：
//
//    1. **`perform()` 是非隔离的**，而 Deep Sleep 的全部状态都在 MainActor 上
//       （`SleepController`、`QuickQuitEngine`）。所以每个 intent 都过
//       `onMain { }` 这道桥，而不是给 intent 类型本身加 `@MainActor`
//       —— 后者会让协议一致性出现隔离不匹配的判断告警。
//
//    2. **`supportedModes = .background`**：`openAppWhenRun` 在 macOS 26 已废弃，
//       现在要写 `supportedModes`。后台模式下 intent 不会把窗口拽到前台 ——
//       Siri 说「保持清醒」时弹出一个窗口是打扰，不是功能。
//       应用不在运行时系统会把 Deep Sleep 作为后台进程拉起，
//       状态因此有地方落脚（这也是状态必须留在应用进程里的原因）。
//
//    3. **每个 intent 都先 `ensureReady()`**：系统拉起应用与 intent 开始执行
//       之间没有先后保证，不等启动流程跑完就动手，会读到
//       「助手未就绪、断言为空」的中间状态并据此做出错误判断。
//
//    4. intent 里的每一步都复用应用内已有的方法（`hold` / `setSleepDisabled` …），
//       不另开一条捷径。因此「需要完全控制」「提权要 Touch ID 确认」
//       这些既有规则在 Siri 路径上原样生效。回报文字也照实说结果。
//

import AppIntents
import Foundation

// MARK: - MainActor 桥

/// 在 MainActor 上跑一段异步逻辑并取回结果。
/// `T` 必须是 Sendable —— 结果要跨回 intent 的隔离域。
@MainActor
func onMain<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
    await Task { @MainActor in await body() }.value
}

// MARK: - 参数类型

/// 保持清醒的方式。
enum KeepAwakeMode: String, AppEnum {
    case idleSystem
    case display
    case system
    case everything

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "保持方式"

    static var caseDisplayRepresentations: [KeepAwakeMode: DisplayRepresentation] = [
        .idleSystem: "阻止空闲睡眠",
        .display: "保持屏幕常亮",
        .system: "阻止系统睡眠（含合盖）",
        .everything: "完全禁止睡眠"
    ]

    /// 对应的 assertion 集合。`.everything` 走 `disablesleep`，不产生 assertion。
    var assertions: Set<AssertionKind> {
        switch self {
        case .idleSystem:  return [.preventIdleSystemSleep]
        case .display:     return [.preventIdleDisplaySleep]
        case .system:      return [.preventSystemSleep]
        case .everything:  return []
        }
    }
}

// MARK: - 保持清醒

struct HoldAwakeIntent: AppIntent {

    static var title: LocalizedStringResource { "保持清醒" }

    static var description: IntentDescription {
        IntentDescription("让 Mac 保持清醒，可选择保持方式与时长。")
    }

    static var supportedModes: IntentModes { .background }

    @Parameter(title: "保持方式", default: .idleSystem)
    var mode: KeepAwakeMode

    @Parameter(title: "时长（分钟，留空或 0 表示不限）")
    var minutes: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("以「\(\.$mode)」保持清醒")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let mode = self.mode
        let minutes = self.minutes

        let dialog = await onMain { () -> String in
            let controller = SleepController.shared
            await controller.ensureReady()

            if mode == .everything {
                await controller.setSleepDisabled(true)
                return controller.sleepDisabled
                    ? "已完全禁止系统睡眠，合盖也不会休眠。"
                    : "没能完全禁止睡眠：请先在 Deep Sleep 里启用完全控制。"
            }

            let duration = (minutes ?? 0) > 0 ? minutes : nil
            let result = await controller.hold(assertions: mode.assertions, minutes: duration)

            guard !result.applied.isEmpty else {
                let rejected = result.rejected.map(\.title).joined(separator: "、")
                return "没能保持清醒：\(rejected) 需要在 Deep Sleep 里启用完全控制，或本次授权被拒绝。"
            }

            let applied = result.applied.map(\.title).joined(separator: "、")
            if let duration {
                return "已保持清醒：\(applied)，\(duration) 分钟后自动释放。"
            }
            return "已保持清醒：\(applied)。"
        }
        return .result(dialog: "\(dialog)")
    }
}

// MARK: - 释放保持

struct ReleaseAwakeIntent: AppIntent {

    static var title: LocalizedStringResource { "允许睡眠" }

    static var description: IntentDescription {
        IntentDescription("释放全部保持，让 Mac 恢复正常睡眠。")
    }

    static var supportedModes: IntentModes { .background }

    static var parameterSummary: some ParameterSummary {
        Summary("释放 Deep Sleep 的全部保持")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog = await onMain { () -> String in
            let controller = SleepController.shared
            await controller.ensureReady()
            await controller.releaseAllAssertions()
            return controller.activeAssertions.isEmpty
                ? "已释放全部保持，Mac 可以正常睡眠了。"
                : "还有 \(controller.activeAssertions.count) 项保持未能释放，可能由自动化规则维持。"
        }
        return .result(dialog: "\(dialog)")
    }
}

// MARK: - 查询状态

struct AwakeStatusIntent: AppIntent {

    static var title: LocalizedStringResource { "查询保持状态" }

    static var description: IntentDescription {
        IntentDescription("读取当前是否在保持清醒、是否已完全禁止睡眠。")
    }

    static var supportedModes: IntentModes { .background }

    static var parameterSummary: some ParameterSummary {
        Summary("查询 Deep Sleep 的当前状态")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let pair = await onMain { () -> (spoken: String, raw: String) in
            let controller = SleepController.shared
            await controller.ensureReady()

            let raw = controller.statusSummary
            var spoken: String
            if controller.sleepDisabled {
                spoken = "系统已完全禁止睡眠，合盖也不会休眠。"
            } else if controller.activeAssertions.isEmpty {
                spoken = "现在允许正常睡眠。"
            } else {
                let titles = controller.activeAssertions
                    .sorted { $0.rawValue < $1.rawValue }
                    .map(\.title)
                    .joined(separator: "、")
                spoken = "正在保持清醒：\(titles)。"
            }
            if let deadline = controller.holdDeadline {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                spoken += "\(formatter.string(from: deadline)) 会自动释放。"
            }
            return (spoken, raw)
        }
        return .result(value: pair.raw, dialog: "\(pair.spoken)")
    }
}

// MARK: - 立即睡眠

struct SleepNowIntent: AppIntent {

    static var title: LocalizedStringResource { "立即睡眠" }

    static var description: IntentDescription {
        IntentDescription("让 Mac 立刻进入睡眠。")
    }

    static var supportedModes: IntentModes { .background }

    static var parameterSummary: some ParameterSummary {
        Summary("让 Mac 立即睡眠")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await onMain { () -> Void in
            let controller = SleepController.shared
            await controller.ensureReady()
            await controller.sleepNow()
        }
        return .result(dialog: "已请求进入睡眠。")
    }
}

// MARK: - 定时唤醒

struct ScheduleWakeIntent: AppIntent {

    static var title: LocalizedStringResource { "排定唤醒" }

    static var description: IntentDescription {
        IntentDescription("把 Mac 排定在指定时间自动唤醒，需要完全控制权限。")
    }

    static var supportedModes: IntentModes { .background }

    @Parameter(title: "唤醒时间")
    var time: Date

    static var parameterSummary: some ParameterSummary {
        Summary("在\(\.$time)唤醒")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let time = self.time
        let dialog = await onMain { () -> String in
            let controller = SleepController.shared
            await controller.ensureReady()

            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            guard time > Date() else {
                return "\(formatter.string(from: time)) 已经过去了，请给一个将来的时间。"
            }
            await controller.scheduleWake(at: time)
            return controller.scheduledWake != nil
                ? "已排定在 \(formatter.string(from: time)) 唤醒。"
                : "排定唤醒失败：需要先在 Deep Sleep 里启用完全控制。"
        }
        return .result(dialog: "\(dialog)")
    }
}

// MARK: - 取消唤醒

struct CancelScheduledWakeIntent: AppIntent {

    static var title: LocalizedStringResource { "取消定时唤醒" }

    static var description: IntentDescription {
        IntentDescription("取消已经排定的唤醒时间。")
    }

    static var supportedModes: IntentModes { .background }

    static var parameterSummary: some ParameterSummary {
        Summary("取消 Deep Sleep 排定的唤醒")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog = await onMain { () -> String in
            let controller = SleepController.shared
            await controller.ensureReady()
            guard controller.scheduledWake != nil else {
                return "当前没有排定任何唤醒。"
            }
            await controller.cancelScheduledWake()
            return controller.scheduledWake == nil
                ? "已取消排定的唤醒。"
                : "取消失败：需要先在 Deep Sleep 里启用完全控制。"
        }
        return .result(dialog: "\(dialog)")
    }
}

// MARK: - 完全禁止睡眠

struct SetSleepDisabledIntent: AppIntent {

    static var title: LocalizedStringResource { "完全禁止睡眠" }

    static var description: IntentDescription {
        IntentDescription("完全禁止系统睡眠（合盖也不休眠），需要完全控制权限。")
    }

    static var supportedModes: IntentModes { .background }

    @Parameter(title: "禁止睡眠")
    var enabled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("把完全禁止睡眠设为\(\.$enabled)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let enabled = self.enabled
        let dialog = await onMain { () -> String in
            let controller = SleepController.shared
            await controller.ensureReady()
            await controller.setSleepDisabled(enabled)
            guard controller.sleepDisabled == enabled else {
                return enabled
                    ? "没能完全禁止睡眠：请先在 Deep Sleep 里启用完全控制，或本次授权被拒绝。"
                    : "没能恢复系统睡眠设置。"
            }
            return enabled ? "已完全禁止系统睡眠。" : "已恢复系统正常睡眠。"
        }
        return .result(dialog: "\(dialog)")
    }
}

// MARK: - 强制退出选定的应用

struct QuickQuitAppsIntent: AppIntent {

    static var title: LocalizedStringResource { "强制退出选定的应用" }

    static var description: IntentDescription {
        IntentDescription("把 Deep Sleep「快速退出」名单里的应用连同它们的全部子进程一起结束。")
    }

    static var supportedModes: IntentModes { .background }

    @Parameter(title: "只演练（不真的退出）", default: false)
    var dryRun: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("强制退出选定的应用") {
            \.$dryRun
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dryRun = self.dryRun
        let dialog = await onMain { () -> String in
            await SleepController.shared.ensureReady()
            let engine = QuickQuitEngine.shared
            guard !engine.targets.isEmpty else {
                return "还没有选定要退出的应用。请先在 Deep Sleep 的「快速退出」页把应用加进名单。"
            }
            let outcome = await engine.run(dryRun: dryRun, trigger: "快捷指令")
            if outcome.details.isEmpty { return "没有需要结束的进程。" }
            return (dryRun ? "演练：" : "已完成：") + outcome.summary
        }
        return .result(dialog: "\(dialog)")
    }
}
