//
//  KeepAliveEngine.swift
//  Deep Sleep
//
//  AI 保活的调度器：每 15 秒评估一次，到点就发一条超短请求。
//
//  做法照抄 ScheduledCommand（`Core/ScheduledCommand.swift`）：
//  - `@MainActor` 单例；
//  - `Timer(timeInterval:repeats:)` 挂在 `RunLoop.main` 的 `.common` 模式；
//  - tick 里评估每个启用任务是否到点。
//
//  与定时命令的区别：
//  - 定时命令用 cron（要匹配「分 时 日 月 周」）；保活只要「每隔 N 分钟」，
//    cron 在这里是过度设计，而且用 cron 表达不了「每 4 小时一次」的干净语义。
//  - 锚点是「上次发送时间」，没有就用「创建时间」—— 新建的任务不会立刻发一条。
//
//  安全约定：日志里只出现任务名、端点、结果摘要，**绝不出现 API Key**。
//
//  退出行为：Deep Sleep 退出后保活就停了（与定时命令、监控一致）。
//  「保留退出态」分支下同样会 stop —— 进程要退了，留个 Timer 没意义，
//  而且留着会让用户以为退出后还在保活。
//

import Foundation
import Combine

@MainActor
final class KeepAliveEngine: ObservableObject {

    static let shared = KeepAliveEngine()

    private init() {}

    /// 评估周期（秒）。15 秒是为了让「1 分钟间隔」这种短间隔不至于误差过半。
    private static let tickInterval: TimeInterval = 15

    /// 全部任务。UI 直接观察这个数组。
    @Published private(set) var tasks: [KeepAliveTask] = []

    /// 是否在跑。
    @Published private(set) var isRunning = false

    /// 引擎状态。工具箱页的状态徽章只依赖这一个入口。
    enum Status {
        /// 调度器在跑。
        case running
        /// 调度器停了（引擎被显式 stop）。
        case paused
        /// 还没有任何任务。
        case notConfigured
        /// 引擎不可用（依赖没就绪等）。
        case unavailable(String)
    }

    /// 当前状态。派生属性 —— 不额外 @Published，避免两处状态打架。
    var status: Status {
        guard isRunning else {
            // 引擎没在跑 —— 调度器停了（应用退出过，或被显式 stop）。
            return .paused
        }
        // 引擎在跑但一个任务都没有：说「运行中」对用户没有意义，
        // 他真正想知道的是「还没配任何东西」。
        return tasks.isEmpty ? .notConfigured : .running
    }

    private var timer: Timer?

    /// 正在发送中的任务 id。防止同一个任务因为 tick 抖动被并发触发两次。
    private var inFlight: Set<UUID> = []

    /// 连续失败次数（按任务 id 记）。用于退避。
    ///
    /// 失败后不推进 `lastRunAt`（见 `finish`），意味着下一个 tick 就会重试。
    /// 服务端临时不可用时这样能自愈，但 API Key 填错时会每 15 秒刷一次屏。
    /// 退避把重试间隔拉开：1 次失败等 1 分钟，2 次 5 分钟，3 次 15 分钟，
    /// 4 次及以上 30 分钟（不超过用户自己配的间隔）。
    private var consecutiveFailures: [UUID: Int] = [:]

    /// 最近一次失败的时刻（按任务 id 记）。
    ///
    /// 冷却期要相对**失败发生的时刻**算，不能相对「现在」算 ——
    /// 每次 tick 都拿当前时间当基准的话，冷却期会一直往后滑，永远等不到。
    private var lastFailureAt: [UUID: Date] = [:]

    /// 退避阶梯（秒）。最后一个是上限。
    private static let backoffSeconds: [TimeInterval] = [60, 300, 900, 1800]

    // MARK: - 生命周期

    func start() {
        reload()
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        isRunning = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    /// 从磁盘重新读一遍任务。
    func reload() {
        tasks = KeepAliveStore.load()
    }

    // MARK: - 配置

    /// 插入或更新一条任务。返回落盘后的列表。
    @discardableResult
    func upsert(_ task: KeepAliveTask) -> [KeepAliveTask] {
        tasks = KeepAliveStore.upsert(task)
        return tasks
    }

    /// 删除一条任务，并顺手删掉它的 Keychain 条目。
    @discardableResult
    func remove(id: UUID) -> [KeepAliveTask] {
        // 先取旧值：要删的 Keychain account 名存在旧任务里，
        // 删完任务就再也拿不到了。
        let oldAccount = tasks.first(where: { $0.id == id })?.apiKeyRef
        tasks = KeepAliveStore.remove(id: id)
        // Keychain 里那条也删掉，否则会留下孤儿凭据。
        let account = (oldAccount?.isEmpty == false ? oldAccount : nil)
            ?? KeepAliveStore.keychainAccount(for: id)
        try? KeychainStore.delete(account: account)
        // 退避状态跟着任务一起清掉，别留孤儿条目。
        consecutiveFailures[id] = nil
        lastFailureAt[id] = nil
        return tasks
    }

    /// 把某条任务的请求内容恢复成默认模板。
    @discardableResult
    func restoreDefaultTemplate(id: UUID) -> [KeepAliveTask] {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return tasks }
        tasks[idx].requestTemplate = KeepAliveDefaults.defaultRequestTemplate
        return upsert(tasks[idx])
    }

    /// 切换启用状态。
    @discardableResult
    func setEnabled(_ id: UUID, _ enabled: Bool) -> [KeepAliveTask] {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return tasks }
        tasks[idx].isEnabled = enabled
        return upsert(tasks[idx])
    }

    // MARK: - 执行

    /// 立即发一次（不等间隔）。UI 上的「立即发送」按钮用。
    ///
    /// 也要过 `inFlight` 这道门：手动连点两次「立即发送」，或者手动发送的
    /// 同时定时 tick 命中，同一个任务会被并发发两次 —— 白白多消耗一次额度，
    /// 而且两次的 `defer { inFlight.remove }` 会把对方的标记提前清掉，
    /// 让退避计数算错。`send()` 里的 `inFlight.insert` 是 Set 的幂等插入，
    /// 光靠它挡不住并发。
    func triggerNow(id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        guard !inFlight.contains(task.id) else { return }
        send(task, reason: "手动触发")
    }

    /// tick：评估哪些任务到点了。
    private func tick() {
        let now = Date()
        for task in tasks where task.isEnabled {
            guard !inFlight.contains(task.id) else { continue }
            guard now >= task.nextDueDate() else { continue }
            // 退避：连续失败的任务要等够冷却时间才重试。
            guard now >= nextRetryAllowedDate(for: task) else { continue }
            send(task, reason: "定时")
        }
    }

    /// 退避冷却期结束的时刻。没有失败记录时返回过去（= 允许立刻重试）。
    private func nextRetryAllowedDate(for task: KeepAliveTask) -> Date {
        guard let failures = consecutiveFailures[task.id], failures > 0,
              let failedAt = lastFailureAt[task.id] else {
            return Date(timeIntervalSince1970: 0)
        }
        let index = min(failures, Self.backoffSeconds.count) - 1
        let cooldown = Self.backoffSeconds[index]
        // 冷却上限不超过用户自己配的间隔 —— 用户配 5 分钟保活，
        // 不应该因为退避而 30 分钟才重试一次。
        let cap = TimeInterval(KeepAliveTask.clampedInterval(task.intervalMinutes) * 60)
        return failedAt.addingTimeInterval(min(cooldown, cap))
    }

    /// 发一条保活请求。失败只写日志，不抛错。
    private func send(_ task: KeepAliveTask, reason: String) {
        inFlight.insert(task.id)
        let account = task.apiKeyRef.isEmpty
            ? KeepAliveStore.keychainAccount(for: task.id)
            : task.apiKeyRef
        let taskID = task.id
        let taskName = task.name.isEmpty ? task.model : task.name

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove(taskID) }

            let apiKey: String
            do {
                let loaded = try await KeepAliveStore.readAPIKey(account: account)
                apiKey = loaded ?? ""
            } catch {
                self.finish(
                    taskID: taskID,
                    success: false,
                    summary: "读取 API Key 失败：\(error.localizedDescription)"
                )
                SleepController.shared.appendLog(
                    "保活任务「\(taskName)」读取 API Key 失败", isError: true
                )
                return
            }

            let result = await KeepAliveClient.send(task, apiKey: apiKey)
            self.finish(taskID: taskID, success: result.succeeded, summary: result.summary)

            if result.succeeded {
                SleepController.shared.appendLog(
                    "保活任务「\(taskName)」已发送（\(reason)）"
                )
            } else {
                SleepController.shared.appendLog(
                    "保活任务「\(taskName)」失败：\(result.summary)", isError: true
                )
            }
        }
    }

    /// 把结果写回任务状态并落盘。
    ///
    /// 锚点的推进规则：**只有成功才推进 `lastRunAt`**。
    ///
    /// 失败时如果也把 `lastRunAt` 推到当前时间，下次到期时间就是
    /// 「失败时刻 + 间隔」—— 用户配 240 分钟、失败一次就变成 480 分钟才重试，
    /// 而失败最该做的事恰恰是尽快重试。失败时保留原锚点，
    /// 下一个 tick（15 秒后）就会再试一次。
    ///
    /// 代价是：服务端持续失败时，任务会每 15 秒重试一次。
    /// 这是刻意选的 —— 保活的失败多半是网络抖动或服务端临时不可用，
    /// 快速重试能自愈；而持续失败会在日志里留下记录，用户看得见。
    /// 真的需要限流的话，用户可以关掉这个任务的启用开关。
    private func finish(taskID: UUID, success: Bool, summary: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        if success {
            tasks[idx].lastRunAt = Date()
            tasks[idx].lastResult = summary
            // 成功一次就把退避清零 —— 之前的失败不该继续拖累后面的重试。
            consecutiveFailures[taskID] = nil
            lastFailureAt[taskID] = nil
        } else {
            tasks[idx].lastResult = "失败：\(summary)"
            let count = (consecutiveFailures[taskID] ?? 0) + 1
            consecutiveFailures[taskID] = count
            lastFailureAt[taskID] = Date()
        }
        // 写回时不能把正在编辑的字段覆盖掉 —— 这里直接落盘当前内存里的整条。
        KeepAliveStore.save(tasks)
    }
}
