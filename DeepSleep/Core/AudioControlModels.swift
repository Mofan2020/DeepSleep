//
//  AudioControlModels.swift
//  Deep Sleep
//
//  音频控制的纯逻辑层：无 CoreAudio 依赖、无副作用、可完整单元测试。
//  设计目标：
//  - 逐应用音量范围 0...1（衰减 only，不放大，消除削波风险）
//  - 同一 Bundle ID 的多进程合并为一行
//  - 所有数学/格式化/持久化键在此处集中，不散落到别处
//

import Foundation

/// 一个「能单独调音量」的应用聚合行。
///
/// **一个 app 的多个进程可能分成好几行。** 比如 WebView 的 GPU 进程：
/// 它跟主进程同一个 bundleID，但它是另一个进程，出声的是它。合成一行
/// 就看不出「谁在响」，调节的时候也不知道调的是谁。
///
/// 所以分组键是 **bundleID + 进程名**：同一个 app 里进程名相同的合成一行
/// （浏览器的多个同类型标签页），进程名不同的分开列。
struct AudioControlledApp: Identifiable, Equatable, Hashable {
    /// UI 里的唯一标识。同一 bundleID 下的不同进程名是不同的行。
    let id: String
    /// 显示名：`App Name`，或者 `App Name/进程名`（子进程）。
    let displayName: String
    let bundleID: String?
    let processIDs: [pid_t]
    let audioObjectIDs: [AudioObjectID]
    var isProducingAudio: Bool
    var volume: Double        // 0...1，存时已 clamp
    /// 这一行的进程名（可执行文件名，如 "GPU"）。
    let processName: String?

    /// 显式写出来是因为成员初始化器不会把带默认值的参数暴露成可传参数，
    /// 而 `processName` 是后来加的（原来按 bundleID 合并成一行，不需要
    /// 区分进程）。
    init(id: String,
         displayName: String,
         bundleID: String?,
         processIDs: [pid_t],
         audioObjectIDs: [AudioObjectID],
         isProducingAudio: Bool,
         volume: Double,
         processName: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.bundleID = bundleID
        self.processIDs = processIDs
        self.audioObjectIDs = audioObjectIDs
        self.isProducingAudio = isProducingAudio
        self.volume = volume
        self.processName = processName
    }

    /// 进程名回退：无 bundleID 时用 pid
    var fallbackName: String {
        bundleID ?? "进程 \(processIDs.first ?? -1)"
    }

    /// 存储用的键。**只用 bundleID**：同一个 app 的所有进程共享一份音量
    /// 设置，用户拖一次滑块就该整个 app 都变。
    var uniqueKey: String {
        bundleID ?? "pid:\(processIDs.sorted().map(String.init).joined(separator: ","))"
    }
}

/// 纯函数集中地：不持有状态、不调用任何副作用 API。
enum AudioControlSupport {

    /// 音量范围上限：1.0 = unity（原声），不允许 >1 以免削波、避免需限制器。
    static let maxVolume: Double = 1.0
    /// 滑块 UI 的步进
    static let volumeStep: Double = 0.01

    /// 将任意值 clamp 到 [0, maxVolume]
    static func clampVolume(_ v: Double) -> Double {
        min(max(v, 0), maxVolume)
    }

    /// 音量 → 线性增益（供 IOProc 用）。
    /// 这里用平方曲线：感知音量 ≈ 幅度平方。
    /// 0 → 0, 0.5 → 0.25, 1.0 → 1.0。
    static func gain(for volume: Double) -> Float {
        let v = clampVolume(volume)
        return Float(v * v)
    }

    /// 线性增益 → 音量（供读回显示用）。
    static func volume(from gain: Float) -> Double {
        let g = max(0, min(1, gain))
        return Double(sqrt(g))
    }

    /// 格式化成「xx%」字符串（滑块右侧标签）
    static func formatPercent(_ volume: Double) -> String {
        "\(Int(round(clampVolume(volume) * 100)))%"
    }

    /// 根据 bundleID 与进程列表推导显示名。
    /// - 有 bundleID：用 bundleID 的最后一段（如 "com.apple.Safari" → "Safari"）
    /// - 无 bundleID：用 "进程 <pid>"
    static func displayName(bundleID: String?, processIDs: [pid_t]) -> String {
        if let bid = bundleID, !bid.isEmpty {
            return bid.split(separator: ".").last.map(String.init) ?? bid
        }
        return "进程 \(processIDs.first ?? -1)"
    }

    /// 一行的显示名。
    ///
    /// **格式：`App Name`，子进程用 `App Name/进程名`。**
    ///
    /// - 进程名跟 app 名一样（主进程）→ 只显示 app 名
    /// - 进程名不一样（WebView 的 "GPU"）→ `App Name/GPU`
    ///
    /// 为什么非要带上进程名：CoreAudio 只报得出 bundleID，WebView 的
    /// GPU 进程跟主进程是同一个 bundleID，光看 app 名用户根本不知道
    /// 响的是哪个进程。
    static func displayName(appName: String, processName: String?) -> String {
        guard let processName, !processName.isEmpty else { return appName }
        if processName.caseInsensitiveCompare(appName) == .orderedSame {
            return appName
        }
        // 进程名里已经带了 app 名（可执行文件名常常是 "SkycMedia"，helper
        // 进程是 "SkycMedia Helper"），那就不用再写一遍。
        if processName.lowercased().contains(appName.lowercased())
            || appName.lowercased().contains(processName.lowercased()) {
            return appName
        }
        return "\(appName)/\(processName)"
    }

    /// 本应用自己的 bundle id。**自己的音频不归自己管。**
    ///
    /// 理由很实在：DeepSleep 自己在跑音频引擎（IOProc、聚合设备），
    /// 它自己的进程也在那个音频图里。要是把它列出来，用户拖一下滑块
    /// 就把自己的声音调没了；更要命的是别的应用（播放器）接的是
    /// 聚合设备，DeepSleep 一调就把它们的音量也带下去。
    static let selfBundleIDs: Set<String> = [
        "com.skyc8266.deepsleep",
        "com.skyc8266.deepsleep.helper",
    ]

    /// 这个 bundle id 是不是自己的。
    static func isSelfBundleID(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return selfBundleIDs.contains(bundleID)
    }

    /// 命令行里给的名字能不能指到这一行。
    ///
    /// 认三种写法：
    /// - bundleID（`com.skyc8266.skycmedia`）
    /// - 完整显示名（`SkycMedia/GPU`）
    /// - 只写 app 名（`SkycMedia`）—— 这一行的 app 名部分一样就算，
    ///   否则用户想调 GPU 进程却得先记住带斜杠的写法。
    static func matches(target: String, app: AudioControlledApp) -> Bool {
        let wanted = target.lowercased()
        if let bid = app.bundleID, bid.lowercased() == wanted { return true }
        if app.displayName.lowercased() == wanted { return true }
        // app 名部分：显示名是 "App Name/进程名"，取斜杠前面那段。
        let appName = app.displayName
            .components(separatedBy: "/")
            .first?
            .lowercased() ?? ""
        return !appName.isEmpty && appName == wanted
    }

    /// 将同一 bundleID 的多进程合并成一行。
    /// 输入：进程对象级别的原始数据。
    /// 输出：按 bundleID + 进程名分组、合并的应用行。
    ///
    /// **分组键是 bundleID + 进程名。** 同一 app 里进程名不同的分开列
    /// （WebView 的主进程和 GPU 进程），名字相同的合成一行。
    ///
    /// - Parameter appNames: bundleID → 应用显示名。查不到就用 bundleID
    ///   的最后一段兜底（那玩意儿是小写的，"com.skyc8266.skycmedia" 会变成
    ///   "skymedia"，不是用户眼里那个 "SkycMedia"）。
    static func mergeByBundleID(_ processes: [(objectID: AudioObjectID, pid: pid_t, bundleID: String?, processName: String?, isProducing: Bool)],
                                 appNames: [String: String] = [:]) -> [AudioControlledApp] {
        var groups: [String: (objects: [AudioObjectID], pids: [pid_t], producing: Bool, bundleID: String?, processName: String?)] = [:]
        for p in processes {
            // 自己的进程不进列表。
            if isSelfBundleID(p.bundleID) { continue }
            let key = p.bundleID.map { "\($0)\u{1}\(p.processName ?? "")" }
                ?? "pid:\(p.pid)"
            var g = groups[key] ?? ([], [], false, p.bundleID, p.processName)
            g.objects.append(p.objectID)
            g.pids.append(p.pid)
            g.producing = g.producing || p.isProducing
            groups[key] = g
        }
        return groups.map { key, g in
            let bid = g.bundleID
            let appName = bid.flatMap { appNames[$0] }
                ?? displayName(bundleID: bid, processIDs: g.pids)
            return AudioControlledApp(
                id: key,
                displayName: displayName(appName: appName, processName: g.processName),
                bundleID: bid,
                processIDs: g.pids.sorted(),
                audioObjectIDs: g.objects,
                isProducingAudio: g.producing,
                volume: maxVolume,  // 默认 unity
                processName: g.processName
            )
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// UserDefaults suite name（与 App 配置隔离，避免污染主配置）
    static let storageSuite = "com.skyc8266.deepsleep.audio.v1"
    /// 存 key：volume:<uniqueKey>
    static func volumeKey(for app: AudioControlledApp) -> String {
        "volume:\(app.uniqueKey)"
    }
    /// 存 key：enabled（功能总开关）
    static let enabledKey = "enabled"
    /// 存 key：menuBar（是否在菜单栏占一个位置，默认关）
    static let menuBarEnabledKey = "menuBar"

    /// 从存储读回音量；**键不存在时返回 unity**（1.0）。
    ///
    /// 为什么不是 0：`UserDefaults.double(forKey:)` 对缺失键返回 0，
    /// 直接透传会把「从没设置过」误判成「静音」—— 用户的应用会突然没声音。
    /// 这里用 `object(forKey:)` 区分「没设过」与「设成了 0」。
    static func storedVolume(for app: AudioControlledApp, defaults: UserDefaults) -> Double {
        let key = volumeKey(for: app)
        guard defaults.object(forKey: key) != nil else { return maxVolume }
        return defaults.double(forKey: key)
    }

    /// 存档里全是这种前缀的键：`volume:<uniqueKey>`。
    static let volumeKeyPrefix = "volume:"

    /// 一次「把存档音量套回应用」的结果。
    ///
    /// 分开两条是有意义的：套上的可以就此不管，没套上的要等目标应用
    /// 重新出现 —— 那是「暂时还没恢复」，不是「恢复失败」。
    struct VolumeRestorePlan: Equatable {
        /// 目标应用正在运行，音量已经套上。
        var applied: [String] = []
        /// 目标应用当前没在运行，音量留到它出现时再生效。
        var pending: [String] = []
    }

    /// 算出这次能套上哪些、哪些还得等。
    ///
    /// - Parameters:
    ///   - storedKeys: 存档里的键（`volume:<uniqueKey>`）。
    ///   - liveKeys: 当前发现的应用 uniqueKey。
    static func volumeRestorePlan(storedKeys: [String], liveKeys: Set<String>) -> VolumeRestorePlan {
        var plan = VolumeRestorePlan()
        for key in storedKeys where key.hasPrefix(volumeKeyPrefix) {
            let target = String(key.dropFirst(volumeKeyPrefix.count))
            guard !target.isEmpty else { continue }
            if liveKeys.contains(target) {
                plan.applied.append(target)
            } else {
                plan.pending.append(target)
            }
        }
        plan.applied.sort()
        plan.pending.sort()
        return plan
    }

    /// 判断是否需要为该 app 建立引擎（音量 != unity）。
    static func needsEngine(volume: Double, isProducing: Bool) -> Bool {
        let v = clampVolume(volume)
        return v < maxVolume - 0.0001 && isProducing
    }

    // MARK: - 重建判据

    /// 已有引擎是否需要重建。
    ///
    /// 设备换了必须重建：聚合设备的主 sub-device 是启动时那个物理设备，
    /// 换了输出设备之后它还指着旧的，tap 抓到的会是空流。
    /// 进程 object 变了则**只有按 pid 建 tap 的 app 才需要重建** —— 有
    /// bundleID 的 tap 由 `processRestoreEnabled` 自己跟，重建反而会
    /// 让用户已经调好的声音断一下。
    static func engineNeedsRebuild(objects: [AudioObjectID],
                                   deviceUID: String,
                                   currentBundleID: String?,
                                   currentObjects: [AudioObjectID],
                                   currentDeviceUID: String) -> Bool {
        if deviceUID != currentDeviceUID { return true }
        if currentBundleID == nil && objects != currentObjects { return true }
        return false
    }

    // MARK: - IO 功耗策略

    /// 目标安静了这么多轮刷新（约 16 秒）之后才停 IOProc。
    /// 不定成 1 轮：通知音、短提示音这类间歇出声的 app 会被反复停/启，
    /// 每次启停都有一次可听的断点。
    static let ioIdleRefreshLimit = 8

    /// 是否应该停掉 IOProc（保留 tap 与聚合设备，随时可再启动）。
    static func ioShouldStop(volume: Double, isProducing: Bool, idleRefreshes: Int) -> Bool {
        if isProducing { return false }
        if clampVolume(volume) >= maxVolume - 0.0001 { return true }
        return idleRefreshes >= ioIdleRefreshLimit
    }

    // MARK: - 菜单栏

    /// 菜单栏里要列出的 app：只列此刻真的在出声的。
    /// 列表按显示名排序，和主界面一致的顺序。
    static func menuBarApps(_ apps: [AudioControlledApp]) -> [AudioControlledApp] {
        apps.filter { $0.isProducingAudio }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

// MARK: - 授权与探活

/// 「系统音频录制」授权的已知状态。
///
/// 没有 API 能读这个授权：没授权时 tap 建得起来、聚合设备建得起来、
/// IOProc 正常回调，只是数据全零。所以状态只能靠峰值反推。
enum AudioTapPermission: String, Equatable, Sendable {
    /// 还没测出来（没建过引擎，或窗口还没跑满）
    case unknown
    /// 峰值有数据，链路通
    case granted
    /// 目标在出声但 tap 一路全零
    case denied

    var isDenied: Bool { self == .denied }
}

/// 一次探活窗口的结论。
enum AudioTapVerdict: Equatable {
    /// 有峰值，或目标本来就没在出声 —— 无事可做
    case healthy
    /// 全零 / 没拿到数据，但还值得重建一次再看
    case rebuild
    /// 拿到了数据但全零，且已经重建过 —— 只能是没有授权
    case permissionDenied
    /// 连 tap 数据都没拿到，且已经重建过 —— 链路本身坏了，跟授权无关
    case chainUnavailable
}

/// 探活判据。集中在这里是为了能在没有声卡的情况下被测试。
enum AudioTapHealthPolicy {

    /// 峰值低于这个值就当静音。float 采样里 -90dB 以下已经是噪声底。
    static let silenceThreshold: Float = 1e-5

    /// 允许重建几次。一次就够：如果只是 tap 绑错了对象，重建能修好；
    /// 重建也全零就只能是权限，再重建只是让用户听更多次断音。
    static let maxRebuildAttempts = 1

    /// - Parameters:
    ///   - peak: 这个窗口里 tap 输入的峰值
    ///   - isProducing: 目标 app 的 `'piro'`（isRunningOutput）
    ///   - rebuildAttempts: 这个 app 已经重建过几次
    ///   - receivedWindows: 这个窗口里真的有 tap 数据的周期数
    ///
    /// 「没有数据」和「有数据但全零」必须分开：前者是链路坏了，
    /// 后者才指向没授权。混为一谈会把设备切换失败报成「去授权」。
    static func verdict(peak: Float,
                        isProducing: Bool,
                        rebuildAttempts: Int,
                        receivedWindows: UInt64 = 1) -> AudioTapVerdict {
        if !isProducing { return .healthy }
        let gotData = receivedWindows > 0
        if gotData, peak > silenceThreshold { return .healthy }
        if rebuildAttempts < maxRebuildAttempts { return .rebuild }
        return gotData ? .permissionDenied : .chainUnavailable
    }
}

// AudioObjectID 从 CoreAudio 引入，保持类型安全
import CoreAudio
typealias AudioObjectID = CoreAudio.AudioObjectID