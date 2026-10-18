//
//  ScheduledCommand.swift
//  Deep Sleep
//
//  「定时执行终端命令」：每 30 秒评估一次规则列表，按 cron 表达式匹配，
// 命中后用 `Process` 跑 `/bin/sh -c <command>`。
//
//  不通过 helper：以当前用户身份跑。helper 只用来 setuid，而 cron 类规则
// 没必要提权 —— 用户自己写的命令以自己的身份跑最干净。
//
//  cron 表达式只支持「5 字段」分钟级粒度（分 时 日 月 周），
// 跟系统 cron / launchd 不完全一致但够用且好理解。语法：
//
//   * * * * *
//   │ │ │ │ │
//   │ │ │ │ └─ 星期（0=周日 ... 6=周六；与系统 Vixie cron 一致）
//   │ │ │ └─── 月份（1-12）
//   │ │ └───── 日（1-31）
//   │ └─────── 时（0-23）
//   └───────── 分（0-59）
//
//  支持：数字、`*`、`*/N`（每隔 N）、`a-b`、`a,b,c`。
//
//  持久化：`scheduledCommands.v1`（UserDefaults JSON）。
//
//  风险与边界：
//   - 命令以**当前用户身份**跑，没有沙箱，写错 `rm -rf /` 是真删；
//     UI 那里加醒目警告，但工具不挡。
//   - 退出 Deep Sleep 后定时任务失效；这是「要 Deep Sleep 在跑」的功能，
//     跟其他「运行时」功能（断言、监控、自动化）一致。
//   - 5 秒一次的评估粒度，命令最少 30 秒一次；想 1 分钟一次也可以（cron
//     最细粒度是分钟），实际执行时间会有最多 30 秒误差。
//

import Foundation

@MainActor
final class ScheduledCommand {

    static let shared = ScheduledCommand()

    private init() {}

    struct Entry: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        var name: String
        var command: String
        /// 5 字段 cron（分 时 日 月 周）。
        var cron: String
        var isEnabled: Bool
        /// 上次实际执行时间（用于 UI 显示 + 避免重跑同一分钟）。
        /// 不持久化（重置为 nil）；持久化在 `lastRunAt` 字符串里。
        var lastRunAt: Date?
    }

    private static let storageKey = "scheduledCommands.v1"
    /// key: entry.id（UUID string），value: ISO8601 timestamp。
    private static let lastRunKey = "scheduledCommands.lastRun.v1"

    private var entries: [Entry] = []
    private var timer: Timer?

    var allEntries: [Entry] { entries }

    func start() {
        load()
        guard timer == nil else { return }
        // 30 秒评估一次（比命令粒度更细是为了误差小）。
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 配置

    func upsert(_ entry: Entry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        persist()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: - 执行

    private func tick() {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents(
            [.minute, .hour, .day, .month, .weekday], from: now
        )
        // Calendar: weekday 是 1=周日...7=周六 → 转成 cron 的 0=周日...6=周六
        let weekday = (components.weekday ?? 1) - 1
        let fields = CronField(
            minute: components.minute ?? 0,
            hour: components.hour ?? 0,
            day: components.day ?? 1,
            month: components.month ?? 1,
            weekday: weekday
        )

        for entry in entries where entry.isEnabled {
            guard let matcher = try? CronExpression.parse(entry.cron) else { continue }
            // 上次跑过的整分钟：避免同一分钟内连跑两次。
            let lastRunFloor = lastRunMinute(for: entry.id)
            let currentMinute = Self.minuteEpoch(for: now)
            if lastRunFloor == currentMinute { continue }
            if matcher.matches(fields) {
                runEntry(entry, at: now)
            }
        }
    }

    /// 跑一条命令。失败只写日志，不抛错。
    private func runEntry(_ entry: Entry, at now: Date) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", entry.command]
        // 接管输出，避免 Process 写到自己的 stdout 干扰 app。
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            SleepController.shared.appendLog(
                "定时命令「\(entry.name)」启动失败：\(error.localizedDescription)",
                isError: true
            )
            return
        }
        process.waitUntilExit()

        let lastRunFloor = Self.minuteEpoch(for: now)
        var map = lastRunMap
        map[entry.id.uuidString] = String(lastRunFloor)
        lastRunMap = map

        // UI 显示用：把 entries 里的对应项标 lastRunAt。
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].lastRunAt = now
        }

        if process.terminationStatus != 0 {
            let errText = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            SleepController.shared.appendLog(
                "定时命令「\(entry.name)」退出码 \(process.terminationStatus)：\(errText)",
                isError: true
            )
        } else {
            SleepController.shared.appendLog("定时命令「\(entry.name)」已执行")
        }
    }

    private var lastRunMap: [String: String] {
        get {
            (UserDefaults.standard.dictionary(forKey: Self.lastRunKey) as? [String: String]) ?? [:]
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.lastRunKey)
        }
    }

    private func lastRunMinute(for id: UUID) -> Int? {
        guard let s = lastRunMap[id.uuidString] else { return nil }
        return Int(s)
    }

    private static func minuteEpoch(for date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 60)
    }

    // MARK: - 公共：cron 解析 / 校验

    /// 校验 cron 字符串能否解析（不实际匹配）。
    static func validate(_ cron: String) -> Result<Void, ParseError> {
        do {
            _ = try CronExpression.parse(cron)
            return .success(())
        } catch let error as ParseError {
            return .failure(error)
        } catch {
            return .failure(.invalid("未知解析错误"))
        }
    }

    enum ParseError: Error, CustomStringConvertible {
        case fieldCount(Int)
        case invalid(String)
        var description: String {
            switch self {
            case .fieldCount(let n):  return "需要 5 个字段，当前 \(n) 个"
            case .invalid(let m):     return "cron 表达式无效：\(m)"
            }
        }
    }
}

// MARK: - cron 解析

/// 解析后的 cron 匹配器：5 个字段各自接受数字 / `*` / `*/N` / `a-b` / `a,b,c`。
struct CronExpression {
    let minute: Field
    let hour: Field
    let day: Field
    let month: Field
    let weekday: Field

    enum ParseError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self {
            case .invalid(let m): return "cron 表达式无效：\(m)"
            }
        }
    }

    struct Field {
        let allowed: Set<Int>

        func matches(_ value: Int) -> Bool {
            allowed.contains(value)
        }

        /// 解析单个字段。语法：`*` / `*` 等价 `*` / `*/N` / `N` / `N-M` / `N,M,K`。
        static func parse(_ raw: String, range: ClosedRange<Int>) throws -> Field {
            var allowed: Set<Int> = []
            for piece in raw.split(separator: ",") {
                let pieceStr = String(piece)
                if pieceStr == "*" {
                    allowed.formUnion(range)
                } else if pieceStr.hasPrefix("*/") {
                    let n = Int(String(pieceStr.dropFirst(2))) ?? 1
                    if n <= 0 { throw CronExpression.ParseError.invalid("步长必须 > 0: \(pieceStr)") }
                    var v = range.lowerBound
                    while v <= range.upperBound {
                        allowed.insert(v)
                        v += n
                    }
                } else if pieceStr.contains("-") {
                    let parts = pieceStr.split(separator: "-")
                    guard parts.count == 2,
                          let lo = Int(parts[0]), let hi = Int(parts[1]) else {
                        throw ParseError.invalid("区间格式: \(pieceStr)")
                    }
                    guard range.contains(lo), range.contains(hi), lo <= hi else {
                        throw ParseError.invalid("区间超出 \(range): \(pieceStr)")
                    }
                    allowed.formUnion(lo...hi)
                } else if let n = Int(pieceStr) {
                    guard range.contains(n) else {
                        throw ParseError.invalid("\(n) 不在 \(range)")
                    }
                    allowed.insert(n)
                } else {
                    throw ParseError.invalid("无法识别: \(pieceStr)")
                }
            }
            return Field(allowed: allowed)
        }
    }

    /// 解析 5 字段 cron。
    static func parse(_ cron: String) throws -> CronExpression {
        let trimmed = cron.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 5 else {
            throw ScheduledCommand.ParseError.fieldCount(parts.count)
        }
        return CronExpression(
            minute: try Field.parse(String(parts[0]), range: 0...59),
            hour: try Field.parse(String(parts[1]), range: 0...23),
            day: try Field.parse(String(parts[2]), range: 1...31),
            month: try Field.parse(String(parts[3]), range: 1...12),
            weekday: try Field.parse(String(parts[4]), range: 0...6)
        )
    }

    /// 当前时间各字段值与 cron 表达式匹配吗？
    func matches(_ fields: CronField) -> Bool {
        minute.matches(fields.minute)
            && hour.matches(fields.hour)
            && day.matches(fields.day)
            && month.matches(fields.month)
            && weekday.matches(fields.weekday)
    }
}

/// 当前时间的 cron 字段快照。
struct CronField {
    let minute: Int
    let hour: Int
    let day: Int
    let month: Int
    let weekday: Int
}
