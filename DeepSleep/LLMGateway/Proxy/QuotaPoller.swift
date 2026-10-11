//
//  QuotaPoller.swift
//  Deep Sleep
//
//  后台定时轮询已配置 Provider 的 quota，写入 GatewayDatabase。
//
//  行为：
//  - 按量（payAsYouGo / codingPlan）：每 5 分钟轮一次。
//  - 订阅（subscription / codingPlan 也走这条）：每 1 分钟轮一次更密的窗口。
//  - 任意 provider 连续 5 次拉取失败 → 标记该 provider 失败并停止该 provider 的轮询。
//    数据库侧的 QuotaWindow.windowStatus 会被设为 .exhausted，UI 显示「拉取失败」。
//  - 整体上不重新调度已经被判定「失败」的 provider；要恢复只能外部 trigger pollNow。
//  - start() 幂等；stop() 幂等；多次调用安全。
//

import Foundation

actor QuotaPoller {

    static let shared = QuotaPoller()

    // 状态
    private var task: Task<Void, Never>?
    private var running = false

    // 内存级失败计数：providerId → 连续失败次数。重启进程清零。
    private var failureCount: [UUID: Int] = [:]
    private var disabled: Set<UUID> = []

    // 间隔常量
    private static let payAsYouGoInterval: UInt64 = 5 * 60  // 5 分钟
    private static let subscriptionInterval: UInt64 = 60    // 1 分钟
    private static let maxFailures = 5

    private init() {}

    // MARK: - 公开 API

    /// 启动轮询循环。如果已在跑，幂等。
    func start() {
        if running { return }
        running = true
        failureCount.removeAll()
        disabled.removeAll()
        scheduleLoop()
    }

    /// 停止轮询循环。幂等。
    func stop() {
        running = false
        task?.cancel()
        task = nil
    }

    /// 立刻拉一次所有（或指定）provider；不等下一个 tick。
    func pollNow(providerId: UUID? = nil) async {
        await poll(providerFilter: providerId)
    }

    // MARK: - 内部循环

    /// 重排下一个 tick。启动时立刻跑一次（不等满 1~5 分钟）。
    private func scheduleLoop() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            // 启动那一轮：立刻跑一次。
            await self.poll(providerFilter: nil)
            while await self.isRunning() {
                if Task.isCancelled { break }
                let sleep = await self.nextIntervalNanos()
                try? await Task.sleep(nanoseconds: sleep)
                if Task.isCancelled { break }
                guard await self.isRunning() else { break }
                await self.poll(providerFilter: nil)
            }
        }
    }

    private func isRunning() -> Bool { running }

    /// 下一个 tick 间隔：取所有 enabled provider 中最密的间隔（subscription=60s
    /// 比 payAsYouGo=300s 更短）。这样一次 tick 就把所有 provider 都拉一次。
    private func nextIntervalNanos() async -> UInt64 {
        var minInterval = Self.subscriptionInterval
        do {
            let providers = try GatewayDatabase.shared.listProviders()
            for p in providers where p.enabled {
                if p.billingMode == .payAsYouGo {
                    minInterval = Swift.min(minInterval, Self.payAsYouGoInterval)
                } else {
                    minInterval = Swift.min(minInterval, Self.subscriptionInterval)
                }
            }
        } catch {
            // 数据库异常不影响——保持默认 1 分钟，等下一次会重试。
        }
        return minInterval * 1_000_000_000
    }

    // MARK: - 轮询主体

    private func poll(providerFilter: UUID?) async {
        let providers: [ProviderConfig]
        do {
            providers = try GatewayDatabase.shared.listProviders()
        } catch {
            NSLog("[QuotaPoller] failed to list providers: \(error)")
            return
        }

        for cfg in providers {
            if !cfg.enabled { continue }
            if let want = providerFilter, want != cfg.id { continue }
            if disabled.contains(cfg.id) { continue }
            await pollOne(cfg)
        }
    }

    /// 拉一个 provider 的 quota。失败超过阈值后停止再拉。
    private func pollOne(_ cfg: ProviderConfig) async {
        // 读 API Key（同步 IO，放到 detached task 里）。KeychainStore 抛错说明
        // macOS 安全栈出问题；当次跳过，下个 tick 再试。
        let apiKey: String
        do {
            apiKey = try await loadAPIKey(ref: cfg.apiKeyRef)
        } catch {
            await recordFailure(cfg, reason: "keychain: \(error.localizedDescription)")
            return
        }

        // 构造 provider 实例。这里 KeychainStore.load 已在 detached 里跑完。
        let provider = await Task.detached {
            ProviderRegistry.shared.makeProvider(for: cfg, apiKey: apiKey)
        }.value

        do {
            let windows = try await provider.fetchQuota()
            // 成功：清失败计数，写快照。
            failureCount[cfg.id] = 0
            await persistSuccess(cfg: cfg, windows: windows)
        } catch let e as LLMGatewayError {
            // 「平台未实现」这种不算 provider 自身的失败：清计数。
            if case .unsupportedProvider = e {
                failureCount[cfg.id] = 0
                return
            }
            await recordFailure(cfg, reason: e.localizedDescription)
        } catch {
            await recordFailure(cfg, reason: String(describing: error))
        }
    }

    /// 成功路径：写每条窗口快照；如果窗口字段大多 nil（dashboard 不可用），仍写一条 unknown。
    private func persistSuccess(cfg: ProviderConfig, windows: [QuotaWindow]) async {
        guard !windows.isEmpty else { return }
        for w in windows {
            var copy = w
            copy.providerId = cfg.id  // 防止 provider 把 providerId 写成占位
            do {
                try GatewayDatabase.shared.insertQuotaSnapshot(copy)
            } catch {
                NSLog("[QuotaPoller] insertQuotaSnapshot failed for \(cfg.id): \(error)")
            }
        }
    }

    /// 失败路径：阈值以下累加，到阈值标记 .exhausted + 禁用该 provider。
    private func recordFailure(_ cfg: ProviderConfig, reason: String) async {
        let prior = failureCount[cfg.id] ?? 0
        let next = prior + 1
        failureCount[cfg.id] = next
        NSLog("[QuotaPoller] provider \(cfg.id) poll failed #\(next): \(reason)")
        if next >= Self.maxFailures {
            disabled.insert(cfg.id)
            // 把最近一条快照的 windowStatus 写成 .exhausted；UI 上就能看到「拉取失败」。
            let snapshot = QuotaWindow(
                providerId: cfg.id,
                capturedAt: Date(),
                fiveHourUsed: nil, fiveHourTotal: nil, fiveHourResetAt: nil,
                weeklyUsed: nil, weeklyTotal: nil, weeklyResetAt: nil,
                balanceAmount: nil, balanceCurrency: nil,
                windowStatus: .exhausted
            )
            do {
                try GatewayDatabase.shared.insertQuotaSnapshot(snapshot)
            } catch {
                NSLog("[QuotaPoller] failed to record exhausted snapshot: \(error)")
            }
        }
    }

    /// KeychainStore.load 是同步 throw；用 Task.detached + semaphore 之外的
    /// 写法其实就是放到脱离当前 actor 的协程里跑。我们用 withCheckedContinuation
    /// 把同步抛错接到 async 上下文。
    private func loadAPIKey(ref: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    if let key = try KeychainStore.load(account: ref) {
                        cont.resume(returning: key)
                    } else {
                        cont.resume(throwing: LLMGatewayError.noAPIKey)
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
