//
//  SMCFanControl.swift
//  deepsleep-helper
//
//  风扇读写（SMC）。
//
//  ============================================================================
//  规格来源
//  ============================================================================
//  全部按 docs/SMC.md 的实测报告实现：§2.2（结构体偏移）、§2.4（FourCC 字节序）、
//  §2.5（读命令必须回填 dataSize）、§2.6 / §2.6.1（写命令与写入顺序）、
//  §2.8（写风扇速查卡）、§4.2（模式键）、§4.3（转速键）、§4.4（写 RPM）。
//
//  **不复用**网上流传的 SMCParamStruct（AlDente 那套）：那份布局在 Apple Silicon 上
//  读不到任何东西（kr=KERN_SUCCESS 但 dataType=0 / dataSize=0）。本文件按 SMC.md
//  §2.2 的偏移自己组包。方法 ID 固定是 2（kSMCHandleYPCEvent），命令走帧里的
//  命令字节（+0x2A），不是拿命令当方法 ID。
//
//  三条硬约束（违反会静默出错，不是报错）：
//   1. 写入长度必须等于该键声明的 dataSize，否则 SMC 返 0xE00002BC。
//      所以每次写之前都先 GetKeyInfo 拿真实长度。
//   2. 读命令 5 必须回填 dataSize，否则**不报错**、静默返回全 0。
//   3. 顺序必须先模式后目标：写 F<n>Md=1（手动）→ 再写 F<n>Tg=float(rpm)；
//      交回自动写 F<n>Md=0。
//
//  ============================================================================
//  机型差异一律运行时探测，不硬编码
//  ============================================================================
//   - 模式键大小写：F<n>Md ↔ F<n>md
//   - 全局模式键：FS! （2 字节位掩码）是否存在
//   - 转速键长度：4 字节 float（现代）↔ 2 字节定点 RPM×4（老机型）
//   - 风扇数量：FNum
//   - 风扇名：F<n>ID（16 字节），读不到回落成 "Fan N"
//
//  ============================================================================
//  三条安全底线
//  ============================================================================
//  1. **租约**：手动模式下风扇转速不再由 SMC 决定，而由「谁写的」决定。写它的进程
//     死了而手动模式还留着，风扇就会永久停在一个（可能很低的）转速 —— 等于把散热
//     交给一个已经不存在的进程。所以每次写配一份租约，到期自动交回系统自动控制。
//
//  2. **免责声明门禁**：写 SMC 前必须确认用户明示同意过（FanDisclaimer）。
//     门禁放在执行点，不是调用点 —— 绕过应用直接打 socket 也拦得住。
//
//  3. **90°C 硬兜底**：助手在持有控制权期间自己读温度，任一传感器 ≥ 90°C 就把所有
//     可写风扇拉到 maxRPM 并保持。这条**独立于应用是否还活着**：应用崩了、被强杀、
//     租约断了，助手仍然自己判断、自己写。紧急状态下拒绝一切降速意图（含「交回系统」），
//     只有温度回落且冷却满 `FanControl.emergencyCooldownSeconds` 才解除。
//

import Foundation
import IOKit
import Darwin

// MARK: - 助手日志（风扇模块自带）

/// 风扇模块的极简日志写入器。
///
/// 为什么不用 main.swift 里的 LogWriter：那个类是文件私有的，跨文件拿不到。
/// 这里用 stdio 的 "a" 模式（等价 O_APPEND）追加到同一个日志文件：每次 write 落在
/// 文件末尾，两个写入方不会互相覆盖半行。
enum FanLog {
    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] [helper][fan] \(message)\n"

        guard let handle = fopen(HelperConstants.logPath, "a") else { return }
        fputs(line, handle)
        fflush(handle)
        fclose(handle)
    }
}

// MARK: - 租约登记表

/// 风扇租约登记：风扇序号 → 租约到期时间。
///
/// 全局单例：助手侧可能存在多个 `SMCFanControl` 实例（读状态可以随手 new 一个），
/// 但租约只有一份 —— 否则「谁写的谁负责收回」这条链就断了。
final class FanLeaseRegistry {

    static let shared = FanLeaseRegistry()

    private let lock = NSLock()
    private var expiry: [Int: Date] = [:]

    /// 刷新某个风扇的租约。`seconds <= 0` 表示不设租约（直接清掉该风扇的租约）。
    func renew(fan: Int, seconds: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard seconds > 0 else {
            expiry.removeValue(forKey: fan)
            return
        }
        expiry[fan] = Date().addingTimeInterval(TimeInterval(seconds))
    }

    /// 放弃某个风扇的租约（已经交回自动了就不需要再收回一次）。
    func cancel(fan: Int) {
        lock.lock()
        defer { lock.unlock() }
        expiry.removeValue(forKey: fan)
    }

    /// 清空全部租约。
    func cancelAll() {
        lock.lock()
        defer { lock.unlock() }
        expiry.removeAll()
    }

    /// 取出并移除已到期的风扇。`now` 可注入，方便单测。
    func takeExpired(now: Date = Date()) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        let dead = expiry.filter { $0.value <= now }.map(\.key).sorted()
        for fan in dead {
            expiry.removeValue(forKey: fan)
        }
        return dead
    }

    /// 当前仍在生效的租约（快照）。
    func activeLeases(now: Date = Date()) -> [Int: Date] {
        lock.lock()
        defer { lock.unlock() }
        return expiry.filter { $0.value > now }
    }
}

// MARK: - 紧急兜底状态

/// 90°C 硬兜底的三态。
///
/// `.cooling` 是为了防阈值抖动：温度刚回落到 90 以下不能马上降速，
/// 否则风扇会在阈值附近反复启停（像在喘气，也伤机械）。
enum FanEmergencyState: Equatable {
    /// 正常，按应用的指令走。
    case normal
    /// 紧急中：所有可写风扇已在 maxRPM，拒绝一切降速意图。
    case active(since: Date)
    /// 温度已回落，冷却计时中；期间仍保持 maxRPM。
    case cooling(since: Date)

    var isEngaged: Bool {
        if case .normal = self { return false }
        return true
    }
}

// MARK: - 风扇控制

/// SMC 风扇读写。
///
/// 每次操作自己开关 SMC 连接：助手重启成本远低于长期持有连接，
/// 也避免 SMC 连接异常挂死时整个助手卡住。
final class SMCFanControl {

    // MARK: 错误

    enum ControlError: Error, CustomStringConvertible {
        case connectionFailed(String)
        case keyMissing(String)
        case statusFailure(key: String, status: UInt8)
        case lengthMismatch(key: String, expected: Int, actual: Int)
        case verificationFailed(key: String, expected: Double, actual: Double)
        case unknownFan(Int)
        case noFansAvailable(String)
        case modeUnavailable
        case noTargetKey(Int)
        case emergencyActive(maxCelsius: Double)

        var description: String {
            switch self {
            case .connectionFailed(let detail):
                return "无法打开 SMC 连接：\(detail)"
            case .keyMissing(let key):
                return "SMC 里没有这个键：\(key)"
            case .statusFailure(let key, let status):
                return "SMC 命令失败：键 \(key) 状态字节 0x\(String(status, radix: 16))"
            case .lengthMismatch(let key, let expected, let actual):
                return "写入长度不匹配：键 \(key) 声明 \(expected) 字节，实际写了 \(actual) 字节（SMC 会回 0xE00002BC）"
            case .verificationFailed(let key, let expected, let actual):
                return "写后校验失败：键 \(key) 期望 \(expected)，读回 \(actual)"
            case .unknownFan(let index):
                return "没有编号为 \(index) 的风扇"
            case .noFansAvailable(let detail):
                return "本机读不到可写风扇：\(detail)"
            case .modeUnavailable:
                return "这台机器没有可用的风扇模式键（F<n>Md / F<n>md / FS! 都不存在）"
            case .noTargetKey(let index):
                return "风扇 \(index) 没有目标转速键（F\(index)Tg 不存在）"
            case .emergencyActive(let maxCelsius):
                return "90°C 紧急兜底生效中（当前最高 \(String(format: "%.2f", maxCelsius))°C），不接受降速请求"
            }
        }
    }

    /// 写一次的结果（供助手回包与日志使用）。
    struct SpeedResult {
        let fan: Int
        /// 实际下发的目标转速（已按 min/max 夹取）。
        let targetRPM: Int
        /// 写完读回的实际转速。
        let actualRPM: Int
        /// 写完读回的目标转速。
        let readbackTargetRPM: Int
        /// 是否手动模式。
        let isManual: Bool
        /// 租约秒数（0 = 不设租约）。
        let leaseSeconds: Int

        func encode() -> [String: String] {
            [
                "fan": "\(fan)",
                "target": "\(targetRPM)",
                "actual": "\(actualRPM)",
                "readback": "\(readbackTargetRPM)",
                "manual": isManual ? "1" : "0",
                "lease": "\(leaseSeconds)"
            ]
        }
    }

    // MARK: 常量

    /// SMC 帧内偏移（docs/SMC.md §2.2）。
    private enum Offset {
        static let frameSize = 0x50          // 80 字节
        static let key = 0x00                // FourCC（字节反序）
        static let dataSize = 0x1C           // u32，该键的数据字节数
        static let dataType = 0x20           // 4 字符类型串（出参）
        static let status = 0x28             // 状态字节（出参）：0x84 = 键不存在，0x89 = 读缺 size
        static let command = 0x2A            // 命令字节（入参）
        static let result = 0x2C             // 结果字节（出参）
        static let valueLow = 0x30           // 值区低 16 字节
        static let valueHigh = 0x40          // 值区高 16 字节
        static let valueSpan = 32
    }

    /// SMC 命令字节（SMC.md §2.3）。
    private enum Command: UInt8 {
        case readKey = 5
        case writeKey = 6
        case listKeys = 8
        case getKeyInfo = 9
    }

    /// SMC 方法 ID。固定是 2（kSMCHandleYPCEvent）—— 命令走帧里的命令字节，
    /// 不是拿命令当方法 ID。实测：方法 ID 传错时 kr 可能是 0 但回包全是 0。
    private static let methodID: UInt32 = 2

    /// 全局手动模式位掩码键（2 字节）。
    private static let globalModeKey = "FS! "

    // MARK: 单例（心跳与兜底的宿主）

    /// 助手内部共享实例。构造即启动租约心跳与 90°C 监控。
    ///
    /// 不设 `private init`：应用侧/测试不应被迫走单例，但助手进程内必须用
    /// `shared` 才能让「谁写的谁收回」这条链成立。
    static let shared = SMCFanControl()

    private var heartbeatTimer: DispatchSourceTimer?

    private init() {
        startHeartbeat()
    }

    // MARK: - 状态（受 stateLock 保护）

    private let stateLock = NSRecursiveLock()

    /// 当前被我们放进手动模式的风扇。空 = 不持有控制权。
    private var manualFans: Set<Int> = []

    /// 每个风扇最后一次由应用请求的目标转速，用于紧急兜底解除后恢复。
    private var lastRequested: [Int: Int] = [:]

    /// 紧急兜底状态。
    private var emergency: FanEmergencyState = .normal

    /// 故障降噪：同一类兜底失败只记一次日志，别把日志刷爆。
    private var lastEmergencyLogReason: String?

    /// 当前紧急状态（供命令层做拒绝判定与回包）。
    var emergencyState: FanEmergencyState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return emergency
    }

    /// 是否正持有风扇控制权（有手动模式的风扇，或已在紧急兜底）。
    var isHoldingControl: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !manualFans.isEmpty || emergency.isEngaged
    }

    /// 认领「遗留」的手动模式风扇。
    ///
    /// 场景：上一任助手崩了，或者应用崩溃时没来得及把风扇交回系统，
    /// 风扇就停在手动模式的某个转速上。这种情况下本实例并没有写过它们
    /// （`manualFans` 为空），90°C 兜底会因为「没持有任何风扇」而完全不监控 ——
    /// 等于把一台正卡在手动模式里的机器放任不管。所以启动时要认领。
    ///
    /// 认领的语义边界很重要：
    ///   - 把这些风扇**纳入 90°C 兜底监控**，紧急时会被拉到最大转速；
    ///   - **不写任何 SMC 值** —— 认领只是「纳入监控」，不是「接管转速」。
    ///     启动探测时用户并没有要求我们调整这些风扇；
    ///   - **不建立租约**。租约是应用与助手之间的约定，遗留风扇没有约定。
    ///     没有租约意味着紧急兜底解除后它们会被交回系统自动控制 —— 这是对的，
    ///     因为已经没有进程还持有它们。
    ///
    /// 调用方只在免责声明已同意时才认领：未同意说明这些手动模式不是我们留下的
    /// （可能是别的工具设的），不该插手，更不该写 SMC。
    ///
    /// - Parameters:
    ///   - indexes: 要认领的风扇序号。
    ///   - state: 启动探测读到的风扇状态，用来核对序号是否真的存在。
    func adoptManualFans(_ indexes: [Int], state: FanState) {
        guard !indexes.isEmpty else { return }

        let existing = Set(state.fans.map(\.index))
        let candidates = indexes.filter { existing.contains($0) }
        guard !candidates.isEmpty else { return }

        stateLock.lock()
        let added = candidates.filter { manualFans.insert($0).inserted }
        stateLock.unlock()

        guard !added.isEmpty else { return }
        FanLog.write("认领遗留手动模式风扇 \(added.sorted())：纳入 90°C 兜底监控，未写任何转速、未建租约")
    }

    // MARK: - 心跳

    private func startHeartbeat() {
        let interval = Double(FanControl.heartbeatSeconds)
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.skyc8266.deepsleep.helper.fan.heartbeat"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.heartbeatTick()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    /// 心跳：先查租约，再查温度。
    ///
    /// 顺序有讲究：温度兜底优先。若先按租约把手动模式交回自动，
    /// 紧接着发现 90°C，就会出现「刚降速又要拉满」的空窗。
    private func heartbeatTick() {
        checkThermalEmergency()
        expireLeases()
    }

    /// 租约到期 → 交回系统自动控制。
    ///
    /// 紧急状态下**不**交回：交回自动意味着转速可能下降，而这一档是
    /// 「任何规则不可覆盖」的最高优先级。
    private func expireLeases() {
        let expired = FanLeaseRegistry.shared.takeExpired()
        guard !expired.isEmpty else { return }

        if emergency.isEngaged {
            FanLog.write("租约到期的风扇 \(expired) 因 90°C 紧急兜底生效中，暂不交回自动控制")
            return
        }

        for fan in expired {
            FanLog.write("fan \(fan) 租约到期，交回系统自动控制")
            do {
                try writeManualMode(fan: fan, manual: false)
                stateLock.lock()
                manualFans.remove(fan)
                lastRequested.removeValue(forKey: fan)
                stateLock.unlock()
            } catch {
                FanLog.write("fan \(fan) 租约到期后交回自动失败：\(error)")
            }
        }
    }

    // MARK: - 90°C 硬兜底

    /// 检查温度并驱动紧急状态机。
    ///
    /// 只在「持有控制权」或「已在兜底」时动作：没写过 SMC 时风扇归系统管，
    /// 那时候插一脚没有意义，反而会抢走系统自己的温控。
    private func checkThermalEmergency() {
        stateLock.lock()
        let holding = !manualFans.isEmpty || emergency.isEngaged
        stateLock.unlock()
        guard holding else { return }

        let maxCelsius: Double
        do {
            maxCelsius = try SMCTemperatureIOHID().maxCelsius()
        } catch {
            // 温度通道不可用：不谎报、不假装兜底成功，记一条日志就走。
            noteEmergencyLog("温度读取失败，跳过本轮兜底判定：\(error)")
            return
        }

        stateLock.lock()
        let previous = emergency
        stateLock.unlock()

        let (next, action) = Self.emergencyTransition(
            from: previous, maxCelsius: maxCelsius, now: Date())

        guard next != previous || action != .none else { return }

        stateLock.lock()
        emergency = next
        let restoreTargets = lastRequested
        let restoreFans = manualFans
        if action == .release {
            manualFans.removeAll()
            lastRequested.removeAll()
        }
        stateLock.unlock()

        let threshold = FanControl.emergencyTemperatureCelsius

        switch action {
        case .none:
            break

        case .engage:
            switch previous {
            case .normal:
                FanLog.write(String(
                    format: "90°C 紧急兜底触发：最高 %.2f°C ≥ %.1f°C，所有可写风扇拉到最大转速并保持",
                    maxCelsius, threshold))
            case .cooling:
                FanLog.write(String(
                    format: "90°C 紧急兜底重新触发：温度回升到 %.2f°C，取消冷却计时",
                    maxCelsius))
            default:
                break
            }
            applyMaximumToAllFans()

        case .holdMaximum:
            applyMaximumToAllFans()

        case .startCooling:
            FanLog.write(String(
                format: "90°C 紧急兜底降温：温度回落到 %.2f°C，进入 %.0f 秒冷却（期间仍保持最大转速）",
                maxCelsius, FanControl.emergencyCooldownSeconds))
            applyMaximumToAllFans()

        case .release:
            let elapsed = Date().timeIntervalSince({
                if case .cooling(let since) = previous { return since }
                return Date()
            }())
            FanLog.write(String(
                format: "90°C 紧急兜底解除：温度 %.2f°C 已低于阈值 %.1f°C 并冷却 %.0f 秒，恢复常规控制",
                maxCelsius, threshold, elapsed))
            restoreAfterEmergency(fans: restoreFans, requested: restoreTargets)
        }
    }

    /// 紧急兜底的动作。
    enum EmergencyAction: Equatable {
        /// 什么都不用做。
        case none
        /// 触发兜底：拉满并进入 active。
        case engage
        /// 已在兜底：保持最大转速。
        case holdMaximum
        /// 温度回落：开始冷却计时，仍保持最大转速。
        case startCooling
        /// 冷却结束：解除兜底，恢复常规控制。
        case release
    }

    /// 状态机。**纯函数**，时间由调用方注入 —— 冷却 60 秒这条规则可以单测，
    /// 不用真的等一分钟。
    static func emergencyTransition(
        from current: FanEmergencyState,
        maxCelsius: Double,
        now: Date
    ) -> (next: FanEmergencyState, action: EmergencyAction) {

        let threshold = FanControl.emergencyTemperatureCelsius

        if maxCelsius >= threshold {
            switch current {
            case .normal:
                return (.active(since: now), .engage)
            case .cooling:
                // 冷却期内温度又冲上去了：取消冷却，重新兜底。
                return (.active(since: now), .engage)
            case .active:
                return (current, .holdMaximum)
            }
        }

        switch current {
        case .normal:
            return (.normal, .none)
        case .active:
            return (.cooling(since: now), .startCooling)
        case .cooling(let since):
            if now.timeIntervalSince(since) >= FanControl.emergencyCooldownSeconds {
                return (.normal, .release)
            }
            return (current, .holdMaximum)
        }
    }

    /// 把所有可写风扇拉到各自 maxRPM。
    private func applyMaximumToAllFans() {
        do {
            let state = try readState()
            var applied = 0
            for fan in state.fans {
                guard fan.minRPM > 0, fan.maxRPM > fan.minRPM else { continue }
                do {
                    try withConnection { connection in
                        let keys = try fanKeys(connection, index: fan.index)
                        guard let targetKey = keys.targetKey else { return }
                        try writeManualMode(connection, keys: keys, manual: true)
                        try writeTargetRPM(connection, key: targetKey, rpm: fan.maxRPM)
                    }
                    applied += 1
                } catch {
                    noteEmergencyLog("fan \(fan.index) 紧急拉满失败：\(error)")
                }
            }
            if applied > 0 {
                stateLock.lock()
                manualFans.formUnion(state.fans.map(\.index))
                stateLock.unlock()
            }
        } catch {
            noteEmergencyLog("紧急兜底读取风扇状态失败：\(error)")
        }
    }

    /// 兜底解除后恢复：有未过期租约的风扇按最后一次请求恢复，其余交回自动。
    private func restoreAfterEmergency(fans: Set<Int>, requested: [Int: Int]) {
        let live = FanLeaseRegistry.shared.activeLeases()
        for fan in fans.sorted() {
            if let target = requested[fan], live[fan] != nil {
                do {
                    try withConnection { connection in
                        let keys = try fanKeys(connection, index: fan)
                        guard let targetKey = keys.targetKey else { return }
                        try writeManualMode(connection, keys: keys, manual: true)
                        try writeTargetRPM(connection, key: targetKey, rpm: target)
                    }
                    stateLock.lock()
                    manualFans.insert(fan)
                    lastRequested[fan] = target
                    stateLock.unlock()
                    FanLog.write("兜底解除后恢复 fan \(fan) 到应用请求的 \(target) RPM")
                } catch {
                    FanLog.write("兜底解除后恢复 fan \(fan) 失败（\(error)），交回自动")
                    try? writeManualMode(fan: fan, manual: false)
                }
            } else {
                do {
                    try writeManualMode(fan: fan, manual: false)
                    FanLog.write("兜底解除后 fan \(fan) 交回系统自动控制")
                } catch {
                    FanLog.write("兜底解除后 fan \(fan) 交回自动失败：\(error)")
                }
            }
        }
    }

    /// 同一类兜底失败只记一次，避免 5 秒一次刷爆日志。
    private func noteEmergencyLog(_ message: String) {
        stateLock.lock()
        let duplicate = lastEmergencyLogReason == message
        if !duplicate { lastEmergencyLogReason = message }
        stateLock.unlock()
        guard !duplicate else { return }
        FanLog.write(message)
    }

    // MARK: - 对外 API

    /// 读所有风扇的实时状态。
    ///
    /// 读不到风扇键（FNum 不存在 / 为 0 / 没有任何风扇有有效区间）时**抛错**，
    /// 不返回空列表假装成功 —— 调用方要能区分「这台机器没风扇」和「读失败了」。
    func readState() throws -> FanState {
        stateLock.lock()
        defer { stateLock.unlock() }

        return try withConnection { connection in
            let count = try fanCount(connection)
            guard count > 0 else {
                throw ControlError.noFansAvailable("FNum 读不到或为 0（这台机器没有可控制的风扇）")
            }

            var fans: [FanState.Fan] = []
            for index in 0..<count {
                let keys = try fanKeys(connection, index: index)

                let name = try readFanName(connection, key: keys.nameKey, index: index)
                let current = try readRPM(connection, key: keys.actualKey)
                let minimum = try readRPM(connection, key: keys.minKey)
                let maximum = try readRPM(connection, key: keys.maxKey)
                let manual = try readManualMode(connection, keys: keys)

                fans.append(FanState.Fan(
                    index: index,
                    name: name,
                    currentRPM: current,
                    minRPM: minimum,
                    maxRPM: maximum,
                    isManual: manual))
            }

            guard fans.contains(where: { $0.minRPM > 0 && $0.maxRPM > $0.minRPM }) else {
                throw ControlError.noFansAvailable(
                    "读到 \(count) 个风扇，但没有一个给出有效的 min/max 转速区间")
            }
            return FanState(fans: fans)
        }
    }

    /// 写风扇。
    ///
    /// - `rpm == 0`：交回系统自动控制（写模式键 = 0），并清掉该风扇的租约。
    /// - `rpm > 0`：先写手动模式、再写目标转速，最后读回校验。
    ///
    /// 目标转速会被夹到 `[minRPM * FanControl.minRpmSafetyRatio, maxRPM]`。
    ///
    /// 门禁（按顺序）：
    ///   1. 未同意免责声明 → 拒绝；
    ///   2. 90°C 兜底生效中且本次是降速（含「交回系统」）→ 拒绝。
    func setSpeed(fan: Int, rpm: Int, leaseSeconds: Int, reason: String?) throws -> SpeedResult {
        try FanDisclaimer.shared.requireAccepted()

        guard rpm >= 0 else {
            throw ControlError.verificationFailed(key: "rpm", expected: 0, actual: Double(rpm))
        }

        try rejectIfEmergencyDownSpeed(fan: fan, requestedRPM: rpm)

        let result = try withConnection { connection -> SpeedResult in
            let count = try fanCount(connection)
            guard count > 0 else {
                throw ControlError.noFansAvailable("FNum 读不到或为 0（这台机器没有可控制的风扇）")
            }
            guard fan < count else { throw ControlError.unknownFan(fan) }

            let keys = try fanKeys(connection, index: fan)

            // 交回自动：只写模式键，不碰目标键。
            guard rpm > 0 else {
                try writeManualMode(connection, keys: keys, manual: false)
                return SpeedResult(
                    fan: fan,
                    targetRPM: 0,
                    actualRPM: try readRPM(connection, key: keys.actualKey),
                    readbackTargetRPM: try readRPM(connection, key: keys.targetKey),
                    isManual: false,
                    leaseSeconds: 0)
            }

            let minimum = try readRPM(connection, key: keys.minKey)
            let maximum = try readRPM(connection, key: keys.maxKey)
            guard let targetKey = keys.targetKey else {
                throw ControlError.noTargetKey(fan)
            }

            let clamped = clamp(rpm: rpm, minimum: minimum, maximum: maximum)
            if clamped != rpm {
                FanLog.write("fan \(fan) 目标转速 \(rpm) 被夹到 \(clamped)（min=\(minimum) max=\(maximum)）")
            }

            // 顺序不能颠倒：先模式后目标（SMC.md §2.6.1）。
            do {
                try writeManualMode(connection, keys: keys, manual: true)
                try writeTargetRPM(connection, key: targetKey, rpm: clamped)
            } catch {
                // 写失败立刻交回自动 —— 半途而废的手动模式比自动模式危险。
                FanLog.write("fan \(fan) 写失败（\(error)），立即交回系统自动控制")
                try? writeManualMode(connection, keys: keys, manual: false)
                throw error
            }

            // 写后读回校验。
            let readback = try readRPM(connection, key: targetKey)
            let actual = try readRPM(connection, key: keys.actualKey)
            try verify(targetKey: targetKey, expected: Double(clamped), actual: Double(readback))

            return SpeedResult(
                fan: fan,
                targetRPM: clamped,
                actualRPM: actual,
                readbackTargetRPM: readback,
                isManual: true,
                leaseSeconds: max(0, leaseSeconds))
        }

        // 记账：不管成功与否，先按实际下发的值更新状态。
        stateLock.lock()
        if result.isManual {
            manualFans.insert(fan)
            lastRequested[fan] = result.targetRPM
        } else {
            manualFans.remove(fan)
            lastRequested.removeValue(forKey: fan)
        }
        stateLock.unlock()

        if rpm > 0 {
            FanLeaseRegistry.shared.renew(fan: fan, seconds: leaseSeconds)
            let note = reason.map { "（\($0)）" } ?? ""
            FanLog.write("fan \(fan) 手动模式，目标 \(result.targetRPM) RPM，实际 \(result.actualRPM) RPM，租约 \(leaseSeconds)s\(note)")
        } else {
            FanLeaseRegistry.shared.cancel(fan: fan)
            FanLog.write("fan \(fan) 已交回系统自动控制")
        }
        return result
    }

    /// 所有风扇交回系统自动控制，并清空全部租约。
    ///
    /// 应用侧的正常路径。**90°C 兜底生效期间拒绝执行** —— 交回自动等于允许降速，
    /// 而兜底这一档压过任何规则。
    func releaseAll() throws {
        try FanDisclaimer.shared.requireAccepted()

        stateLock.lock()
        let currentEmergency = emergency
        stateLock.unlock()
        if currentEmergency.isEngaged {
            let maxCelsius = (try? SMCTemperatureIOHID().maxCelsius()) ?? 0
            throw ControlError.emergencyActive(maxCelsius: maxCelsius)
        }

        try releaseAll(reason: "应用请求")
    }

    /// 内部释放。**不**过免责声明门禁：租约到期、助手退出这些路径必须能收回控制权，
    /// 否则「没同意」会变成「风扇永远卡在手动模式」。
    ///
    /// - Parameter respectingEmergency: true = 紧急兜底期间不动（租约到期走这条）；
    ///   false = 强制释放（助手退出走这条，进程都要没了，留在手动模式更危险）。
    func releaseAll(reason: String, respectingEmergency: Bool = false) throws {
        stateLock.lock()
        let currentEmergency = emergency
        stateLock.unlock()

        if respectingEmergency && currentEmergency.isEngaged {
            FanLog.write("releaseAll（\(reason)）因 90°C 紧急兜底生效中被跳过")
            return
        }

        stateLock.lock()
        defer { stateLock.unlock() }

        let released = try withConnection { connection -> Int in
            let count = try fanCount(connection)
            guard count > 0 else { return 0 }
            var done = 0
            for index in 0..<count {
                let keys = try fanKeys(connection, index: index)
                do {
                    try writeManualMode(connection, keys: keys, manual: false)
                    done += 1
                } catch {
                    FanLog.write("fan \(index) 交回自动失败：\(error)")
                }
            }
            return done
        }

        manualFans.removeAll()
        lastRequested.removeAll()
        FanLeaseRegistry.shared.cancelAll()
        FanLog.write("releaseAll（\(reason)）：\(released) 个风扇交回系统自动控制")
    }

    /// 把目标转速夹到安全区间。
    ///
    /// 下限是 `minRPM * FanControl.minRpmSafetyRatio`（留 5% 余量，避免踩在
    /// SMC 拒绝执行的边界上）；上限是该风扇的最高转速。
    /// min/max 读不到（0）时不做夹取 —— 那说明 SMC 没给出有效值，夹了也是瞎夹。
    func clamp(rpm: Int, minimum: Int, maximum: Int) -> Int {
        var result = rpm
        if minimum > 0 {
            let floorValue = Int((Double(minimum) * FanControl.minRpmSafetyRatio).rounded(.down))
            result = max(result, floorValue)
        }
        if maximum > 0 {
            result = min(result, maximum)
        }
        return result
    }

    // MARK: - 紧急态判定

    /// 紧急兜底生效中，任何降速意图一律拒绝。
    ///
    /// 「降速」包括：交回系统（rpm = 0）、低于当前 maxRPM 的任何目标。
    /// 等值或更高（会被夹到 max）不算降速，放行 —— 应用可能也在按同一条规则拉满。
    private func rejectIfEmergencyDownSpeed(fan: Int, requestedRPM: Int) throws {
        stateLock.lock()
        let currentEmergency = emergency
        stateLock.unlock()
        guard currentEmergency.isEngaged else { return }

        let maxRPM = (try? readState().fans.first { $0.index == fan }?.maxRPM) ?? 0
        let maxCelsius = (try? SMCTemperatureIOHID().maxCelsius()) ?? 0

        if requestedRPM == 0 {
            throw ControlError.emergencyActive(maxCelsius: maxCelsius)
        }
        if maxRPM > 0 && requestedRPM < maxRPM {
            throw ControlError.emergencyActive(maxCelsius: maxCelsius)
        }
    }

    // MARK: - 模式读写

    /// 读某个风扇当前是否处于手动模式。
    private func readManualMode(_ connection: io_connect_t, keys: FanKeys) throws -> Bool {
        if let modeKey = keys.modeKey {
            guard let raw = try readValue(connection, key: modeKey) else { return false }
            return raw.bytes.first.map { $0 != 0 } ?? false
        }
        if keys.usesGlobalMode {
            guard let raw = try readValue(connection, key: Self.globalModeKey) else { return false }
            let mask = raw.bytes.count >= 2
                ? UInt16(raw.bytes[0]) | (UInt16(raw.bytes[1]) << 8)
                : 0
            return (mask & (1 << UInt16(keys.index))) != 0
        }
        return false
    }

    /// 写某个风扇的手动模式。
    ///
    /// 优先写每个风扇一个的模式键（F<n>Md / F<n>md，1 字节）；
    /// 只有全局位掩码键（FS! ，2 字节）时才改掩码，且保留其它风扇的位。
    private func writeManualMode(_ connection: io_connect_t, keys: FanKeys, manual: Bool) throws {
        if let modeKey = keys.modeKey {
            try writeValue(connection, key: modeKey, bytes: [manual ? 1 : 0])
            return
        }
        guard keys.usesGlobalMode else { throw ControlError.modeUnavailable }

        var mask: UInt16 = 0
        if let raw = try readValue(connection, key: Self.globalModeKey) {
            if raw.bytes.count >= 2 {
                mask = UInt16(raw.bytes[0]) | (UInt16(raw.bytes[1]) << 8)
            }
        }
        let bit = UInt16(1) << UInt16(keys.index)
        if manual {
            mask |= bit
        } else {
            mask &= ~bit
        }
        try writeValue(connection, key: Self.globalModeKey, bytes: [UInt8(mask & 0xFF), UInt8((mask >> 8) & 0xFF)])
    }

    /// 单风扇交回自动的便捷封装（内部用，不开新连接以外的东西）。
    private func writeManualMode(fan: Int, manual: Bool) throws {
        try withConnection { connection in
            let keys = try fanKeys(connection, index: fan)
            try writeManualMode(connection, keys: keys, manual: manual)
        }
    }

    // MARK: - 转速读写

    /// 写目标转速（按该键声明的长度选编码方式）。
    private func writeTargetRPM(_ connection: io_connect_t, key: String, rpm: Int) throws {
        guard let info = try keyInfo(connection, key: key) else {
            throw ControlError.keyMissing(key)
        }
        switch info.dataSize {
        case 4:
            try writeValue(connection, key: key, bytes: Self.encodeFloat32(Float(rpm)))
        case 2:
            try writeValue(connection, key: key, bytes: Self.encodeFixedRPM(rpm))
        default:
            throw ControlError.lengthMismatch(key: key, expected: Int(info.dataSize), actual: 4)
        }
    }

    /// 读一个转速键。读不到返回 0。
    private func readRPM(_ connection: io_connect_t, key: String?) throws -> Int {
        guard let key else { return 0 }
        guard let raw = try readValue(connection, key: key) else { return 0 }
        switch raw.dataSize {
        case 4:
            return Int(Self.decodeFloat32(raw.bytes))
        case 2:
            return Self.decodeFixedRPM(raw.bytes)
        case 1:
            return Int(raw.bytes.first ?? 0)
        default:
            return 0
        }
    }

    /// 写后校验。允许 2% 或 2 RPM 的量化误差。
    private func verify(targetKey: String, expected: Double, actual: Double) throws {
        let tolerance = max(2.0, abs(expected) * 0.02)
        guard abs(expected - actual) <= tolerance else {
            throw ControlError.verificationFailed(key: targetKey, expected: expected, actual: actual)
        }
    }

    // MARK: - 键探测

    /// 一个风扇用到的全部键（运行时探测的结果）。
    private struct FanKeys {
        let index: Int
        /// 每风扇一个的模式键（F0Md / F0md），没有则 nil。
        let modeKey: String?
        /// 是否走全局位掩码模式键（FS! ）。
        let usesGlobalMode: Bool
        /// 目标转速键（F0Tg，4 字节 float；老机型可能是 F0Sf，2 字节定点）。
        let targetKey: String?
        /// 实际转速键（F0Ac）。
        let actualKey: String?
        /// 最低转速键（F0Mn）。
        let minKey: String?
        /// 最高转速键（F0Mx）。
        let maxKey: String?
        /// 风扇名键（F0ID，16 字节）。
        let nameKey: String?
    }

    /// 风扇数量（FNum，1 字节）。
    private func fanCount(_ connection: io_connect_t) throws -> Int {
        guard let raw = try readValue(connection, key: "FNum") else { return 0 }
        return Int(raw.bytes.first ?? 0)
    }

    /// 探测某个风扇的键布局。全部靠 GetKeyInfo，不靠猜。
    private func fanKeys(_ connection: io_connect_t, index: Int) throws -> FanKeys {
        let prefix = "F\(index)"

        var modeKey: String?
        for candidate in ["\(prefix)Md", "\(prefix)md"] {
            if (try? keyInfo(connection, key: candidate)) != nil {
                modeKey = candidate
                break
            }
        }

        var usesGlobalMode = false
        if modeKey == nil {
            usesGlobalMode = (try? keyInfo(connection, key: Self.globalModeKey)) != nil
        }

        var targetKey: String?
        for candidate in ["\(prefix)Tg", "\(prefix)Sf"] {
            if (try? keyInfo(connection, key: candidate)) != nil {
                targetKey = candidate
                break
            }
        }

        return FanKeys(
            index: index,
            modeKey: modeKey,
            usesGlobalMode: usesGlobalMode,
            targetKey: targetKey,
            actualKey: "\(prefix)Ac",
            minKey: "\(prefix)Mn",
            maxKey: "\(prefix)Mx",
            nameKey: "\(prefix)ID")
    }

    /// 读风扇名。读不到 / 为空 → "Fan N"。
    private func readFanName(_ connection: io_connect_t, key: String?, index: Int) throws -> String {
        let fallback = "Fan \(index)"
        guard let key else { return fallback }
        guard let raw = try readValue(connection, key: key) else { return fallback }
        let bytes = raw.bytes.prefix(16)
        guard let text = String(bytes: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters)
            .trimmingCharacters(in: .whitespaces),
              !text.isEmpty else {
            return fallback
        }
        return text
    }

    // MARK: - SMC 底层

    /// 一个键的元信息。
    private struct KeyInfo {
        let dataType: String
        let dataSize: UInt32
    }

    /// 一个键读出来的原始值。
    private struct RawValue {
        let dataType: String
        let dataSize: UInt32
        let bytes: [UInt8]
    }

    /// 打开一次 SMC 连接，操作完就关。
    ///
    /// 用 `smcLock` 串行化：心跳线程与命令线程同时写 SMC 会互相踩连接。
    private let smcLock = NSRecursiveLock()

    private func withConnection<T>(_ body: (io_connect_t) throws -> T) throws -> T {
        smcLock.lock()
        defer { smcLock.unlock() }

        let connection = try openConnection()
        defer { if connection != 0 { IOServiceClose(connection) } }
        return try body(connection)
    }

    private func openConnection() throws -> io_connect_t {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            throw ControlError.connectionFailed("IOServiceGetMatchingService(\"AppleSMC\") 返回 0")
        }
        var connection: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        guard result == KERN_SUCCESS else {
            throw ControlError.connectionFailed("IOServiceOpen 返回 0x\(String(UInt32(bitPattern: result), radix: 16))")
        }
        return connection
    }

    /// 组一个请求帧。
    ///
    /// FourCC 按 SMC.md §2.4 字节反序存放（"#KEY" 在内存里是 59 45 4B 23）。
    private func makeFrame(command: Command, key: String?, dataSize: UInt32?, value: [UInt8]?) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: Offset.frameSize)

        if let key {
            let bytes = Array(key.utf8)
            precondition(bytes.count == 4, "SMC 键必须是 4 个字符：\(key)")
            for index in 0..<4 {
                frame[Offset.key + index] = bytes[3 - index]
            }
        }
        if let dataSize {
            frame[Offset.dataSize] = UInt8(dataSize & 0xFF)
            frame[Offset.dataSize + 1] = UInt8((dataSize >> 8) & 0xFF)
            frame[Offset.dataSize + 2] = UInt8((dataSize >> 16) & 0xFF)
            frame[Offset.dataSize + 3] = UInt8((dataSize >> 24) & 0xFF)
        }
        frame[Offset.command] = command.rawValue

        if let value {
            for index in 0..<min(value.count, Offset.valueSpan) {
                let target = index < 16 ? Offset.valueLow + index : Offset.valueHigh + (index - 16)
                frame[target] = value[index]
            }
        }
        return frame
    }

    /// 发一帧，回一帧。
    private func call(_ connection: io_connect_t, frame: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: Offset.frameSize)
        // IOConnectCallStructMethod 的计数参数在 Swift 里导入成 Int（size_t），
        // 不能用 UInt32 —— 编译器会直接拒。
        var outputSize = Offset.frameSize

        let result: Int32 = frame.withUnsafeBufferPointer { inputBuffer -> Int32 in
            output.withUnsafeMutableBufferPointer { outputBuffer -> Int32 in
                guard let inputAddress = inputBuffer.baseAddress,
                      let outputAddress = outputBuffer.baseAddress else { return -1 }
                return IOConnectCallStructMethod(
                    connection,
                    Self.methodID,
                    inputAddress,
                    Offset.frameSize,
                    outputAddress,
                    &outputSize)
            }
        }

        guard result == KERN_SUCCESS else {
            throw ControlError.connectionFailed("IOConnectCallStructMethod 返回 0x\(String(UInt32(bitPattern: result), radix: 16))")
        }
        return output
    }

    /// 判断回包是不是「键不存在」。
    ///
    /// 本机实测：状态字节（+0x28）= 0x84 表示键不存在；同时兼容某些固件把它放在
    /// 结果字节（+0x2C）的情况。
    private func isKeyMissing(_ output: [UInt8]) -> Bool {
        if output[Offset.status] == 0x84 { return true }
        if output[Offset.result] == 0x84 { return true }
        return false
    }

    /// 通用状态判定：0 = 成功。
    private func checkStatus(_ output: [UInt8], key: String) throws {
        guard output[Offset.status] == 0 else {
            throw ControlError.statusFailure(key: key, status: output[Offset.status])
        }
        if output[Offset.result] != 0 {
            throw ControlError.statusFailure(key: key, status: output[Offset.result])
        }
    }

    /// GetKeyInfo（命令 9）：拿 dataSize / dataType。键不存在返回 nil。
    private func keyInfo(_ connection: io_connect_t, key: String) throws -> KeyInfo? {
        let frame = makeFrame(command: .getKeyInfo, key: key, dataSize: nil, value: nil)
        let output = try call(connection, frame: frame)
        if isKeyMissing(output) { return nil }
        try checkStatus(output, key: key)

        let size = UInt32(output[Offset.dataSize])
            | (UInt32(output[Offset.dataSize + 1]) << 8)
            | (UInt32(output[Offset.dataSize + 2]) << 16)
            | (UInt32(output[Offset.dataSize + 3]) << 24)
        guard size > 0 else { return nil }

        // 类型串同样是字节反序存放（" tlf" → "flt "）。
        let typeBytes = (0..<4).map { output[Offset.dataType + $0] }
        let dataType = String(bytes: typeBytes.reversed(), encoding: .ascii) ?? ""

        return KeyInfo(dataType: dataType, dataSize: size)
    }

    /// 读一个键的值。键不存在返回 nil。
    ///
    /// 关键：命令 5 必须带上 dataSize，否则 SMC **不报错**、静默返回全 0。
    private func readValue(_ connection: io_connect_t, key: String) throws -> RawValue? {
        guard let info = try keyInfo(connection, key: key) else { return nil }
        guard info.dataSize > 0, info.dataSize <= UInt32(Offset.valueSpan) else { return nil }

        let frame = makeFrame(command: .readKey, key: key, dataSize: info.dataSize, value: nil)
        let output = try call(connection, frame: frame)
        if isKeyMissing(output) { return nil }
        try checkStatus(output, key: key)

        let bytes = Array(output[Offset.valueLow..<Offset.valueLow + Int(info.dataSize)])
        return RawValue(dataType: info.dataType, dataSize: info.dataSize, bytes: bytes)
    }

    /// 写一个键的值。
    ///
    /// 写入长度必须等于该键声明的 dataSize，否则 SMC 返 0xE00002BC —— 这里先查再写。
    private func writeValue(_ connection: io_connect_t, key: String, bytes: [UInt8]) throws {
        guard let info = try keyInfo(connection, key: key) else {
            throw ControlError.keyMissing(key)
        }
        guard Int(info.dataSize) == bytes.count else {
            throw ControlError.lengthMismatch(key: key, expected: Int(info.dataSize), actual: bytes.count)
        }

        let frame = makeFrame(command: .writeKey, key: key, dataSize: info.dataSize, value: bytes)
        let output = try call(connection, frame: frame)
        if isKeyMissing(output) { throw ControlError.keyMissing(key) }
        try checkStatus(output, key: key)
    }

    // MARK: - 数值编码

    /// 4 字节 float（小端）。
    static func encodeFloat32(_ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return [
            UInt8(bits & 0xFF),
            UInt8((bits >> 8) & 0xFF),
            UInt8((bits >> 16) & 0xFF),
            UInt8((bits >> 24) & 0xFF)
        ]
    }

    /// 4 字节 float 解码（小端）。
    static func decodeFloat32(_ bytes: [UInt8]) -> Float {
        guard bytes.count >= 4 else { return 0 }
        let bits = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        return Float(bitPattern: bits)
    }

    /// 2 字节定点 RPM（SMC.md §2.6.1）：
    /// 高位字节 = rpm >> 6，低位字节 = (rpm × 4) & 0xFF。
    static func encodeFixedRPM(_ rpm: Int) -> [UInt8] {
        let clamped = max(0, rpm)
        return [
            UInt8((clamped >> 6) & 0xFF),
            UInt8((clamped * 4) & 0xFF)
        ]
    }

    /// 2 字节定点 RPM 解码（encodeFixedRPM 的逆运算）：
    /// rpm = (b0 << 6) | (b1 >> 2)
    static func decodeFixedRPM(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= 2 else { return 0 }
        let high = Int(bytes[0])
        let low = Int(bytes[1])
        return (high << 6) | (low >> 2)
    }
}

// MARK: - 进程退出兜底

/// 助手退出时把风扇交回系统自动控制。
///
/// main.swift 里 shutdown() / uninstallSelf() 都会 exit(0)，atexit 钩子在这两条
/// 路径上都会跑，所以手动模式不会因为助手退出而留在机器上。
///
/// 注意：这里**不走**免责声明门禁（进程要退出了，留在手动模式比写一下危险得多），
/// 也**不因紧急兜底而跳过** —— 进程消失后没人能维持 maxRPM，交回自动至少让
/// 系统自己的温控接管。
private func deepSleepFanExitHook() {
    do {
        try SMCFanControl.shared.releaseAll(reason: "助手退出", respectingEmergency: false)
    } catch {
        FanLog.write("退出时交回风扇控制失败：\(error)")
    }
}

/// 助手启动钩子：创建单例 → 启动心跳与 90°C 监控。
///
/// 必须由入口显式调用。Swift 的全局 `let` 是惰性初始化的，光声明不会执行，
/// 所以这里给一个明确的函数，比依赖全局初始化可靠。
///
/// 幂等：重复调用只是再取一次单例。
enum FanControlBootstrap {
    static func start() {
        _ = SMCFanControl.shared
        atexit(deepSleepFanExitHook)

        let disclaimer = FanDisclaimer.shared.isAccepted
            ? "已同意（v\(FanDisclaimer.shared.acceptedVersion)）"
            : "未同意 —— 写风扇命令会被拒绝"
        FanLog.write("风扇控制已就绪：免责声明\(disclaimer)，心跳 \(FanControl.heartbeatSeconds)s，"
                     + "兜底阈值 \(FanControl.emergencyTemperatureCelsius)°C，"
                     + "冷却 \(FanControl.emergencyCooldownSeconds)s")

        if let state = try? SMCFanControl.shared.readState() {
            let summary = state.fans
                .map { "fan\($0.index) \($0.name) \($0.currentRPM)/\($0.minRPM)-\($0.maxRPM)\($0.isManual ? " 手动" : " 自动")" }
                .joined(separator: "; ")
            FanLog.write("启动探测：\(state.fans.count) 个风扇 · \(summary)")

            // 认领上一任助手 / 崩溃遗留的手动模式：不认领的话，90°C 兜底
            // 会因为「本实例没写过风扇、manualFans 为空」而完全不监控，
            // 等于把一台正卡在手动模式里的机器放任不管。
            //
            // 只在免责声明已同意时认领 —— 未同意说明不是我们写的，
            // 那些风扇归别的工具或系统管，不该由我们插手（也不该写 SMC）。
            if FanDisclaimer.shared.isAccepted {
                let manual = state.fans.filter(\.isManual).map(\.index)
                if !manual.isEmpty {
                    SMCFanControl.shared.adoptManualFans(manual, state: state)
                    FanLog.write("启动探测：认领 \(manual) 号风扇的手动模式，纳入 90°C 兜底监控")
                }
            }
        } else {
            FanLog.write("启动探测：本机读不到可写风扇（FNum 不存在或为 0）")
        }
    }
}
