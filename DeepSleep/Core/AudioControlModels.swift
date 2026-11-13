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
/// 同一 bundleID 的多个进程（如浏览器渲染进程）合并成一行。
struct AudioControlledApp: Identifiable, Equatable, Hashable {
    let id: String            // bundleID；没有时用 "pid:<pid>"
    let displayName: String
    let bundleID: String?
    let processIDs: [pid_t]
    let audioObjectIDs: [AudioObjectID]
    var isProducingAudio: Bool
    var volume: Double        // 0...1，存时已 clamp

    /// 进程名回退：无 bundleID 时用 pid
    var fallbackName: String {
        bundleID ?? "进程 \(processIDs.first ?? -1)"
    }

    /// 供 UI 显示的唯一标识（同一 bundleID 的多进程已合并）
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

    /// 将同一 bundleID 的多进程合并成一行。
    /// 输入：进程对象级别的原始数据。
    /// 输出：按 bundleID 分组、合并的应用行。
    static func mergeByBundleID(_ processes: [(objectID: AudioObjectID, pid: pid_t, bundleID: String?, isProducing: Bool)]) -> [AudioControlledApp] {
        var groups: [String: (objects: [AudioObjectID], pids: [pid_t], producing: Bool)] = [:]
        for p in processes {
            let key = p.bundleID ?? "pid:\(p.pid)"
            var g = groups[key] ?? ([], [], false)
            g.objects.append(p.objectID)
            g.pids.append(p.pid)
            g.producing = g.producing || p.isProducing
            groups[key] = g
        }
        return groups.map { key, g in
            let bid = key.hasPrefix("pid:") ? nil : key
            return AudioControlledApp(
                id: key,
                displayName: displayName(bundleID: bid, processIDs: g.pids),
                bundleID: bid,
                processIDs: g.pids.sorted(),
                audioObjectIDs: g.objects,
                isProducingAudio: g.producing,
                volume: maxVolume  // 默认 unity
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