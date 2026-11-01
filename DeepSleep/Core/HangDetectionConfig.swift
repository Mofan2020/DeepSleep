//
//  HangDetectionConfig.swift
//  Deep Sleep
//
//  未响应应用检测的配置与候选过滤规则。
//
//  纯数据 + 纯函数，不依赖 AppKit：`scripts/test-hang-config.swift`
//  只编译这一个文件就能把「白名单 / 系统进程 / 后台开关」三条规则全测一遍，
//  不用把整套 UI 与 IO 拖进来。
//

import Foundation

/// 未响应应用检测的配置。
public struct HangDetectionConfig: Codable, Equatable, Sendable {

    /// 总开关：关掉之后完全不做检测。
    public var enabled: Bool
    /// 是否检测后台应用。关掉之后只看当前前台应用。
    public var checkBackgroundApps: Bool
    /// 是否跳过系统应用（bundle 路径在 /System/ 下的）。
    public var ignoreSystemProcesses: Bool
    /// 白名单（bundle id）。命中的应用一律跳过。
    public var whitelistBundleIDs: [String]
    /// 检测间隔（秒）。
    public var detectionIntervalSeconds: Int

    /// 检测间隔的取值范围。
    ///
    /// 下限是为了别把系统问询打成轮询炸弹：每个候选都要问一次辅助功能，
    /// 间隔太短会把机器拖慢。上限是为了关掉再打开之后不用干等。
    public static let intervalRange: ClosedRange<Int> = 5...600

    public init(enabled: Bool = true,
                checkBackgroundApps: Bool = true,
                ignoreSystemProcesses: Bool = true,
                whitelistBundleIDs: [String] = [],
                detectionIntervalSeconds: Int = 15) {
        self.enabled = enabled
        self.checkBackgroundApps = checkBackgroundApps
        self.ignoreSystemProcesses = ignoreSystemProcesses
        self.whitelistBundleIDs = whitelistBundleIDs
        self.detectionIntervalSeconds = HangDetectionConfig.clampInterval(detectionIntervalSeconds)
    }

    /// 默认配置。
    public static let `default` = HangDetectionConfig()

    static func clampInterval(_ seconds: Int) -> Int {
        min(max(seconds, intervalRange.lowerBound), intervalRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case checkBackgroundApps
        case ignoreSystemProcesses
        case whitelistBundleIDs
        case detectionIntervalSeconds
    }

    /// 逐字段容错解码。
    ///
    /// 合成出来的 `init(from:)` 只要存档里缺一个键就整份解码失败，
    /// 那样用户改过的白名单会跟配置一起丢光。缺哪个键就用哪个键的默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        checkBackgroundApps = try container.decodeIfPresent(Bool.self, forKey: .checkBackgroundApps) ?? true
        ignoreSystemProcesses = try container.decodeIfPresent(Bool.self, forKey: .ignoreSystemProcesses) ?? true
        whitelistBundleIDs = try container.decodeIfPresent([String].self, forKey: .whitelistBundleIDs) ?? []
        detectionIntervalSeconds = HangDetectionConfig.clampInterval(
            try container.decodeIfPresent(Int.self, forKey: .detectionIntervalSeconds) ?? 15
        )
    }
}

// MARK: - 持久化

extension HangDetectionConfig {

    /// 存档的键名。带 `.v1` 后缀：以后改结构换 key，老存档自然作废。
    public static let storageKey = "hangDetectionConfig.v1"

    /// 存档落在哪个 UserDefaults。
    ///
    /// 默认是 `.standard`（App 真实在用的偏好域）。留这个口子是为了测试：
    /// `hangDetectionConfig.v1` 是真实键名，测试拿 `.standard` 去写就会把
    /// 用户自己的设置改掉。注入方式与 `MonitorConfig` 一致（环境变量）。
    private static let defaultsOverride: UserDefaults? = {
        if let suite = ProcessInfo.processInfo.environment["DEEPSLEEP_HANG_CONFIG_SUITE"],
           !suite.isEmpty,
           let suiteDefaults = UserDefaults(suiteName: suite) {
            return suiteDefaults
        }
        return nil
    }()

    /// 实际使用的 UserDefaults。
    static var storage: UserDefaults { defaultsOverride ?? .standard }

    /// 默认配置的 JSON 形式，用于判断「是否还是默认值」。
    ///
    /// **必须用 `.sortedKeys`**：JSONEncoder 对 struct 的键序不固定，
    /// 同一个值多次编码能产出好几种字节，比较会随机失败。
    private static let defaultJSON: Data? = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(HangDetectionConfig.default)
    }()

    /// 从 UserDefaults 读。读不到或损坏时返回默认值。
    public static func load() -> HangDetectionConfig {
        guard let data = storage.data(forKey: storageKey) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(HangDetectionConfig.self, from: data)
        } catch {
            return .default
        }
    }

    /// 写到 UserDefaults。
    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        Self.storage.set(data, forKey: Self.storageKey)
    }

    /// 写到 UserDefaults，但当它就是默认值时不写（避免无谓的磁盘改动）。
    public func saveIfNotDefault() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let mine = try? encoder.encode(self) else { return }
        if let defaultData = Self.defaultJSON, mine == defaultData {
            Self.storage.removeObject(forKey: Self.storageKey)
            return
        }
        Self.storage.set(mine, forKey: Self.storageKey)
    }
}

// MARK: - 候选筛选

/// 一个待检测的应用。
///
/// 只带值类型：检测跑在后台线程上，候选列表要能从主线程原样传过去。
public struct HangCandidate: Equatable, Sendable {
    public let pid: pid_t
    public let bundleID: String
    public let appName: String
    /// bundle 路径。判断「是不是系统应用」靠它。
    public let bundlePath: String?
    /// 当前是不是前台应用。
    public let isForeground: Bool
    /// 激活策略是不是 `.regular`。后台 agent 不是 `.regular`，一律不管。
    public let isRegularActivationPolicy: Bool

    public init(pid: pid_t,
                bundleID: String,
                appName: String,
                bundlePath: String? = nil,
                isForeground: Bool = false,
                isRegularActivationPolicy: Bool = true) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.bundlePath = bundlePath
        self.isForeground = isForeground
        self.isRegularActivationPolicy = isRegularActivationPolicy
    }
}

/// 候选筛选规则。纯函数，方便单测。
public enum HangCandidateFilter {

    /// 本应用自己与特权助手的 bundle id。
    ///
    /// 检测自己没意义；而且 Deep Sleep 自己弹窗时，它的辅助功能查询
    /// 可能被自己的模态挡住，会把自己误判成「无响应」。
    public static let ownBundleIDs: Set<String> = [
        "com.skyc8266.deepsleep",
        "com.skyc8266.deepsleep.helper",
    ]

    /// 系统应用：bundle 路径在 /System/ 下的（含 /System/Applications）。
    ///
    /// 只看路径不看 bundle id 前缀：系统自带应用的 bundle id 前缀会变
    /// （com.apple.* 之外还有别的），路径是稳定的。
    public static func isSystemApp(bundlePath: String?) -> Bool {
        guard let bundlePath, !bundlePath.isEmpty else { return false }
        if bundlePath == "/System" { return true }
        return bundlePath.hasPrefix("/System/")
    }

    /// 是否在白名单里。bundle id 大小写不敏感 —— 存的时候手抖大写不该漏判。
    public static func isWhitelisted(bundleID: String, whitelist: [String]) -> Bool {
        whitelist.contains { $0.compare(bundleID, options: .caseInsensitive) == .orderedSame }
    }

    /// 按配置过滤候选。
    ///
    /// 顺序即优先级：先排掉根本不该问的（自己、后台 agent、无 bundle id），
    /// 再排掉用户明确不想看的（系统应用、白名单），最后按「是否检测后台应用」
    /// 收窄到前台。
    public static func filter(_ candidates: [HangCandidate],
                              config: HangDetectionConfig,
                              ownBundleIDs: Set<String> = HangCandidateFilter.ownBundleIDs) -> [HangCandidate] {
        candidates.filter { candidate in
            guard candidate.isRegularActivationPolicy else { return false }
            guard !candidate.bundleID.isEmpty else { return false }
            guard !ownBundleIDs.contains(candidate.bundleID) else { return false }
            if config.ignoreSystemProcesses,
               isSystemApp(bundlePath: candidate.bundlePath) {
                return false
            }
            if isWhitelisted(bundleID: candidate.bundleID, whitelist: config.whitelistBundleIDs) {
                return false
            }
            if !config.checkBackgroundApps, !candidate.isForeground {
                return false
            }
            return true
        }
    }
}
