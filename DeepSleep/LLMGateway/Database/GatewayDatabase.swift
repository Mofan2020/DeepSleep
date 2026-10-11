//
//  GatewayDatabase.swift
//  Deep Sleep
//
//  LLM Gateway 用的 sqlite3 封装。
//
//  设计：
//  - 手写 sqlite3 C API 封装，零依赖。
//  - 路径固定：~/Library/Application Support/DeepSleep/llm-gateway.sqlite
//  - WAL 模式（GatewayServer 与 QuotaPoller 同时写）。
//  - Migration：单表 schema_version 字符串，启动时按版本迁移。
//  - 同步 API（不并发）：上层调用方自己用 actor / DispatchQueue。
//
//  公共方法：
//      let db = try GatewayDatabase.open()
//      try db.insertProvider(cfg)
//      let cfgs = try db.listProviders()
//      try db.recordUsage(rec)
//      let rows = try db.aggregateUsage(providerId: x, since: yesterday)
//

import Foundation
import SQLite3

// MARK: - SQLite C API 静态常量

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - 数据库错误

enum GatewayDatabaseError: LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)
    case bind(String)
    case migration(String)

    var errorDescription: String? {
        switch self {
        case .open(let s):       return "打开数据库失败：\(s)"
        case .prepare(let s):    return "准备 SQL 失败：\(s)"
        case .step(let s):       return "执行 SQL 失败：\(s)"
        case .bind(let s):       return "绑定参数失败：\(s)"
        case .migration(let s):  return "迁移失败：\(s)"
        }
    }
}

// MARK: - GatewayDatabase

final class GatewayDatabase {

    /// 单例：全局共享一个 db handle，简化调用方。
    static let shared: GatewayDatabase = {
        do { return try GatewayDatabase.open() }
        catch {
            // 单例初始化失败意味着 db 文件不可写——这种情况下让进程直接挂，
            // 比「假装成功」要好。但 SQLite 失败很可能是磁盘满 / 权限问题，
            // 不能简单 assert；打日志 + 返回一个不会真正写入的占位实例。
            NSLog("[GatewayDatabase] failed to open: \(error)")
            // 退到 /tmp；写入会失败但不会崩。
            return (try? GatewayDatabase.open(at: NSTemporaryDirectory()
                + "DeepSleep-llm-gateway-fallback.sqlite"))!
        }
    }()

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.skyc8266.deepsleep.llmgateway.db")

    /// 同步打开数据库，自动迁移到最新 schema。
    static func open() throws -> GatewayDatabase {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("DeepSleep", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("llm-gateway.sqlite")
        return try open(at: url.path)
    }

    static func open(at path: String) throws -> GatewayDatabase {
        let db = GatewayDatabase()
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code=\(openResult)"
            sqlite3_close(handle)
            throw GatewayDatabaseError.open(msg)
        }
        db.handle = handle
        try db.exec("PRAGMA journal_mode = WAL;")
        try db.exec("PRAGMA synchronous = NORMAL;")
        try db.exec("PRAGMA foreign_keys = ON;")
        try db.migrate()
        return db
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    // MARK: - Migration

    private static let currentSchemaVersion = "1"

    private func migrate() throws {
        // metadata 表
        try exec("""
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
        """)
        let version = readMetadata("schema_version")
        if version == nil {
            try writeMetadata("schema_version", Self.currentSchemaVersion)
            try createInitialTables()
        } else if version != Self.currentSchemaVersion {
            // 现阶段只支持 v1；以后添加 v2/v3 时在这里加 if 分支。
            throw GatewayDatabaseError.migration(
                "unknown schema_version=\(version ?? "nil")"
            )
        }
    }

    private func createInitialTables() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS providers (
                id TEXT PRIMARY KEY,
                platform TEXT NOT NULL,
                display_name TEXT NOT NULL,
                billing_mode TEXT NOT NULL,
                api_key_ref TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                added_at REAL NOT NULL,
                notes TEXT
            );
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS quota_snapshots (
                id TEXT PRIMARY KEY,
                provider_id TEXT NOT NULL,
                captured_at REAL NOT NULL,
                five_hour_used REAL,
                five_hour_total REAL,
                five_hour_reset_at REAL,
                weekly_used REAL,
                weekly_total REAL,
                weekly_reset_at REAL,
                balance_amount REAL,
                balance_currency TEXT,
                window_status TEXT NOT NULL
            );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_quota_provider_time ON quota_snapshots(provider_id, captured_at);")
        try exec("""
            CREATE TABLE IF NOT EXISTS usage_records (
                id TEXT PRIMARY KEY,
                provider_id TEXT NOT NULL,
                model TEXT NOT NULL,
                timestamp REAL NOT NULL,
                prompt_tokens INTEGER NOT NULL,
                completion_tokens INTEGER NOT NULL,
                latency_ms INTEGER NOT NULL,
                status_code INTEGER NOT NULL,
                source_format TEXT NOT NULL,
                target_format TEXT NOT NULL
            );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_usage_provider_time ON usage_records(provider_id, timestamp);")
    }

    // MARK: - 元数据辅助

    private func readMetadata(_ key: String) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle, "SELECT value FROM metadata WHERE key = ?1;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cstr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cstr)
    }

    private func writeMetadata(_ key: String, _ value: String) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle,
            "INSERT OR REPLACE INTO metadata(key, value) VALUES(?1, ?2);",
            -1, &stmt, nil) == SQLITE_OK else {
            throw GatewayDatabaseError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw GatewayDatabaseError.step(String(cString: sqlite3_errmsg(handle)))
        }
    }

    // MARK: - 执行原始 SQL

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &err)
        if result != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "code=\(result)"
            if let err { sqlite3_free(err) }
            throw GatewayDatabaseError.step(msg)
        }
    }

    // MARK: - Provider CRUD

    func insertProvider(_ cfg: ProviderConfig) throws {
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, """
                INSERT OR REPLACE INTO providers
                (id, platform, display_name, billing_mode, api_key_ref, enabled, added_at, notes)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
                """, -1, &stmt, nil) == SQLITE_OK else {
                throw GatewayDatabaseError.prepare(String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_bind_text(stmt, 1, cfg.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, cfg.platform.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, cfg.displayName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, cfg.billingMode.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, cfg.apiKeyRef, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 6, cfg.enabled ? 1 : 0)
            sqlite3_bind_double(stmt, 7, cfg.addedAt.timeIntervalSince1970)
            if let notes = cfg.notes {
                sqlite3_bind_text(stmt, 8, notes, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw GatewayDatabaseError.step(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func deleteProvider(id: UUID) throws {
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, "DELETE FROM providers WHERE id = ?1;", -1, &stmt, nil) == SQLITE_OK else {
                throw GatewayDatabaseError.prepare(String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw GatewayDatabaseError.step(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func listProviders() throws -> [ProviderConfig] {
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, """
                SELECT id, platform, display_name, billing_mode, api_key_ref, enabled, added_at, notes
                FROM providers ORDER BY added_at ASC;
                """, -1, &stmt, nil) == SQLITE_OK else {
                throw GatewayDatabaseError.prepare(String(cString: sqlite3_errmsg(handle)))
            }
            var rows: [ProviderConfig] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                    let platformStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                    let nameStr = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                    let billingStr = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                    let refStr = sqlite3_column_text(stmt, 4).map({ String(cString: $0) }),
                    let platform = LLMPlatform(rawValue: platformStr),
                    let billing = BillingMode(rawValue: billingStr),
                    let id = UUID(uuidString: idStr)
                else { continue }

                let enabled = sqlite3_column_int(stmt, 5) != 0
                let addedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                let notes: String? = sqlite3_column_text(stmt, 7).map { String(cString: $0) }

                rows.append(ProviderConfig(
                    id: id,
                    platform: platform,
                    displayName: nameStr,
                    billingMode: billing,
                    apiKeyRef: refStr,
                    enabled: enabled,
                    addedAt: addedAt,
                    notes: notes
                ))
            }
            return rows
        }
    }

    // MARK: - Quota 快照

    func insertQuotaSnapshot(_ w: QuotaWindow) throws {
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, """
                INSERT OR REPLACE INTO quota_snapshots
                (id, provider_id, captured_at,
                 five_hour_used, five_hour_total, five_hour_reset_at,
                 weekly_used, weekly_total, weekly_reset_at,
                 balance_amount, balance_currency, window_status)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12);
                """, -1, &stmt, nil) == SQLITE_OK else {
                throw GatewayDatabaseError.prepare(String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_bind_text(stmt, 1, w.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, w.providerId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, w.capturedAt.timeIntervalSince1970)
            bindOptionalDouble(stmt, 4, w.fiveHourUsed)
            bindOptionalDouble(stmt, 5, w.fiveHourTotal)
            bindOptionalDate(stmt, 6, w.fiveHourResetAt)
            bindOptionalDouble(stmt, 7, w.weeklyUsed)
            bindOptionalDouble(stmt, 8, w.weeklyTotal)
            bindOptionalDate(stmt, 9, w.weeklyResetAt)
            bindOptionalDouble(stmt, 10, w.balanceAmount)
            bindOptionalText(stmt, 11, w.balanceCurrency)
            sqlite3_bind_text(stmt, 12, w.windowStatus.rawValue, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw GatewayDatabaseError.step(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func latestQuotaSnapshot(providerId: UUID) throws -> QuotaWindow? {
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, """
                SELECT id, captured_at,
                       five_hour_used, five_hour_total, five_hour_reset_at,
                       weekly_used, weekly_total, weekly_reset_at,
                       balance_amount, balance_currency, window_status
                FROM quota_snapshots
                WHERE provider_id = ?1
                ORDER BY captured_at DESC LIMIT 1;
                """, -1, &stmt, nil) == SQLITE_OK else {
                throw GatewayDatabaseError.prepare(String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_bind_text(stmt, 1, providerId.uuidString, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return try parseQuotaWindow(stmt: stmt, providerId: providerId)
        }
    }

    func allLatestQuotaSnapshots() throws -> [QuotaWindow] {
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, """
                SELECT qs.id, qs.provider_id, qs.captured_at,
                       qs.five_hour_used, qs.five_hour_total, qs.five_hour_reset_at,
                       qs.weekly_used, qs.weekly_total, qs.weekly_reset_at,
                       qs.balance_amount, qs.balance_currency, qs.window_status
                FROM quota_snapshots qs
                INNER JOIN (
                    SELECT provider_id, MAX(captured_at) AS max_at
                    FROM quota_snapshots GROUP BY provider_id
                ) latest
                  ON qs.provider_id = latest.provider_id AND qs.captured_at = latest.max_at;
                """, -1, &stmt, nil) == SQLITE_OK else {
                throw GatewayDatabaseError.prepare(String(cString: sqlite3_errmsg(handle)))
            }
            var rows: [QuotaWindow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let pidStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                      let pid = UUID(uuidString: pidStr) else { continue }
                if let w = try? parseQuotaWindow(stmt: stmt, providerId: pid) {
                    rows.append(w)
                }
            }
            return rows
        }
    }

    private func parseQuotaWindow(stmt: OpaquePointer?, providerId: UUID) throws -> QuotaWindow {
        guard let stmt,
              let idStr = sqlite3_column_text(stmt, 0) else {
            throw GatewayDatabaseError.step("解析 quota_snapshots 行失败")
        }
        let id = UUID(uuidString: String(cString: idStr)) ?? UUID()
        let capturedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        let balanceCurrency: String? = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
        let windowStatus: QuotaWindow.WindowStatus = sqlite3_column_text(stmt, 11)
            .map { String(cString: $0) }
            .flatMap { QuotaWindow.WindowStatus(rawValue: $0) } ?? .unknown
        return QuotaWindow(
            providerId: providerId,
            capturedAt: capturedAt,
            fiveHourUsed: optionalDouble(stmt, 3),
            fiveHourTotal: optionalDouble(stmt, 4),
            fiveHourResetAt: optionalDate(stmt, 5),
            weeklyUsed: optionalDouble(stmt, 6),
            weeklyTotal: optionalDouble(stmt, 7),
            weeklyResetAt: optionalDate(stmt, 8),
            balanceAmount: optionalDouble(stmt, 9),
            balanceCurrency: balanceCurrency,
            windowStatus: windowStatus
        )
    }

    // MARK: - Usage records

    func recordUsage(_ r: UsageRecord) throws {
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, """
                INSERT INTO usage_records
                (id, provider_id, model, timestamp,
                 prompt_tokens, completion_tokens, latency_ms,
                 status_code, source_format, target_format)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10);
                """, -1, &stmt, nil) == SQLITE_OK else {
                throw GatewayDatabaseError.prepare(String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_bind_text(stmt, 1, r.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, r.providerId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, r.model, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 4, r.timestamp.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 5, Int64(r.promptTokens))
            sqlite3_bind_int64(stmt, 6, Int64(r.completionTokens))
            sqlite3_bind_int64(stmt, 7, Int64(r.latencyMs))
            sqlite3_bind_int(stmt, 8, Int32(r.statusCode))
            sqlite3_bind_text(stmt, 9, r.sourceFormat, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 10, r.targetFormat, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw GatewayDatabaseError.step(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    struct UsageAggregate: Identifiable, Hashable {
        var id: UUID { providerId }
        let providerId: UUID
        let promptTokens: Int
        let completionTokens: Int
        let requestCount: Int
    }

    /// 按 provider 聚合 from..to 时间窗口的用量。
    func aggregateUsage(providerId: UUID, since: Date, until: Date = Date()) throws -> UsageAggregate {
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, """
                SELECT
                    COALESCE(SUM(prompt_tokens), 0),
                    COALESCE(SUM(completion_tokens), 0),
                    COUNT(*)
                FROM usage_records
                WHERE provider_id = ?1 AND timestamp BETWEEN ?2 AND ?3;
                """, -1, &stmt, nil) == SQLITE_OK else {
                throw GatewayDatabaseError.prepare(String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_bind_text(stmt, 1, providerId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, until.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return UsageAggregate(providerId: providerId, promptTokens: 0, completionTokens: 0, requestCount: 0)
            }
            return UsageAggregate(
                providerId: providerId,
                promptTokens: Int(sqlite3_column_int64(stmt, 0)),
                completionTokens: Int(sqlite3_column_int64(stmt, 1)),
                requestCount: Int(sqlite3_column_int64(stmt, 2))
            )
        }
    }

    func usageRecords(providerId: UUID, since: Date, until: Date = Date(), limit: Int = 200) throws -> [UsageRecord] {
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, """
                SELECT id, provider_id, model, timestamp,
                       prompt_tokens, completion_tokens, latency_ms,
                       status_code, source_format, target_format
                FROM usage_records
                WHERE provider_id = ?1 AND timestamp BETWEEN ?2 AND ?3
                ORDER BY timestamp DESC
                LIMIT ?4;
                """, -1, &stmt, nil) == SQLITE_OK else {
                throw GatewayDatabaseError.prepare(String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_bind_text(stmt, 1, providerId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, until.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 4, Int32(limit))
            var rows: [UsageRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                    let pidStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                    let modelStr = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                    let srcStr = sqlite3_column_text(stmt, 8).map({ String(cString: $0) }),
                    let tgtStr = sqlite3_column_text(stmt, 9).map({ String(cString: $0) }),
                    let id = UUID(uuidString: idStr),
                    let pid = UUID(uuidString: pidStr)
                else { continue }
                rows.append(UsageRecord(
                    id: id,
                    providerId: pid,
                    model: modelStr,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    promptTokens: Int(sqlite3_column_int64(stmt, 4)),
                    completionTokens: Int(sqlite3_column_int64(stmt, 5)),
                    latencyMs: Int(sqlite3_column_int64(stmt, 6)),
                    statusCode: Int(sqlite3_column_int(stmt, 7)),
                    sourceFormat: srcStr,
                    targetFormat: tgtStr
                ))
            }
            return rows
        }
    }

    // MARK: - 列辅助

    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ v: Double?) {
        if let v = v {
            sqlite3_bind_double(stmt, idx, v)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindOptionalDate(_ stmt: OpaquePointer?, _ idx: Int32, _ v: Date?) {
        if let v = v {
            sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ idx: Int32, _ v: String?) {
        if let v = v {
            sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func optionalDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, idx)
    }

    private func optionalDate(_ stmt: OpaquePointer?, _ idx: Int32) -> Date? {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, idx))
    }
}