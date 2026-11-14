//
//  RunState.swift
//  Deep Sleep
//
//  跨重启保留的运行状态：存什么、怎么编解码、恢复时怎么判断能不能恢复。
//
//  为什么单独一个文件：这一层是纯数据 + 纯判定，不依赖 AppKit / 助手 /
//  IOKit，能在命令行里单独跑（scripts/test-state-restore.swift）。
//
//  ## 存「用户看到的状态」，不存退出那一刻的收尾
//
//  退出流程会主动释放断言、把 disablesleep 改回 —— 那是收尾，不是用户改主意。
//  把两件事分开，重启后恢复的才是用户要的那份状态。
//
//  「用户看到的状态」指界面上那个开关当时的样子：服务器模式顺带把
//  disablesleep 打开时，界面上的「完全禁止系统睡眠」同样是亮的，所以录下来
//  并不算把副作用冒充成用户选择。退出时的那次回写则一律不记
//  （`SleepController.shutdown` 期间写入整体被 `updateRunState` 丢掉）。
//
//  ## 字段一律有默认值
//
//  解码时缺的 key 用默认值补上，而不是整份存档作废。存档格式会随版本
//  往前长，新增字段不该让老用户丢掉已有的配置。
//

import Foundation

/// 需要跨重启保留的运行状态。
struct RunState: Codable, Equatable {

    /// 风扇控制总开关。调速规则本身另有存档（`FanModeStore`），这里只记开关。
    var fanControlEnabled: Bool = false

    /// 用户手动打开的保持类型。存 rawValue 而不是枚举本体：
    /// 枚举以后加类型时，老存档里不认识的 rawValue 不该让整份存档作废。
    var manualAssertions: [String] = []

    /// 「完全禁止系统睡眠」的开关状态（`pmset disablesleep`）。
    var sleepDisabled: Bool = false

    /// 「保持到某个时刻」的到期时间。过期即失效。
    var holdUntil: Date? = nil

    /// 服务器模式是否开启。
    var serverModeEnabled: Bool = false

    // MARK: - 编解码

    private enum CodingKeys: String, CodingKey {
        case fanControlEnabled
        case manualAssertions
        case sleepDisabled
        case holdUntil
        case serverModeEnabled
    }

    /// 解码：缺的 key 用默认值补齐。
    ///
    /// 不用合成的 `init(from:)` —— 合成版本要求每个 key 都在，
    /// 老存档少一个字段就整份作废。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fanControlEnabled = try container.decodeIfPresent(Bool.self, forKey: .fanControlEnabled) ?? false
        manualAssertions = try container.decodeIfPresent([String].self, forKey: .manualAssertions) ?? []
        sleepDisabled = try container.decodeIfPresent(Bool.self, forKey: .sleepDisabled) ?? false
        holdUntil = try container.decodeIfPresent(Date.self, forKey: .holdUntil)
        serverModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .serverModeEnabled) ?? false
    }

    init() {}

    /// 丢掉不认识的保持类型。
    ///
    /// 老版本留下的 rawValue 在当前版本里没有对应类型 —— 保留它没有意义，
    /// 但也不能因此让整份存档作废。
    func retainingKnownAssertions(_ known: Set<String>) -> RunState {
        var copy = self
        copy.manualAssertions = manualAssertions.filter { known.contains($0) }
        return copy
    }

    /// 存档是否等于「什么都没设」。
    ///
    /// 用它决定要不要落盘：没改过任何东西就别写 UserDefaults，
    /// 免得每次启动都往磁盘里塞一份默认值的副本。
    var isEmpty: Bool {
        self == RunState()
    }
}

/// 运行状态的落盘与读回。
enum RunStateStore {

    /// 存档键。带版本号：格式变了就换键，不做原地迁移。
    static let storageKey = "runState.v1"

    /// 存档落在哪个 UserDefaults。
    ///
    /// 默认是 `.standard`（App 真实在用的偏好域）。留这个口子是为了测试：
    /// `runState.v1` 是真实键名，测试拿 `.standard` 去写就会把用户自己的
    /// 运行状态改掉。测试注入自己的 suite，两边互不干扰。
    /// 跟 `MonitorConfig` 用同一个环境变量约定。
    private static let defaultsOverride: UserDefaults? = {
        if let suite = ProcessInfo.processInfo.environment["DEEPSLEEP_RUNSTATE_SUITE"],
           !suite.isEmpty,
           let suiteDefaults = UserDefaults(suiteName: suite) {
            return suiteDefaults
        }
        return nil
    }()

    /// 实际使用的 UserDefaults。
    static var storage: UserDefaults { defaultsOverride ?? .standard }

    /// 读回存档。没有存档或内容损坏时返回 nil（= 没有可恢复的状态）。
    static func load() -> RunState? {
        guard let data = storage.data(forKey: storageKey) else { return nil }
        do {
            return try JSONDecoder().decode(RunState.self, from: data)
        } catch {
            NSLog("[DeepSleep] 运行状态读取失败，已忽略：\(error.localizedDescription)")
            return nil
        }
    }

    /// 写存档。空状态不写（不留空壳）。
    static func save(_ state: RunState) {
        guard !state.isEmpty else {
            storage.removeObject(forKey: storageKey)
            return
        }
        let encoder = JSONEncoder()
        // 固定键序：同一个值多次编码能产出好几种字节，便于排查「到底存了什么」。
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else {
            NSLog("[DeepSleep] 运行状态编码失败，本次改动未落盘")
            return
        }
        storage.set(data, forKey: storageKey)
    }

    /// 读 → 改 → 写。
    ///
    /// 几个控制器各管各的字段（风扇管风扇、保持管保持），但存在同一份
    /// 存档里。走这个入口就不会互相覆盖。
    static func update(_ body: (inout RunState) -> Void) {
        var state = load() ?? RunState()
        body(&state)
        save(state)
    }

    /// 清空存档。
    static func clear() {
        storage.removeObject(forKey: storageKey)
    }
}

/// 一次状态变更的来源。
///
/// 需要区分它，是因为几件事的收尾方式各不一样：
///   - 用户操作：写存档、必要时弹授权确认；
///   - 启动恢复：存档本来就是「要这个」，不写、不弹（用户不在键盘前）；
///   - 退出收尾：把系统状态还原成干净的样子，但**不动存档** ——
///     退出不是用户改主意，下次启动还要恢复它；
///   - 别处顺带改的：服务器模式会顺手把 disablesleep 打开，那是它的副作用，
///     不能反过来记成「用户按了完全禁止系统睡眠」。仍要弹确认（用户刚点了
///     一个提权动作），但不写存档。
enum StateChangeSource {
    case user
    case restore
    case shutdown
    case derived

    /// 要不要写跨重启存档。
    var writesArchive: Bool { self == .user }

    /// 要不要弹提权确认。
    var requiresPrompt: Bool { self == .user || self == .derived }
}

// MARK: - 恢复判据

/// 恢复的前提条件。
struct RestoreEnvironment: Equatable {

    /// 特权助手是否就绪。断言、disablesleep、风扇、服务器模式都要它。
    var helperReady: Bool = false

    /// 风扇控制的免责声明是否已同意。
    var disclaimerAccepted: Bool = false

    /// 服务器模式当前用的空闲检测方式是否需要辅助功能授权。
    /// 需要而没授权时不能悄悄换一种 —— 用户选了哪个模式就该跑哪个模式。
    var serverModeNeedsAccessibility: Bool = false

    /// 「辅助功能」授权是否已有。
    var accessibilityAuthorized: Bool = false

    /// 当前版本认识的保持类型（rawValue）。
    var knownAssertions: Set<String> = []

    /// 需要助手才能拿到的保持类型（rawValue）。
    var privilegedAssertions: Set<String> = []
}

/// 恢复不了的原因。每一项都要能对用户说清楚。
enum RestoreSkipReason: Equatable {

    /// 需要特权助手，助手还没就绪。
    case helperUnavailable

    /// 风扇控制的免责声明没同意。
    case disclaimerNotAccepted

    /// 目标应用当前没有在运行。
    case appNotRunning

    /// 存档里的类型当前版本不认识。
    case unknownType

    /// 定时保持已经到期。
    case holdExpired

    /// 服务器模式要用的空闲检测方式缺授权。
    case accessibilityNotAuthorized

    /// 面向用户的一句话说明。
    var explanation: String {
        switch self {
        case .helperUnavailable:          return "需要先启用完全控制"
        case .disclaimerNotAccepted:      return "未同意风扇控制免责声明"
        case .appNotRunning:              return "目标应用当前没有在运行"
        case .unknownType:                return "当前版本不认识这个保持类型"
        case .holdExpired:                return "定时的保持已经到期"
        case .accessibilityNotAuthorized: return "缺少辅助功能授权"
        }
    }
}

/// 一项恢复动作的结论。
enum RestoreAction: Equatable {

    /// 可以恢复。
    case restore

    /// 恢复不了，跳过并说明原因。
    case skip(RestoreSkipReason)
}

/// 要恢复的一项。
enum RestoreItem: Equatable {

    /// 风扇控制总开关。
    case fanControl

    /// 某一项保持（rawValue）。
    case assertion(String)

    /// 「完全禁止系统睡眠」。
    case sleepDisabled

    /// 服务器模式。
    case serverMode

    /// 「保持到某个时刻」的约定。
    case holdDeadline

    /// 面向用户的一句话说明。
    var description: String {
        switch self {
        case .fanControl:         return "风扇控制"
        case .assertion(let raw): return "保持「\(raw)」"
        case .sleepDisabled:      return "完全禁止系统睡眠"
        case .serverMode:         return "服务器模式"
        case .holdDeadline:       return "定时保持"
        }
    }
}

/// 一项恢复动作及其结论。
struct RestoreEntry: Equatable {

    let item: RestoreItem
    let action: RestoreAction
}

extension RunState {

    /// 算出这份存档在当前环境里能恢复什么、什么要跳过。
    ///
    /// 判据写在纯函数里，才能离线验证 —— 恢复失败在真机上表现为
    /// 「重启后保持没回来」，这种问题在开发机上根本复现不了。
    ///
    /// - Parameter now: 判断定时保持是否过期用的「现在」。
    func restoreEntries(environment: RestoreEnvironment,
                        now: Date = Date()) -> [RestoreEntry] {
        var entries: [RestoreEntry] = []

        // 定时保持已经到期：那一批保持本该在到点时全部释放。
        // 应用当时不在，释放没发生 —— 现在补上，而不是把它们恢复成「永不释放」。
        let holdExpired = holdUntil.map { $0 <= now } ?? false

        for raw in manualAssertions {
            guard environment.knownAssertions.contains(raw) else {
                entries.append(RestoreEntry(item: .assertion(raw), action: .skip(.unknownType)))
                continue
            }
            if holdExpired {
                entries.append(RestoreEntry(item: .assertion(raw), action: .skip(.holdExpired)))
                continue
            }
            // 本地断言（不需要特权）随时能恢复；特权断言要等助手。
            if environment.privilegedAssertions.contains(raw), !environment.helperReady {
                entries.append(RestoreEntry(item: .assertion(raw), action: .skip(.helperUnavailable)))
            } else {
                entries.append(RestoreEntry(item: .assertion(raw), action: .restore))
            }
        }

        if let deadline = holdUntil {
            entries.append(RestoreEntry(item: .holdDeadline,
                                        action: deadline > now ? .restore : .skip(.holdExpired)))
        }

        if sleepDisabled {
            entries.append(RestoreEntry(item: .sleepDisabled,
                                        action: environment.helperReady ? .restore : .skip(.helperUnavailable)))
        }

        if serverModeEnabled {
            if !environment.helperReady {
                entries.append(RestoreEntry(item: .serverMode,
                                            action: .skip(.helperUnavailable)))
            } else if environment.serverModeNeedsAccessibility,
                      !environment.accessibilityAuthorized {
                entries.append(RestoreEntry(item: .serverMode,
                                            action: .skip(.accessibilityNotAuthorized)))
            } else {
                entries.append(RestoreEntry(item: .serverMode, action: .restore))
            }
        }

        if fanControlEnabled {
            if !environment.disclaimerAccepted {
                entries.append(RestoreEntry(item: .fanControl,
                                            action: .skip(.disclaimerNotAccepted)))
            } else if !environment.helperReady {
                entries.append(RestoreEntry(item: .fanControl,
                                            action: .skip(.helperUnavailable)))
            } else {
                entries.append(RestoreEntry(item: .fanControl, action: .restore))
            }
        }

        return entries
    }
}
