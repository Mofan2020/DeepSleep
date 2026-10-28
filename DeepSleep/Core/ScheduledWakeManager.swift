//
//  ScheduledWakeManager.swift
//  Deep Sleep
//
//  排定唤醒的管理：多条一次性排定 + 循环排定，以及与系统真实状态的对账。
//
//  为什么不用现有那套：原实现只有一条排定，取消走 `pmset schedule cancelall`
//  —— 那会把**别的程序**排的唤醒一起取消掉。排定是共享的系统资源，
//  别人也可能在用（闹钟、备份工具）。所以这里改成：
//    - 本地维护一份排定列表，每条带自己的 id 与备注
//    - 取消时按「类型 + 时间」精确取消单条
//    - 每次变更后从 `pmset -g sched` 读回真实状态，与本地列表对账
//
//  对账的理由和项目里其它地方一样：不假设「设了就一直生效」。
//  外部可能改掉（用户手动 pmset、别的工具排定、机器重启）。
//
//  权限：`pmset schedule` / `pmset repeat` 都必须 root，所以写操作走特权助手；
//  读 `pmset -g sched` 不需要 root，但统一放助手侧读，避免两套解析逻辑漂移。
//

import Foundation

/// 排定操作失败的原因。
///
/// 用专门的错误类型而不是裸 `String`：`Result` 的失败类型必须满足 `Error`，
/// 而且界面拿到的是一个「能说明白」的对象，不是一段不知道从哪来的文本。
enum ScheduledWakeError: LocalizedError, Equatable {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// 一条排定唤醒。
struct ScheduledWake: Codable, Identifiable, Equatable {

    /// 本地唯一标识。不参与系统侧匹配，只用于 UI 与持久化。
    var id: UUID = UUID()
    /// 备注。给用户看「这一条是干什么的」。
    var note: String = ""
    /// 一次性排定的时刻。循环排定时为 nil。
    var date: Date?
    /// 循环排定的星期（1 = 周日 … 7 = 周六，与 Calendar 一致）。
    var weekdays: Set<Int> = []
    /// 循环排定的时刻（当天几点）。一次性排定时为 nil。
    var timeOfDay: Date?
    /// 是否启用。
    var isEnabled: Bool = true

    init(id: UUID = UUID(),
         note: String = "",
         date: Date? = nil,
         weekdays: Set<Int> = [],
         timeOfDay: Date? = nil,
         isEnabled: Bool = true) {
        self.id = id
        self.note = note
        self.date = date
        self.weekdays = weekdays
        self.timeOfDay = timeOfDay
        self.isEnabled = isEnabled
    }

    /// 这是循环排定还是一次性排定。
    var isRepeating: Bool { weekdays.isEmpty == false }

    /// 显示用的时间文本。
    var timeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        if let timeOfDay {
            return formatter.string(from: timeOfDay)
        }
        if let date {
            formatter.dateFormat = "MM/dd HH:mm"
            return formatter.string(from: date)
        }
        return "—"
    }

    /// 显示用的星期文本。
    var weekdayText: String {
        guard isRepeating else { return "一次性" }
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        let sorted = weekdays.sorted()
        guard sorted.count == 7 else {
            return sorted.compactMap { (1...7).contains($0) ? "周" + names[$0 - 1] : nil }
                .joined(separator: "、")
        }
        return "每天"
    }
}

/// 系统里实际存在的排定项（从 `pmset -g sched` 解析）。
struct SystemScheduledEvent: Equatable, Identifiable {
    /// 类型：wake / poweron / sleep / shutdown / restart
    var kind: String
    /// 时刻（一次性排定）。
    var date: Date?
    /// 星期（循环排定）。
    var weekdays: Set<Int> = []
    /// 时刻（循环排定）。
    var timeOfDay: Date?
    /// 排定者。
    var owner: String

    var id: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yy HH:mm:ss"
        let when = date.map { formatter.string(from: $0) } ?? (timeOfDay.map { $0.description } ?? "")
        return "\(kind)|\(when)|\(owner)"
    }

    /// 是不是本工具排的。
    var isOwnedByDeepSleep: Bool { owner == ScheduledWakeManager.ownerTag }
}

/// 排定唤醒的管理器。
@MainActor
final class ScheduledWakeManager {

    static let shared = ScheduledWakeManager()

    /// 排定时的 owner 标记。`pmset schedule` 支持 owner 参数，
    /// 用它就能只认自己排的那些。
    static let ownerTag = "Deep Sleep"

    private static let storageKey = "scheduledWakes.v1"

    /// 本地排定列表。
    private(set) var entries: [ScheduledWake] = []
    /// 系统里实际存在的排定项。
    private(set) var systemEvents: [SystemScheduledEvent] = []

    private init() {}

    // MARK: - 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ScheduledWake].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// 载入本地列表。
    func start() {
        load()
    }

    // MARK: - 查询

    /// 本工具排定的、且已到点的排定项。
    func pendingEntries() -> [ScheduledWake] {
        let now = Date()
        return entries.filter { entry in
            guard entry.isEnabled else { return false }
            if let date = entry.date {
                return date > now
            }
            return true
        }
    }

    /// 与系统真实状态对账。
    ///
    /// 返回「本地有、系统里没有」的条目 —— 那些是**失效**的
    /// （被外部取消了，或者时间已过被系统消费掉了）。
    func staleEntries() -> [ScheduledWake] {
        let known = Set(systemEvents.map(\.id))
        return entries.filter { entry in
            guard entry.isEnabled else { return false }
            guard let date = entry.date else { return false }
            // 一次性排定：系统里找不到同类型同时间同 owner 的，就是失效了
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MM/dd/yy HH:mm:ss"
            let key = "wake|\(formatter.string(from: date))|\(Self.ownerTag)"
            return !known.contains(key)
        }
    }

    // MARK: - 变更

    func upsert(_ entry: ScheduledWake) {
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

    func toggle(id: UUID, enabled: Bool) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].isEnabled = enabled
        persist()
    }

    // MARK: - 与系统交互

    /// 排定一条一次性唤醒。成功后本地列表同步更新。
    func scheduleOnce(at date: Date, note: String) async -> Result<ScheduledWake, ScheduledWakeError> {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yy HH:mm:ss"
        let text = formatter.string(from: date)

        do {
            let response = try await HelperClient.shared.send(.init(
                command: .scheduleWakeWithOwner,
                arguments: ["date": text, "owner": Self.ownerTag]
            ))
            guard response.success else {
                return .failure(.message(response.message))
            }
            let entry = ScheduledWake(note: note, date: date)
            upsert(entry)
            await refresh()
            return .success(entry)
        } catch {
            return .failure(.message(error.localizedDescription))
        }
    }

    /// 排定一条循环唤醒。
    func scheduleRepeating(weekdays: Set<Int>, timeOfDay: Date, note: String) async -> Result<ScheduledWake, ScheduledWakeError> {
        guard !weekdays.isEmpty else {
            return .failure(.message("至少要选一个星期"))
        }
        // pmset 用 MTWRFSU 表示周一到周日（Monday first）。
        let symbols = ["M", "T", "W", "R", "F", "S", "U"]
        let ordered = [2, 3, 4, 5, 6, 7, 1]  // Calendar: 1=周日 → MTWRFSU 顺序
        let letters = ordered.compactMap { weekday -> String? in
            guard weekdays.contains(weekday) else { return nil }
            return symbols[weekday - 1]
        }.joined()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: timeOfDay)

        do {
            let response = try await HelperClient.shared.send(.init(
                command: .scheduleRepeatWake,
                arguments: ["weekdays": letters, "time": time]
            ))
            guard response.success else {
                return .failure(.message(response.message))
            }
            let entry = ScheduledWake(note: note, weekdays: weekdays, timeOfDay: timeOfDay)
            upsert(entry)
            await refresh()
            return .success(entry)
        } catch {
            return .failure(.message(error.localizedDescription))
        }
    }

    /// 取消一条排定。一次性走精确取消，循环走取消全部循环排定
    /// （`pmset repeat cancel` 没有单条粒度 —— 系统本身就不支持）。
    func cancel(id: UUID) async -> Result<Void, ScheduledWakeError> {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return .failure(.message("找不到这条排定"))
        }
        do {
            if entry.isRepeating {
                let response = try await HelperClient.shared.send(.init(command: .cancelRepeatWake))
                guard response.success else { return .failure(.message(response.message)) }
            } else {
                guard let date = entry.date else {
                    return .failure(.message("这条排定没有时间信息"))
                }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "MM/dd/yy HH:mm:ss"
                let response = try await HelperClient.shared.send(.init(
                    command: .cancelScheduledEvent,
                    arguments: [
                        "date": formatter.string(from: date),
                        "kind": "wake"
                    ]
                ))
                guard response.success else { return .failure(.message(response.message)) }
            }
            remove(id: id)
            await refresh()
            return .success(())
        } catch {
            return .failure(.message(error.localizedDescription))
        }
    }

    /// 从系统读回真实排定状态。
    func refresh() async {
        do {
            let response = try await HelperClient.shared.send(.init(command: .listScheduledEvents))
            guard response.success else {
                systemEvents = []
                return
            }
            systemEvents = Self.parseEntries(response.payload["entries"])
        } catch {
            systemEvents = []
        }
    }

    /// 解析助手回传的 `kind|when|owner` 记录串。
    static func parseEntries(_ raw: String?) -> [SystemScheduledEvent] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",", omittingEmptySubsequences: false).compactMap { entry in
            let fields = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { return nil }
            let kind = fields[0]
            let when = fields[1]
            let owner = fields.count >= 3 ? fields[2] : ""

            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.dateFormat = "MM/dd/yy HH:mm:ss"

            let timeFormatter = DateFormatter()
            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
            timeFormatter.dateFormat = "HH:mm:ss"

            if let date = dateFormatter.date(from: when) {
                return SystemScheduledEvent(kind: kind, date: date, owner: owner)
            }
            // 循环排定的 when 形如 "MTWRFSU 08:00:00"
            let pieces = when.split(separator: " ").map(String.init)
            if pieces.count == 2, let time = timeFormatter.date(from: pieces[1]) {
                // MTWRFSU 顺序 → Calendar 编号（1=周日）。
                let symbols: [Character] = ["M", "T", "W", "R", "F", "S", "U"]
                var weekdays: Set<Int> = []
                for ch in pieces[0] {
                    if let idx = symbols.firstIndex(of: ch) {
                        weekdays.insert([2, 3, 4, 5, 6, 7, 1][idx])
                    }
                }
                return SystemScheduledEvent(kind: kind, weekdays: weekdays,
                                            timeOfDay: time, owner: owner)
            }
            return nil
        }
    }
}
