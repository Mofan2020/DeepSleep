//
//  AudioControlManager.swift
//  Deep Sleep
//
//  音频控制管理器：
//  - 发现正在输出音频的进程（每 2 秒刷新）
//  - 按 bundleID 合并同一 app 的多进程
//  - 为需要调音量的 app 创建/销毁引擎
//  - 持久化开关与音量
//  - 音频链路的异常自愈：coreaudiod 重启、设备切换、设备拔出、授权被撤销
//
//  两条贯穿全文件的约定：
//  1. 所有 tap / 聚合设备的重建都走同一个串行队列 —— 两个聚合设备同时挂
//     在同一个物理设备上会把 coreaudiod 的 HAL 状态搞坏。
//  2. 状态只在主线程上改，队列里只放 CoreAudio 的建与拆。
//

import Foundation
import CoreAudio
import AppKit
import Combine
import os.log

private let log = OSLog(subsystem: "com.skyc8266.deepsleep", category: "AudioControlManager")

@MainActor
final class AudioControlManager: ObservableObject {

    // MARK: - 单例

    static let shared = AudioControlManager()

    // MARK: - 公开状态

    /// 当前可控制的应用列表（已按 bundleID 合并、按名称排序）。
    @Published private(set) var controlledApps: [AudioControlledApp] = []

    /// 功能总开关（默认关）。赋值即生效：写盘、起停引擎。
    @Published var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: AudioControlSupport.enabledKey)
            if isEnabled {
                start()
            } else {
                shutdown(reason: "用户关闭")
            }
        }
    }

    /// 是否在菜单栏占一个位置（默认关）。
    @Published private(set) var isMenuBarEnabled: Bool = false

    /// 「系统音频录制」授权状态。没有 API 能读，只能靠峰值反推。
    @Published private(set) var permission: AudioTapPermission = .unknown

    /// 最近一次错误（供 UI 展示）。
    @Published private(set) var lastError: String?

    // MARK: - 内部状态

    /// key = app.uniqueKey
    private(set) var engines: [String: AudioControlEngine] = [:]
    /// 每个 app 已经因「全零峰值」重建过几次。
    private var rebuildAttempts: [String: Int] = [:]
    /// 每个 app 连续多少轮刷新没在出声（用来决定什么时候停 IOProc）。
    private var idleRefreshes: [String: Int] = [:]
    /// 链路确认不可用的 app：暂时不再建引擎，等它下次开始出声或用户改音量再试。
    private var blockedKeys: Set<String> = []

    private var refreshTimer: Timer?
    private var healthTimer: Timer?
    private var permissionProbeTask: Task<Void, Never>?
    private var isRefreshing = false
    private var quickRefreshPending = false
    private var rebuildScheduled = false
    private var watcher: CoreAudioWatcher?

    /// 串行重建队列。CoreAudio 的建/拆只在这里跑。
    private let rebuildQueue = DispatchQueue(label: "com.skyc8266.deepsleep.audio.rebuild")

    private let defaults = UserDefaults(suiteName: AudioControlSupport.storageSuite)!

    // MARK: - 生命周期

    private init() {
        isEnabled = defaults.bool(forKey: AudioControlSupport.enabledKey)
        isMenuBarEnabled = defaults.bool(forKey: AudioControlSupport.menuBarEnabledKey)
        // 上次退出时是开着的，这次得自己接上：不接的话用户以为功能还在，
        // 实际上一个引擎都没跑，调音量毫无反应。
        if isEnabled {
            start()
        }
    }

    // 单例存活整个应用生命周期。显式关闭走 setEnabled(false) 或 shutdownForAppExit()。

    // MARK: - 公开控制

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func setMenuBarEnabled(_ enabled: Bool) {
        guard enabled != isMenuBarEnabled else { return }
        isMenuBarEnabled = enabled
        defaults.set(enabled, forKey: AudioControlSupport.menuBarEnabledKey)
        // 菜单栏开关打开时功能必须跟着开：否则菜单里没有任何可调的东西。
        if enabled {
            setEnabled(true)
        }
    }

    /// 设置某 app 的音量（0...1）。
    func setVolume(_ volume: Double, for app: AudioControlledApp) {
        let clamped = AudioControlSupport.clampVolume(volume)
        let gain = AudioControlSupport.gain(for: clamped)
        let key = app.uniqueKey

        saveVolume(clamped, for: app)
        updateAppVolume(key, clamped)
        // 用户亲手动过这个 app，就再给链路一次机会。
        blockedKeys.remove(key)
        rebuildAttempts[key] = nil

        if let engine = engines[key] {
            engine.gain = gain
            return
        }

        // 还没有引擎：把音量从 100% 往下拖的那一刻就建起来，
        // 不然要等下一轮刷新才有反应，滑块像是坏的。
        guard isEnabled, !permission.isDenied, app.isProducingAudio,
              clamped < AudioControlSupport.maxVolume - 0.0001,
              let deviceUID = currentOutputDeviceUID() else { return }
        if let engine = makeEngine(for: app, deviceUID: deviceUID, gain: gain) {
            engines[key] = engine
        }
    }

    /// 切换某 app 静音（音量 0 <-> 1）。按 key 取当下值，避免用到过期快照。
    func toggleMute(forKey key: String) {
        guard let app = controlledApps.first(where: { $0.uniqueKey == key }) else { return }
        setVolume(app.volume > 0.001 ? 0 : 1, for: app)
    }

    /// 手动触发一次刷新（UI「刷新」按钮、CLI）。
    func refreshNow() {
        performRefresh()
    }

    /// 打开「系统音频录制」的授权页。
    ///
    /// 这个面板没有公开的常量可用，锚点跟系统版本有关，所以按
    /// 新版 → 旧版 → 隐私总览的顺序试，第一个打开成功的就停。
    func openPermissionSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    /// 应用退出前拆掉所有引擎。
    ///
    /// **必须做**：被 tap 的进程是「muted when tapped」—— tap 存在期间它
    /// 的声音走不到硬件，音频由我们的聚合设备重渲染。进程一死，
    /// tap 与聚合设备随之消失，被 tap 的应用会**一直哑掉**直到
    /// coreaudiod 清掉残留。所以退出路径上必须显式 stop。
    ///
    /// 幂等：stop 与 teardown 都可重复调用。
    func shutdownForAppExit() {
        os_log(.info, log: log, "app exit: tearing down audio engines")
        shutdown(reason: "app exit")
    }

    // MARK: - 跨重启恢复

    /// 把上次的音量状态讲清楚：谁已经套上了、谁还在等应用回来。
    ///
    /// 音量本身的持久化不需要新存档 —— `performRefresh` 每轮都会用
    /// `storedVolume(for:)` 把存档值套到发现的应用上。这里只补一句
    /// 用户能看懂的话，让「没恢复」不是静默失败。
    ///
    /// 目标应用当前没在运行不算错误：音量留在存储里，等它下次出声时
    /// `performRefresh` 会把值套上去。
    func reportRestoredVolumes() {
        guard isEnabled else { return }
        let storedKeys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(AudioControlSupport.volumeKeyPrefix) }
        guard !storedKeys.isEmpty else { return }

        // 先刷一轮拿到当前在出声的列表 —— 应用刚启动时 controlledApps 还是空的，
        // 不刷新会把「还没发现」误报成「没在运行」。
        performRefresh()
        let liveKeys = Set(controlledApps.map(\.uniqueKey))
        let plan = AudioControlSupport.volumeRestorePlan(storedKeys: storedKeys,
                                                        liveKeys: liveKeys)
        if plan.pending.isEmpty {
            os_log(.info, log: log, "restored volume for %d app(s)", plan.applied.count)
        } else {
            os_log(.info, log: log,
                   "restored volume for %d app(s); %d waiting for app to run: %{public}@",
                   plan.applied.count, plan.pending.count,
                   plan.pending.joined(separator: ", "))
        }

        if !plan.applied.isEmpty || !plan.pending.isEmpty {
            let restored = "已恢复 \(plan.applied.count) 个应用的音量"
            let waiting = plan.pending.isEmpty
                ? ""
                : "；\(plan.pending.count) 个应用当前没在出声（也可能没在运行），音量等它们下次出声时生效"
            SleepController.shared.appendLog("逐应用音量：" + restored + waiting)
        }
    }

    // MARK: - 启动与停止

    private func start() {
        installWatchers()
        performRefresh()
        startTimers()
        os_log(.info, log: log, "manager started")
    }

    private func startTimers() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.performRefresh() }
        }
        healthTimer?.invalidate()
        // 5~10 秒一次轻量探活：授权被中途关掉没有任何通知，只能自己看峰值。
        healthTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.runHealthCheck() }
        }
    }

    private func stopTimers() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func shutdown(reason: String) {
        stopTimers()
        permissionProbeTask?.cancel()
        permissionProbeTask = nil
        removeWatchers()
        teardownEngines()
        controlledApps.removeAll()
        rebuildAttempts.removeAll()
        idleRefreshes.removeAll()
        blockedKeys.removeAll()
        permission = .unknown
        rebuildScheduled = false
        quickRefreshPending = false
        os_log(.info, log: log, "manager stopped (%{public}@)", reason)
    }

    // MARK: - 刷新

    /// 核心刷新逻辑：发现进程 → 合并 → 对比 → 启停引擎。
    private func performRefresh() {
        guard isEnabled, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let processes = discoverOutputProcesses()
        let merged = AudioControlSupport.mergeByBundleID(processes)

        var withVolumes: [AudioControlledApp] = []
        for var app in merged {
            app.volume = AudioControlSupport.storedVolume(for: app, defaults: defaults)
            withVolumes.append(app)
        }
        controlledApps = withVolumes

        // 输出设备不可用（拔掉了 / coreaudiod 正在重启）：先全拆，等设备回来再建。
        guard let deviceUID = currentOutputDeviceUID() else {
            teardownEngines()
            return
        }

        // 已经不在列表里的 app：拆掉引擎
        let liveKeys = Set(withVolumes.map(\.uniqueKey))
        for key in Array(engines.keys) where !liveKeys.contains(key) {
            destroyEngine(forKey: key)
            rebuildAttempts[key] = nil
            idleRefreshes[key] = nil
        }

        for app in withVolumes {
            let key = app.uniqueKey
            idleRefreshes[key] = app.isProducingAudio ? 0 : (idleRefreshes[key] ?? 0) + 1
            // 安静下来的 app 下次再出声时重新给链路一次机会。
            if !app.isProducingAudio { blockedKeys.remove(key) }

            let gain = AudioControlSupport.gain(for: app.volume)
            let wantsEngine = app.volume < AudioControlSupport.maxVolume - 0.0001

            guard let engine = engines[key] else {
                if !permission.isDenied, !blockedKeys.contains(key), wantsEngine, app.isProducingAudio,
                   let created = makeEngine(for: app, deviceUID: deviceUID, gain: gain) {
                    engines[key] = created
                }
                continue
            }

            if !wantsEngine || permission.isDenied {
                destroyEngine(forKey: key)
                continue
            }

            if blockedKeys.contains(key) {
                engine.stopIO()
                continue
            }

            engine.gain = gain

            // 有 bundleID 的 tap 由 processRestoreEnabled 自己跟进程，
            // 只有设备换了、或按 pid 建的 tap 目标变了才重建。
            let needsRebuild = AudioControlSupport.engineNeedsRebuild(
                objects: app.audioObjectIDs,
                deviceUID: deviceUID,
                currentBundleID: engine.bundleID,
                currentObjects: engine.tappedObjects,
                currentDeviceUID: engine.outputDeviceUID)

            if needsRebuild {
                rebuildEngine(forKey: key, app: app, deviceUID: deviceUID)
            } else if app.isProducingAudio {
                engine.startIO()
            } else if AudioControlSupport.ioShouldStop(volume: app.volume,
                                                      isProducing: false,
                                                      idleRefreshes: idleRefreshes[key] ?? 0) {
                // 目标安静了：停 IOProc 省电。tap 与聚合设备留着，
                // 而且没人读 tap 时 mutedWhenTapped 会松开摘流，声音照常。
                engine.stopIO()
            }
        }
    }

    // MARK: - 引擎生命周期（全部经过串行队列）

    private func makeEngine(for app: AudioControlledApp, deviceUID: String, gain: Float) -> AudioControlEngine? {
        let spec = AudioControlEngine.Spec(bundleID: app.bundleID,
                                           objects: app.audioObjectIDs,
                                           deviceUID: deviceUID)
        let engine = rebuildQueue.sync { AudioControlEngine(spec: spec, initialGain: gain) }
        if engine == nil {
            lastError = "无法为「\(app.displayName)」创建音频引擎"
            os_log(.error, log: log, "build engine failed for %{public}@", app.displayName)
        }
        return engine
    }

    private func rebuildEngine(forKey key: String, app: AudioControlledApp, deviceUID: String) {
        destroyEngine(forKey: key)
        if let engine = makeEngine(for: app, deviceUID: deviceUID,
                                   gain: AudioControlSupport.gain(for: app.volume)) {
            engines[key] = engine
        }
    }

    private func destroyEngine(forKey key: String) {
        guard let engine = engines.removeValue(forKey: key) else { return }
        rebuildQueue.sync { engine.stop() }
    }

    private func teardownEngines() {
        let all = engines
        engines.removeAll()
        guard !all.isEmpty else { return }
        rebuildQueue.sync {
            for engine in all.values { engine.stop() }
        }
    }

    // MARK: - 探活与自愈

    private func runHealthCheck() {
        guard isEnabled else { return }

        // 已经判定没授权：每隔一轮试一次金丝雀，等用户去系统设置里打开。
        if permission.isDenied {
            probePermission()
            return
        }

        for (key, engine) in Array(engines) {
            // 已经判定链路不可用的，等它自己安静下来或用户改音量再试：
            // 这里再去探一次只会把「停用」变成「停用→重建→停用」的循环。
            if blockedKeys.contains(key) { continue }
            guard let app = controlledApps.first(where: { $0.uniqueKey == key }) else { continue }

            let peak = engine.drainPeak()
            let windows = engine.drainInputWindows()
            // 只有「目标在出声 + IOProc 在跑」时，全零才说明链路有问题。
            let observable = app.isProducingAudio && engine.isRunning
            let attempts = rebuildAttempts[key] ?? 0

            switch AudioTapHealthPolicy.verdict(peak: peak,
                                                isProducing: observable,
                                                rebuildAttempts: attempts,
                                                receivedWindows: windows) {
            case .healthy:
                rebuildAttempts[key] = nil
                if observable, peak > AudioTapHealthPolicy.silenceThreshold, permission != .granted {
                    permission = .granted
                }
            case .rebuild:
                rebuildAttempts[key] = attempts + 1
                os_log(.error, log: log, "tap silent for %{public}@ (windows=%llu), rebuilding once",
                       key, windows)
                if let deviceUID = currentOutputDeviceUID() {
                    rebuildEngine(forKey: key, app: app, deviceUID: deviceUID)
                }
            case .permissionDenied:
                enterPermissionDenied()
                return
            case .chainUnavailable:
                // 连数据都没有，跟授权无关：多半是聚合设备的输入流没接上。
                // 停 IOProc 让目标 app 回到原路径正常出声，别再自动重试，
                // 否则每 2 秒建一次拆一次，比不出声更糟。
                engine.stopIO()
                blockedKeys.insert(key)
                lastError = "「\(app.displayName)」的音频链路不可用，已暂时停用"
                os_log(.error, log: log, "audio chain unavailable for %{public}@, suspended", key)
            }
        }
    }

    private func enterPermissionDenied() {
        guard !permission.isDenied else { return }
        permission = .denied
        lastError = "需要「系统音频录制」权限"
        os_log(.error, log: log, "audio capture permission missing; tearing down all engines")
        // 没授权时 tap 照样把 app 从系统混音里摘走了，数据却是零 ——
        // 留在那儿就是把这个 app 静音了。全部拆掉，声音立刻回来。
        teardownEngines()
        rebuildAttempts.removeAll()
        idleRefreshes.removeAll()
        blockedKeys.removeAll()
    }

    /// 授权被撤销之后，每隔 6 秒建一个 1.5 秒的金丝雀 tap 看峰值。
    ///
    /// 用完立刻拆：没授权时它会让目标 app 静那 1.5 秒，不能常驻。
    private func probePermission() {
        guard permissionProbeTask == nil else { return }
        guard let app = controlledApps.first(where: { $0.isProducingAudio }) else { return }

        let spec = AudioControlEngine.Spec(bundleID: app.bundleID,
                                           objects: app.audioObjectIDs,
                                           deviceUID: currentOutputDeviceUID() ?? "")
        guard !spec.deviceUID.isEmpty else { return }

        permissionProbeTask = Task { [weak self] in
            guard let self else { return }
            let canary = self.rebuildQueue.sync { AudioControlEngine(spec: spec, initialGain: 1.0) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let peak = canary?.drainPeak() ?? 0
            self.rebuildQueue.sync { canary?.stop() }
            self.permissionProbeTask = nil

            guard self.isEnabled, self.permission.isDenied,
                  peak > AudioTapHealthPolicy.silenceThreshold else { return }
            os_log(.info, log: log, "audio capture permission restored")
            self.permission = .granted
            self.lastError = nil
            self.rebuildAttempts.removeAll()
            self.performRefresh()
        }
    }

    // MARK: - CoreAudio 监听

    private func installWatchers() {
        let watcher = self.watcher ?? CoreAudioWatcher()
        watcher.removeAll()
        let system = AudioObjectID(kAudioObjectSystemObject)

        // coreaudiod 重启：tap、聚合设备、IOProc 的 id 一起失效。
        // 这是硬失效，只能全量重建，不能复用 id。
        watcher.add(object: system, selector: kAudioHardwarePropertyServiceRestarted) { [weak self] in
            Task { @MainActor in self?.scheduleFullRebuild(reason: "coreaudiod 重启") }
        }

        // 默认输出设备变了：聚合设备的主 sub-device 与 tap 的 deviceUID 都得换。
        watcher.add(object: system, selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            Task { @MainActor in self?.scheduleFullRebuild(reason: "默认输出设备变化") }
        }

        // 设备列表变化：插拔、蓝牙连断。
        // 不能无脑重建 —— 我们自己的聚合设备建/拆也会触发这条通知，
        // 那样就成了无限重建。先比对当前默认设备的 UID 再说。
        watcher.add(object: system, selector: kAudioHardwarePropertyDevices) { [weak self] in
            Task { @MainActor in self?.handleDeviceListChanged() }
        }

        // 有人开始/停止出声：只提前一轮刷新，不重建。
        watcher.add(object: system, selector: kAudioHardwarePropertyProcessObjectList) { [weak self] in
            Task { @MainActor in self?.scheduleQuickRefresh() }
        }

        // 当前输出设备被拔：alive 掉到 0，旧 id 还能查但已经不出声。
        if let device = currentOutputDevice() {
            watcher.add(object: device, selector: kAudioDevicePropertyDeviceIsAlive) { [weak self] in
                Task { @MainActor in self?.scheduleFullRebuild(reason: "输出设备已断开") }
            }
        }

        self.watcher = watcher
    }

    private func removeWatchers() {
        watcher?.removeAll()
        watcher = nil
    }

    /// 设备列表变了：只有「默认输出设备换了或没了」才值得重建。
    ///
    /// 我们的聚合设备一建一拆都会发这条通知，不看设备就重建会自激。
    private func handleDeviceListChanged() {
        guard isEnabled else { return }
        guard let device = currentOutputDevice(), let uid = deviceUID(of: device) else {
            scheduleFullRebuild(reason: "输出设备消失")
            return
        }
        guard engines.values.contains(where: { $0.outputDeviceUID != uid }) else { return }
        scheduleFullRebuild(reason: "输出设备变化")
    }

    /// 全量重建：先拆干净再建，中间不留「tap 活着但没人读」的空档。
    private func scheduleFullRebuild(reason: String) {
        guard isEnabled, !rebuildScheduled else { return }
        rebuildScheduled = true
        os_log(.info, log: log, "audio chain rebuild scheduled: %{public}@", reason)

        Task { @MainActor in
            // 一次硬件变化往往连着发好几条通知，合并成一次，
            // 否则会出现两个聚合设备抢同一个物理设备。
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.rebuildScheduled = false
            guard self.isEnabled else { return }

            self.permissionProbeTask?.cancel()
            self.permissionProbeTask = nil
            self.teardownEngines()
            self.rebuildAttempts.removeAll()
            self.idleRefreshes.removeAll()
            self.blockedKeys.removeAll()
            self.installWatchers()
            self.performRefresh()
        }
    }

    private func scheduleQuickRefresh() {
        guard isEnabled, !quickRefreshPending else { return }
        quickRefreshPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.quickRefreshPending = false
            self.performRefresh()
        }
    }

    // MARK: - CoreAudio 查询

    private func currentOutputDevice() -> AudioObjectID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr,
              device != 0, AudioControlEngine.isDeviceAlive(device) else { return nil }
        return device
    }

    /// 当前系统默认输出设备的 UID。设备不可用时返回 nil（调用方据此拆引擎）。
    private func currentOutputDeviceUID() -> String? {
        guard let device = currentOutputDevice() else { return nil }
        return deviceUID(of: device)
    }

    private func deviceUID(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let uid, (uid as String).isEmpty == false else { return nil }
        return uid as String
    }

    /// 发现所有 IsRunningOutput=true 的进程对象。
    private func discoverOutputProcesses() -> [(objectID: AudioObjectID, pid: pid_t, bundleID: String?, isProducing: Bool)] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        var result: [(AudioObjectID, pid_t, String?, Bool)] = []
        for object in objects {
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = -1
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { continue }

            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)
            var bundle: CFString?
            var bundleSize = UInt32(MemoryLayout<CFString?>.size)
            let bundleID = (AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr
                            && bundle != nil) ? (bundle! as String) : nil

            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            let isProducing = (AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr
                               && running != 0)

            if isProducing {
                result.append((object, pid, bundleID, true))
            }
        }
        return result
    }

    // MARK: - 持久化

    private func saveVolume(_ volume: Double, for app: AudioControlledApp) {
        defaults.set(volume, forKey: AudioControlSupport.volumeKey(for: app))
    }

    /// 更新 @Published 数组里单个 app 的 volume（触发 UI 刷新）。
    private func updateAppVolume(_ key: String, _ volume: Double) {
        if let index = controlledApps.firstIndex(where: { $0.uniqueKey == key }) {
            controlledApps[index].volume = volume
        }
    }
}

// MARK: - CoreAudio 属性监听

/// 把「注册属性监听」的样板收在一处。
///
/// 回调在内部串行队列上跑，handler 里不能直接动 UI，
/// 调用方自己跳主线程。
final class CoreAudioWatcher {

    private var registrations: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private let queue = DispatchQueue(label: "com.skyc8266.deepsleep.audio.watch")

    @discardableResult
    func add(object: AudioObjectID,
             selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             handler: @escaping () -> Void) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                mScope: scope,
                                                mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else {
            return false
        }
        registrations.append((object, address, block))
        return true
    }

    /// 摘掉全部监听。coreaudiod 重启后旧的注册会一起失效，重建前也要先清一遍。
    func removeAll() {
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(registration.object, &address, queue, registration.block)
        }
        registrations.removeAll()
    }

    deinit {
        removeAll()
    }
}
