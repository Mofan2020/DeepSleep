//
//  ProcessStatsProvider.swift
//  Deep Sleep
//
//  应用侧调用「抓进程快照 / 冻结进程 / 杀掉进程」的统一入口。
//
//  为什么单独一层而不是直接用 HelperClient：
//    1. 协议版本门禁：监控三个新命令是 v2 才有的。旧助手（v=1）收到会回
//       `unknown command`，应用侧必须先探测协议再决定能不能发命令，
//       否则日志里会一直出现假错误。
//    2. 协议编解码集中在 Shared/，但应用侧的 proc-* 函数要做的额外事情是
//       「把 pids 转成逗号串」「把 payload 解码成 ProcessStats」。
//    3. 给系统监控（SystemMonitor）一个不依赖 HelperClient 内部细节的
//       薄接口 —— 监控只需要 `fetchStats / suspend / kill` 三个方法。
//

import Foundation

enum ProcessStatsProviderError: LocalizedError {
    /// 助手还在跑，但版本太老不认识监控命令。需要触发 updateSelf。
    case outdatedHelper
    /// 助手根本没在跑 / 没安装。
    case helperUnavailable(String)
    /// 助手版本够新，但不识别这条命令（例如旧版 v2 没 `getCPUTemperature`）。
    /// 与 `outdatedHelper` 不同:这条不需要整体升级助手,只是「这个能力没启用」,
    /// 调用方应**静默降级**,不要弹错误。
    case unsupportedHelper

    var errorDescription: String? {
        switch self {
        case .outdatedHelper:
            return "完全控制中的助手版本太旧，不支持系统监控相关命令。请在「完全控制」页重新启用以更新助手。"
        case .helperUnavailable(let detail):
            return "特权助手不可用：\(detail)"
        case .unsupportedHelper:
            return "助手版本不支持该能力。"
        }
    }
}

final class ProcessStatsProvider {

    static let shared = ProcessStatsProvider()

    /// 协议版本门禁。监控新命令需要 v2。
    private var hasConfirmedV2 = false
    /// 助手是否支持 `getCPUTemperature`。旧助手（v=2 但发布早于该命令）没有。
    /// **注意**：我们用协议版本号做不到这点（v2 协议里加命令是兼容的），
    /// 所以每次 fetchCPUTemperature 失败时**用「未知命令」识别能力缺失**，
    /// 第一次成功后置 true，之后缓存。
    private var helperSupportsCPUTemperature = false

    /// 抓一份进程快照。会自动校验助手协议版本。
    ///
    /// 返回整个 `ProcessStats`（含整机 CPU 占用），不只是记录数组 ——
    /// 整机占用不是各进程 CPU% 的和，得单独拿。
    ///
    /// **同一时刻只发一个请求。** 见 `StatsGate` 的说明。
    func fetchStats() async throws -> ProcessStats {
        try await ensureV2()
        // 闭包里不需要捕获 self（用的是 `HelperClient.shared` 这个单例），
        // 所以不写 `[weak self]` —— 写了反而多一条 "value 'self' was defined
        // but never used" 的警告。
        return try await StatsGate.shared.stats {
            let request = HelperRequest(command: .getProcessStats)
            let response = try await HelperClient.shared.send(request, timeout: 6)
            guard response.success else {
                throw ProcessStatsProviderError.helperUnavailable(response.message)
            }
            return ProcessStats.decode(response.payload)
        }
    }

    /// 抓一次 CPU 温度读数。助手必须支持 `getCPUTemperature`（v1.4.2+）。
    /// 旧助手会回「unknown command」类失败 → 抛 `unsupportedHelper`,
    /// 调用方应当**静默降级**(不弹错误),不是故障。
    func fetchCPUTemperature() async throws -> CPUTemperatureSample {
        try await ensureV2()
        if !helperSupportsCPUTemperature {
            // 探测阶段已完成 v2 协议校验。但「是否带 getCPUTemperature 命令」
            // 还要看助手是否含此命令 —— 用一次失败/成功识别。
        }
        let request = HelperRequest(command: .getCPUTemperature)
        let response = try await HelperClient.shared.send(request, timeout: 4)
        guard response.success else {
            // 旧助手收到未识别命令会回「unknown command」(英文),
            // 我们以这个关键字判定「助手没有这个能力」。
            if response.message.localizedCaseInsensitiveContains("unknown command") {
                throw ProcessStatsProviderError.unsupportedHelper
            }
            throw ProcessStatsProviderError.helperUnavailable(response.message)
        }
        helperSupportsCPUTemperature = true
        return CPUTemperatureSample.decode(response.payload)
    }

    /// 挂起（SIGSTOP）一组 pid。结果里 `killed` 表示「已挂起」，
    /// `refused` 表示命中保护名单，`failed` 表示 errno 失败。
    func suspend(_ pids: [pid_t]) async throws -> TerminationReport {
        try await ensureV2()
        let request = HelperRequest(command: .suspendProcesses, arguments: [
            "pids": encodePids(pids)
        ])
        let response = try await HelperClient.shared.send(request, timeout: 8)
        guard response.success else {
            throw ProcessStatsProviderError.helperUnavailable(response.message)
        }
        return TerminationReport.decode(response.payload)
    }

    /// 杀掉（SIGKILL）一组 pid。
    func kill(_ pids: [pid_t]) async throws -> TerminationReport {
        try await ensureV2()
        let request = HelperRequest(command: .killProcesses, arguments: [
            "pids": encodePids(pids)
        ])
        let response = try await HelperClient.shared.send(request, timeout: 8)
        guard response.success else {
            throw ProcessStatsProviderError.helperUnavailable(response.message)
        }
        return TerminationReport.decode(response.payload)
    }

    /// 重置协议版本缓存（例如「更新助手」按钮点了之后调一次）。
    func resetVersionCache() {
        hasConfirmedV2 = false
    }

    // MARK: - 内部

    private func ensureV2() async throws {
        if hasConfirmedV2 { return }
        let probe = await HelperClient.shared.probe()
        guard probe.reachable else {
            throw ProcessStatsProviderError.helperUnavailable(probe.detail)
        }
        guard let version = probe.protocolVersion, version >= HelperConstants.protocolVersion else {
            throw ProcessStatsProviderError.outdatedHelper
        }
        hasConfirmedV2 = true
    }

    private func encodePids(_ pids: [pid_t]) -> String {
        pids.map(String.init).joined(separator: ",")
    }
}


/// 进程快照的「在途去重 + 短缓存」。
///
/// 为什么需要这一层：App 里有好几处都要进程快照 —— 系统监控的定时采样、
/// 监控页自己的刷新、进程优先级页。它们各自发一次请求，助手那边就排起长队：
/// 一次快照要 3~5 秒，而默认采样间隔只有 3 秒，**请求速率高于服务速率**。
/// 队列越滚越长，每个请求都在客户端 6 秒超时 → 界面上的数值永远不刷新，
/// 客户端这边每个请求还占着一个线程等超时 → 整个 App 变得极慢、点什么都像
/// 没反应。
///
/// 这里做两件事：
///  1. **在途去重**：同一时刻只有一个请求在飞，后来者 await 同一个 Task
///     （Task 是引用语义，只执行一次），拿到同一份结果。
///  2. **短 TTL 缓存**：1.5 秒内的请求直接复用上一份，不打扰助手。
///     这个间隔与助手侧的「最小扫描间隔」（2 秒）对齐 —— 助手本来也会复用，
///     这里只是省掉一次来回。
private actor StatsGate {

    static let shared = StatsGate()

    /// 缓存有效期（秒）。
    static let ttl: TimeInterval = 1.5

    /// 正在飞的那个请求。后来者 await 它，不新发。
    private var inFlight: Task<ProcessStats, Error>?
    /// 刚拿到的结果。
    private var cached: (value: ProcessStats, at: Date)?

    func stats(_ operation: @escaping @Sendable () async throws -> ProcessStats) async throws -> ProcessStats {
        if let cached, Date().timeIntervalSince(cached.at) < Self.ttl {
            return cached.value
        }
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await operation() }
        inFlight = task
        do {
            let value = try await task.value
            cached = (value, Date())
            inFlight = nil
            return value
        } catch {
            inFlight = nil
            throw error
        }
    }
}
