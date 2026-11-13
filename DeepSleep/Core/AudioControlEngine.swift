//
//  AudioControlEngine.swift
//  Deep Sleep
//
//  实时音频引擎：一个 app 一个 tap + 聚合设备 + IOProc。
//  - 不改系统默认输出：聚合设备的 sub-device 就是真实输出设备，
//    CoreAudio 在设备层混音，被 tap 的 app 从原路径摘出，重渲染回去。
//  - IOProc 纯实时：只做 memset 与 vDSP_vsmul，无锁、无分配、无回调。
//  - 增益 0...1（衰减 only），消除削波与限制器需求。
//  - 异常时 stop() 拆掉聚合设备与 tap，音频自动回流到真实设备。
//

import Foundation
import CoreAudio
import Accelerate
import os.log

private let log = OSLog(subsystem: "com.skyc8266.deepsleep", category: "AudioControl")

/// 单个应用的音频控制引擎。
/// 生命周期：init →（运行中可改 gain / 停启 IOProc）→ stop → deinit 也会 stop。
final class AudioControlEngine {

    /// 引擎的建立参数。重建时整体换掉，不原地改 —— 聚合设备的
    /// sub-device 与 tap 的 deviceUID 都绑死在创建那一刻。
    struct Spec: Equatable {
        let bundleID: String?
        let objects: [AudioObjectID]
        let deviceUID: String
    }

    // MARK: - 公开状态

    let spec: Spec
    var outputDeviceUID: String { spec.deviceUID }
    var tappedObjects: [AudioObjectID] { spec.objects }
    var bundleID: String? { spec.bundleID }

    /// 当前增益（线性，0...1）。
    var gain: Float {
        get { context.gain.value }
        set { context.gain.value = min(max(newValue, 0), 1) }
    }

    /// IOProc 回调计数（调试与自检用）。
    var renderCycles: UInt64 { context.cycles.value }

    /// IOProc 是否在跑。false 时 tap 与聚合设备还在，只是没人读。
    private(set) var isRunning = false

    /// 最近一次错误（用于 UI 展示）。
    private(set) var lastError: String?

    // MARK: - 私有状态

    /// IOProc 与主线程共享的数据。
    ///
    /// **必须放在堆上**：`AudioDeviceCreateIOProcID` 只保存指针，不会拷贝。
    /// 以前这里是个 init 里的局部 struct，init 一返回指针就指向已回收的栈帧 ——
    /// IOProc 读到的是随机值。
    private final class RenderContext {
        let gain = AtomicFloatBox(1.0)
        let peak = AtomicPeakBox()
        let cycles = AtomicCycleBox()
        /// 真的有 tap 数据的周期数。用来区分「链路没数据」与「数据全零」。
        let inputWindows = AtomicCycleBox()
    }

    private let context = RenderContext()
    private(set) var tapID = AudioObjectID(0)
    private(set) var aggregateID = AudioObjectID(0)
    private var ioProcID: AudioDeviceIOProcID?
    /// 上一次 `drainInputWindows()` 读到的计数（主线程专用）。
    private var lastInputWindows: UInt64 = 0

    // MARK: - 初始化

    /// - Parameters:
    ///   - spec: tap 的目标进程、所属 bundle、真实输出设备
    ///   - initialGain: 初始增益（0...1）
    init?(spec: Spec, initialGain: Float = 1.0) {
        guard !spec.objects.isEmpty else { return nil }
        self.spec = spec

        context.gain.value = min(max(initialGain, 0), 1)

        guard let tap = Self.createTap(spec: spec) else {
            lastError = "创建音频捕获失败"
            os_log(.error, log: log, "create tap failed bundle=%{public}@ objects=%{public}@",
                   spec.bundleID ?? "-", spec.objects.map(String.init).joined(separator: ","))
            return nil
        }
        tapID = tap

        // tap 的真实 UID 只能从 HAL 读：`CATapDescription.uuid` 里那个值
        // 是未文档化行为（虽然当下一致），Apple 示例读的是 'tuid'。
        guard let tapUID = Self.tapUID(of: tap) else {
            lastError = "读取捕获标识失败"
            os_log(.error, log: log, "read kAudioTapPropertyUID failed tap=%{public}u", tap)
            stop()
            return nil
        }

        guard let agg = createAggregate(tapUID: tapUID) else {
            lastError = "创建音频聚合设备失败"
            os_log(.error, log: log, "create aggregate failed tapUID=%{public}@", tapUID)
            stop()
            return nil
        }
        aggregateID = agg

        guard let channels = Self.outputStreamChannels(of: agg), !channels.isEmpty,
              Self.nominalSampleRate(of: agg) != nil else {
            lastError = "音频聚合设备格式无效"
            os_log(.error, log: log, "aggregate format invalid agg=%{public}u", agg)
            stop()
            return nil
        }

        guard createIOProc() else {
            lastError = "创建音频回调失败"
            stop()
            return nil
        }

        startIO()
        guard isRunning else {
            lastError = "无法启动音频输出"
            stop()
            return nil
        }

        os_log(.info, log: log, "engine started tap=%{public}u agg=%{public}u device=%{public}@ gain=%.3f",
               tapID, aggregateID, spec.deviceUID, gain)
    }

    deinit {
        stop()
    }

    // MARK: - 公开控制

    /// 启动 IOProc。幂等。
    func startIO() {
        guard let proc = ioProcID, aggregateID != 0, !isRunning else { return }
        let status = AudioDeviceStart(aggregateID, proc)
        if status == noErr {
            isRunning = true
            lastError = nil
        } else {
            lastError = "无法启动音频输出（\(status)）"
            os_log(.error, log: log, "AudioDeviceStart failed status=%{public}d", status)
        }
    }

    /// 停掉 IOProc，保留 tap 与聚合设备。幂等。
    ///
    /// 停掉之后没人读 tap，`mutedWhenTapped` 的摘流随之松开 ——
    /// 目标 app 回到原路径正常出声，这也是省电那一档的安全前提。
    func stopIO() {
        guard isRunning else { return }
        if let proc = ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, proc)
        }
        isRunning = false
    }

    /// 取走这一窗口的输入峰值，同时清零重新开始累计。
    func drainPeak() -> Float {
        context.peak.drain()
    }

    /// 取走这一窗口「真的有 tap 数据」的周期数增量（主线程读）。
    ///
    /// 只读差值不清零：计数器由音频线程单调累加，重置它会和累加撞在一起。
    func drainInputWindows() -> UInt64 {
        let current = context.inputWindows.value
        let delta = current >= lastInputWindows ? current - lastInputWindows : current
        lastInputWindows = current
        return delta
    }

    /// 停止并拆除引擎。幂等。
    ///
    /// 顺序不能换：先停 IOProc，再拆聚合设备，最后销毁 tap。
    /// 先拆 tap 的话，聚合设备还挂着一个不存在的 tap，HAL 会报错；
    /// 而 tap 先没了会让目标 app 在拆聚合设备之前处于「被摘出混音」
    /// 的状态，读端已经不在了 —— 那就是一段真正的静音。
    func stop() {
        if isRunning, let proc = ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, proc)
        }
        isRunning = false

        if let proc = ioProcID, aggregateID != 0 {
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil

        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }

        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }

        os_log(.info, log: log, "engine stopped")
    }

    // MARK: - 构建步骤

    /// 创建 process tap。
    private static func createTap(spec: Spec) -> AudioObjectID? {
        let desc = CATapDescription(processes: spec.objects, deviceUID: spec.deviceUID, stream: 0)
        desc.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        desc.isPrivate = true
        desc.name = "DeepSleep \(spec.bundleID ?? "process")"
        // macOS 26：按 bundle 记目标。app 退出重开换了 PID 也不用重建 tap，
        // 否则每重启一次播放器就断一次音。
        if let bundleID = spec.bundleID, !bundleID.isEmpty {
            desc.bundleIDs = [bundleID]
            desc.isProcessRestoreEnabled = true
        }
        var tapID = AudioObjectID(0)
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr, tapID != 0 else { return nil }
        return tapID
    }

    /// 读 tap 的真实 UID。
    private static func tapUID(of tap: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &uid) == noErr,
              let uid, (uid as String).isEmpty == false else { return nil }
        return uid as String
    }

    /// 创建私有聚合设备：主 sub-device 是真实输出设备，tap 只作为 input。
    private func createAggregate(tapUID: String) -> AudioObjectID? {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DeepSleep AudioControl \(UUID().uuidString.prefix(8))",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: spec.deviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: spec.deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var aggregateID = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID) == noErr,
              aggregateID != 0 else { return nil }
        return aggregateID
    }

    /// 建 IOProc。上下文用 `Unmanaged` 传裸指针，闭包捕获的东西
    /// 不能直接当 C 函数指针用。
    private func createIOProc() -> Bool {
        let contextPointer = Unmanaged.passUnretained(context).toOpaque()

        let ioProc: AudioDeviceIOProc = { _, _, inInputData, _, outOutputData, _, clientData in
            guard let clientData else { return noErr }
            let context = Unmanaged<RenderContext>.fromOpaque(clientData).takeUnretainedValue()
            context.cycles.increment()

            let outList = UnsafeMutableAudioBufferListPointer(outOutputData)

            // 1. 先把所有输出清零。
            //    没有 tap 数据、格式不匹配、通道数为 0 的周期都必须输出静音；
            //    直接 return 会让硬件缓冲里留着上一轮的内容，听感是卡带式重复。
            for buffer in outList {
                guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
                memset(data, 0, Int(buffer.mDataByteSize))
            }

            guard outList.count > 0 else { return noErr }
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard inList.count > 0 else { return noErr }

            // 聚合设备的输入里，sub-device 那份通常没有通道，tap 在后面。
            var tapBuffer: AudioBuffer?
            for index in stride(from: inList.count - 1, through: 0, by: -1) {
                let candidate = inList[index]
                if candidate.mNumberChannels > 0, candidate.mData != nil {
                    tapBuffer = candidate
                    break
                }
            }
            guard let source = tapBuffer,
                  let sourcePointer = source.mData?.assumingMemoryBound(to: Float.self) else { return noErr }

            let sourceChannels = Int(source.mNumberChannels)
            let frames = Int(source.mDataByteSize) / (MemoryLayout<Float>.size * sourceChannels)
            guard frames > 0 else { return noErr }
            context.inputWindows.increment()

            // 2. 峰值取自增益**之前**的原始数据：这就是「有没有授权」的
            //    唯一判据 —— 没授权时链路全通但这里永远是 0。
            var peak: Float = 0
            vDSP_maxmgv(sourcePointer, 1, &peak, vDSP_Length(frames * sourceChannels))
            context.peak.raise(peak)

            var gain = context.gain.value
            if gain < 0 { gain = 0 }
            let isUnity = gain >= 0.999

            for destination in outList {
                guard destination.mNumberChannels > 0,
                      let destinationPointer = destination.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let destinationChannels = Int(destination.mNumberChannels)
                let writeFrames = min(frames, Int(destination.mDataByteSize) / (MemoryLayout<Float>.size * destinationChannels))
                guard writeFrames > 0 else { continue }

                if destinationChannels == sourceChannels {
                    let sampleCount = writeFrames * sourceChannels
                    if isUnity {
                        // unity 直接拷贝，省一次乘法。**不能**直接 return：
                        // 输出刚被清零、tap 又把原路径摘掉了，少这一份就是静音。
                        memcpy(destinationPointer, sourcePointer, sampleCount * MemoryLayout<Float>.size)
                    } else {
                        vDSP_vsmul(sourcePointer, 1, &gain, destinationPointer, 1, vDSP_Length(sampleCount))
                    }
                } else if sourceChannels == 1 {
                    for channel in 0..<destinationChannels {
                        vDSP_vsmul(sourcePointer, 1, &gain, destinationPointer + channel,
                                   vDSP_Stride(destinationChannels), vDSP_Length(writeFrames))
                    }
                } else {
                    for channel in 0..<destinationChannels {
                        let sourceChannel = channel < sourceChannels ? channel : 0
                        vDSP_vsmul(sourcePointer + sourceChannel, vDSP_Stride(sourceChannels), &gain,
                                   destinationPointer + channel, vDSP_Stride(destinationChannels),
                                   vDSP_Length(writeFrames))
                    }
                }
            }
            return noErr
        }

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(aggregateID, ioProc, contextPointer, &procID)
        guard status == noErr, let procID else {
            os_log(.error, log: log, "create IOProc failed status=%{public}d", status)
            return false
        }
        ioProcID = procID
        return true
    }

    // MARK: - 静态查询

    static func nominalSampleRate(of device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr ? rate : nil
    }

    /// 设备是否还活着。拔掉设备之后旧 id 仍然能被查询，但 alive 变 0。
    static func isDeviceAlive(_ device: AudioObjectID) -> Bool {
        guard device != 0 else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr else { return false }
        return alive != 0
    }

    static func outputStreamChannels(of device: AudioObjectID) -> [UInt32]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: kAudioObjectPropertyScopeOutput,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        // AudioBufferList 是柔性数组，按最大 32 个 AudioBuffer 预留
        let maxBuffers = 32
        let bufferSize = MemoryLayout<AudioBufferList>.size + (maxBuffers - 1) * MemoryLayout<AudioBuffer>.size
        var storage = Data(count: bufferSize)
        return storage.withUnsafeMutableBytes { rawPointer in
            guard let base = rawPointer.baseAddress,
                  AudioObjectGetPropertyData(device, &address, 0, nil, &size, base) == noErr else { return nil as [UInt32]? }
            let list = base.assumingMemoryBound(to: AudioBufferList.self)
            var channels: [UInt32] = []
            withUnsafePointer(to: list.pointee.mBuffers) { firstBuffer in
                let buffers = UnsafeMutableRawPointer(mutating: firstBuffer).assumingMemoryBound(to: AudioBuffer.self)
                for index in 0..<Int(list.pointee.mNumberBuffers) {
                    channels.append(buffers[index].mNumberChannels)
                }
            }
            return channels.isEmpty ? nil : channels
        }
    }

    static func outputFormats(of device: AudioObjectID) -> [AudioStreamBasicDescription]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                                mScope: kAudioObjectPropertyScopeOutput,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioStreamBasicDescription>.size
        var formats = [AudioStreamBasicDescription](repeating: AudioStreamBasicDescription(), count: count)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &formats) == noErr else { return nil }
        return formats.isEmpty ? nil : formats
    }

    static func frames(bytes: UInt32, channels: UInt32) -> Int {
        guard channels > 0 else { return 0 }
        return Int(bytes) / (MemoryLayout<Float>.size * Int(channels))
    }
}

// MARK: - 原子盒子（实时线程安全）

/// 单 float 原子读写（用 bitPattern 避免 Swift 的 atomic 还没稳定）。
final class AtomicFloatBox: @unchecked Sendable {
    private var bits: UInt32 = 0
    init(_ value: Float) { bits = value.bitPattern }
    var value: Float {
        get { Float(bitPattern: bits) }
        set { bits = newValue.bitPattern }
    }
}

/// 峰值。IOProc 只抬不读，主线程只读并清零。
///
/// 用 CAS 而不是普通自增：音频线程和读侧可能同时碰这个格子，
/// 而实时线程上不能加锁。
final class AtomicPeakBox: @unchecked Sendable {
    private var rawBits: Int32 = 0

    func raise(_ value: Float) {
        guard value > 0 else { return }
        var expected = rawBits
        while true {
            if value <= Float(bitPattern: UInt32(bitPattern: expected)) { return }
            let desired = Int32(bitPattern: value.bitPattern)
            if OSAtomicCompareAndSwap32Barrier(expected, desired, &rawBits) { return }
            expected = rawBits
        }
    }

    /// 取走当前峰值并清零。
    func drain() -> Float {
        var expected = rawBits
        while true {
            if expected == 0 { return 0 }
            if OSAtomicCompareAndSwap32Barrier(expected, 0, &rawBits) {
                return Float(bitPattern: UInt32(bitPattern: expected))
            }
            expected = rawBits
        }
    }
}

/// 原子计数器（仅 IOProc 增，主线程读）。
final class AtomicCycleBox: @unchecked Sendable {
    private var count: UInt64 = 0
    func increment() { _ = OSAtomicIncrement64Barrier(&count) }
    var value: UInt64 { count }
}
