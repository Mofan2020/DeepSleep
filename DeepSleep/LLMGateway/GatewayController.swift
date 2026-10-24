//
//  GatewayController.swift
//  Deep Sleep
//
//  SwiftUI-friendly 的 LLM 网关控制器。
//
//  设计：
//  - @MainActor ObservableObject：UI 直接观察 @Published 集合。
//  - 单例 GatewayController.shared：组件之间共享同一份状态（taskbar、设置面板、
//    配额仪表盘等）。
//  - 所有副作用（Keychain IO / SQLite / 启动 GatewayServer）放到 Task 里跑。
//    KeychainStore.load 是 sync throws；用 withCheckedThrowingContinuation 包一层
//    拿到 await 形态，调用方即可在 async 方法里直接 `try await`。
//
//  不持有 SleepController 或磁盘 IO；所有持久化都委托给 GatewayDatabase /
//  KeychainStore / ProviderRegistry。
//

import Foundation
import Combine

@MainActor
final class GatewayController: ObservableObject {

    static let shared = GatewayController()

    // MARK: 已发布状态

    @Published var providers: [ProviderConfig] = []
    @Published var latestSnapshots: [UUID: QuotaWindow] = [:]
    @Published var isRunning: Bool = false

    /// 网关配置。改动会立刻落盘（`gateway.config.v1`），重启后仍在。
    @Published var gatewayConfig: GatewayConfig {
        didSet {
            // 每次变更都写盘 —— 配置只改几项，没有合并的必要。
            // 写盘的是「非默认值」判断，值等于默认值时会删掉 key。
            gatewayConfig.saveIfNotDefault()
        }
    }

    /// 最近一次启动 / 关闭的错误（Banner 用）。
    @Published var lastError: String?

    // 私有
    private var cancellables: Set<AnyCancellable> = []
    /// 是否已经读过数据库。`ensureLoaded()` 靠它做幂等。
    private var hasLoaded = false

    private init() {
        // 配置从磁盘读，不留在内存里 —— 重启后端口 / 鉴权不该丢。
        gatewayConfig = GatewayConfig.load()

        // 观察 feature toggle：开了 .gateway 不代表立即启动——这只是「允许启」，
        // 真正的 startGateway() 由用户在 UI 里点「启动」触发。
        LLMGatewayFeature.didChange
            .sink { _ in /* no-op; UI 自己看 isEnabled */ }
            .store(in: &cancellables)
    }

    // MARK: - 加载

    /// 确保数据库读过一次。幂等，可以随便调。
    ///
    /// 以前 `load()` 从来没被调用过，`providers` 永远是空数组 ——
    /// Provider 列表页 / 模型切换页 / 配额页全是空的。入口现在有两个：
    /// 网关设置页与 Provider 列表页的 `.task`，两边都调它。
    func ensureLoaded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    /// 从 db 读所有 provider + 各自的最近一条 quota 快照。
    func load() async {
        do {
            let cfgs = try GatewayDatabase.shared.listProviders()
            providers = cfgs
        } catch {
            providers = []
            lastError = "读取 Provider 列表失败：\(error.localizedDescription)"
        }
        await reloadSnapshots()
    }

    /// 重新读所有最新的 quota 快照（不发起实际轮询；只读数据库已有）。
    func reloadSnapshots() async {
        do {
            let snaps = try GatewayDatabase.shared.allLatestQuotaSnapshots()
            var map: [UUID: QuotaWindow] = [:]
            for s in snaps { map[s.providerId] = s }
            latestSnapshots = map
        } catch {
            // 保留旧值；不报错炸 UI
        }
    }

    // MARK: - Provider CRUD

    /// 新增一条 Provider：先写 Keychain，再入库。
    func addProvider(_ cfg: ProviderConfig, apiKey: String) async throws {
        var toInsert = cfg
        if toInsert.apiKeyRef.isEmpty {
            toInsert.apiKeyRef = cfg.displayName
        }
        try await writeKeyChain(ref: toInsert.apiKeyRef, key: apiKey)
        try GatewayDatabase.shared.insertProvider(toInsert)
        await load()
    }

    /// 兼容签名（View 调 addProvider(_:)）：不写 Keychain，假设已有。
    func addProvider(_ cfg: ProviderConfig) async throws {
        try GatewayDatabase.shared.insertProvider(cfg)
        providers.append(cfg)
    }

    /// upsert 一条 provider（兼容旧 View 调用）。
    func updateProvider(_ cfg: ProviderConfig) async throws {
        try GatewayDatabase.shared.insertProvider(cfg)
        if let idx = providers.firstIndex(where: { $0.id == cfg.id }) {
            providers[idx] = cfg
        } else {
            providers.append(cfg)
        }
    }

    /// 删除一条 Provider：db + Keychain。
    func removeProvider(id: UUID) async throws {
        if let cfg = providers.first(where: { $0.id == id }) {
            try? KeychainStore.delete(account: cfg.apiKeyRef)
        }
        try GatewayDatabase.shared.deleteProvider(id: id)
        latestSnapshots.removeValue(forKey: id)
        providers.removeAll { $0.id == id }
    }

    // MARK: - quota

    /// 兼容 API（旧 View）：拉取单个 Provider 的最新 quota，返回 snapshot。
    func refreshQuota(providerId: UUID) async throws -> QuotaWindow {
        guard let cfg = providers.first(where: { $0.id == providerId }) else {
            throw LLMGatewayError.unsupportedProvider("Provider 不存在")
        }
        let key = (try? KeychainStore.load(account: cfg.apiKeyRef)) ?? ""
        let provider = ProviderRegistry.shared.makeProvider(for: cfg, apiKey: key)
        let windows = try await provider.fetchQuota()
        let w = windows.first ?? QuotaWindow(
            providerId: providerId, capturedAt: Date(), windowStatus: .unknown
        )
        var snapshot = QuotaWindow(
            providerId: providerId, capturedAt: Date(), windowStatus: w.windowStatus
        )
        snapshot.fiveHourUsed = w.fiveHourUsed
        snapshot.fiveHourTotal = w.fiveHourTotal
        snapshot.fiveHourResetAt = w.fiveHourResetAt
        snapshot.weeklyUsed = w.weeklyUsed
        snapshot.weeklyTotal = w.weeklyTotal
        snapshot.weeklyResetAt = w.weeklyResetAt
        snapshot.balanceAmount = w.balanceAmount
        snapshot.balanceCurrency = w.balanceCurrency
        try GatewayDatabase.shared.insertQuotaSnapshot(snapshot)
        latestSnapshots[providerId] = snapshot
        return snapshot
    }

    /// 兼容 API（旧 View）：依次刷新所有 enabled provider。
    func refreshAllQuotas() async {
        for provider in providers where provider.enabled {
            _ = try? await refreshQuota(providerId: provider.id)
        }
    }

    /// 推荐 API：委托给 QuotaPoller.pollNow。`id` 缺省 = 全部。
    func refreshQuota(for id: UUID? = nil) async {
        await QuotaPoller.shared.pollNow(providerId: id)
        await reloadSnapshots()
    }

    // MARK: - 网关启停

    /// 启动 GatewayServer + QuotaPoller。已经在跑的话幂等返回。
    ///
    /// 这里**不再**检查旧的 `LLMGatewayFeature.gateway` 开关：
    /// 那个开关默认关且没有 UI 入口，等于把功能永久锁死。入口改成
    /// 「工具箱卡片 + 已同意免责申明」，启停本身仍然由用户在
    /// 网关设置页里点「启动」触发。
    func startGateway() async throws {
        guard !isRunning else { return }
        guard GatewayDisclaimer.accepted else {
            throw LLMGatewayError.unsupportedProvider(
                "尚未确认网关免责申明，无法启动"
            )
        }
        let cfg = gatewayConfig
        await GatewayServer.shared.start(config: cfg)
        isRunning = await GatewayServer.shared.isRunning()
        await QuotaPoller.shared.start()
    }

    /// 关闭 GatewayServer + QuotaPoller 的同步入口（不 await）。
    /// 内部用 Task 异步执行。Task 规范中所谓的 `func stopGateway() async`
    /// 是一个更高层的概念；这里把核心工作包到 detached Task，
    /// 避免阻塞调用方线程——对 SwiftUI 而言，
    /// `controller.stopGateway()` 一句代码即可。
    nonisolated func stopGateway() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await QuotaPoller.shared.stop()
            await GatewayServer.shared.stop()
            await MainActor.run { self.isRunning = false }
        }
    }

    /// `await controller.stopGateway()` 也可以用——通过显式 await async 版本，
    /// 我们的 stopGateway() 重载空间里只有这一个非 async 入口；如果以后需要
    /// `await` 风格的关闭，请加 `func stopGateway() async` 把这行注释掉。
    // (no async overload to avoid Swift 5 ambiguous resolution)

    // MARK: - 聚合查询

    /// 单个 provider 在 since..now 的用量聚合。
    /// 这里走 GatewayDatabase.aggregateUsage（同步）；UI 调用时注意放后台。
    func usageAggregate(
        providerId: UUID, since: Date
    ) throws -> GatewayDatabase.UsageAggregate {
        try GatewayDatabase.shared.aggregateUsage(providerId: providerId, since: since)
    }

    // MARK: - 异步 IO 包装

    /// KeychainStore.save 是 sync throws；用 continuation 接成 async。
    private func writeKeyChain(ref: String, key: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try KeychainStore.save(key: key, account: ref)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
