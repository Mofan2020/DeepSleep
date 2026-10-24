//
//  KeepAliveModels.swift
//  Deep Sleep
//
//  AI 保活：按每天的固定时刻向订阅制 AI 服务发一条超短请求，把「按最后一次
//  使用起算的滚动窗口」拉成近似固定窗口。
//
//  背景：Claude Code / MiniMax / Codex / Gemini / DeepSeek 这类订阅服务普遍
//  有「N 小时滚动使用窗口」—— 窗口从你上一次使用开始计时，闲置到点就重置
//  额度。实际用起来就是：明明没怎么用，额度却因为窗口到期被白白重置掉。
//
//  为什么要「每天定时」而不是「每隔 N 小时」：
//  - 「每隔 N 小时」的锚点是上一次实际发送的时刻，窗口边界一直往后漂。
//    想让额度在开工前就重置，得自己记得点一下。
//  - 「每天定时」给的是固定边界：配了 09:00，窗口就从 09:00 起算，
//    在下一个时刻之前你一直待在同一个窗口里。
//  - 「每周哪几天」用来表达「周末不用管」：那几天不发，窗口自然重置。
//
//  本文件只放「纯数据 + 纯函数」，不碰网络、不碰 Keychain、不碰 UI ——
//  这样 scripts/test-keepalive-url.swift 可以单独编译它做回归测试。
//
//  安全约定：API Key 不出现在这个文件里，也不出现在任何会被持久化的地方。
//  任务只保存 Keychain 的 account 名（apiKeyRef）。
//

import Foundation

// MARK: - 协议格式

/// 保活请求用哪种协议格式。
enum KeepAliveFormat: String, Codable, CaseIterable, Hashable {
    case openAI = "openai"
    case anthropic = "anthropic"

    /// UI 标题。
    var title: String {
        switch self {
        case .openAI:    return "OpenAI 格式"
        case .anthropic: return "Anthropic 格式"
        }
    }

    /// UI 副标题：一句话说清请求长什么样。
    var detail: String {
        switch self {
        case .openAI:
            return "Authorization: Bearer *** /v1/chat/completions"
        case .anthropic:
            return "x-api-key: *** + anthropic-version，端点 /v1/messages"
        }
    }
}

// MARK: - 默认值

/// 保活相关的默认常量。用户改乱了模板要能一键还原，所以模板内容必须是常量。
enum KeepAliveDefaults {

    /// 每天最多几个触发时刻。
    ///
    /// 上限的意义：保活是「让窗口别闲置」，不是「轮询」。
    /// 一天几十次说明用户把两件事混了，那样每个窗口都被打散，反而用不满额度。
    static let maxTimesPerDay = 24

    /// 默认请求内容模板。
    ///
    /// 只发一个 "ping" 的话，模型不知道要做什么 —— 有的会回一段解释，
    /// 有的会反问，消耗和延迟都不可控。写清楚「回 ping 即可」，
    /// 模型就会给一个 token 的应答。
    static let defaultRequestTemplate = "测试消息，直接回复‘ping’即可"
}

// MARK: - 触发时刻

/// 一个「每天的时刻」。只精确到分钟。
struct KeepAliveTime: Codable, Equatable, Hashable, Comparable, Identifiable {

    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    /// 自定义解码：钳制到合法区间。
    ///
    /// 手改过的存储可能塞进 25 点或 70 分 —— 不钳制的话
    /// `date(bySettingHour:)` 会返回 nil，那个时刻就静默消失了。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hour = try container.decode(Int.self, forKey: .hour)
        let minute = try container.decode(Int.self, forKey: .minute)
        self.init(hour: hour, minute: minute)
    }

    /// 从「距零点多少分钟」构造。
    init(minutesFromMidnight: Int) {
        let total = min(max(minutesFromMidnight, 0), 24 * 60 - 1)
        self.hour = total / 60
        self.minute = total % 60
    }

    /// 距零点多少分钟。
    var minutesFromMidnight: Int { hour * 60 + minute }

    /// `HH:mm`
    var display: String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// 稳定 id。同一时刻的重复项会被去重，所以 id 天然唯一。
    var id: String { "\(hour):\(minute)" }

    static func < (lhs: KeepAliveTime, rhs: KeepAliveTime) -> Bool {
        lhs.minutesFromMidnight < rhs.minutesFromMidnight
    }
}

// MARK: - 时间计划

/// 保活任务的时间计划：每天哪些时刻发、每周哪几天发。
///
/// 星期用 `Calendar` 的编号：1 = 周日 ... 7 = 周六。
/// 与 `Calendar.component(.weekday:)` 一致，不另造一套。
struct KeepAliveSchedule: Codable, Equatable, Hashable {

    /// 每天的触发时刻。构造时去重并按时间升序排。
    var times: [KeepAliveTime]

    /// 生效的星期（1 = 周日 ... 7 = 周六）。空集合 = 一周都不发。
    var weekdays: Set<Int>

    /// 默认时刻：上午开工前一次，下午再续一次。
    static let defaultTimes: [KeepAliveTime] = [
        KeepAliveTime(hour: 9, minute: 0),
        KeepAliveTime(hour: 14, minute: 0),
    ]

    /// 默认星期：周一到周五。
    static let defaultWeekdays: Set<Int> = [2, 3, 4, 5, 6]

    /// 界面上的星期顺序：周一排头，周日排尾。
    static let weekdayOrder: [Int] = [2, 3, 4, 5, 6, 7, 1]

    /// 一周七天全开。
    static let allWeekdays: Set<Int> = Set(1...7)

    /// 归一化构造：去重、排序、剔非法星期、限制每天时刻数量。
    init(times: [KeepAliveTime] = KeepAliveSchedule.defaultTimes,
         weekdays: Set<Int> = KeepAliveSchedule.defaultWeekdays) {
        var unique: [KeepAliveTime] = []
        for time in times.sorted() where !unique.contains(time) {
            unique.append(time)
        }
        self.times = Array(unique.prefix(KeepAliveDefaults.maxTimesPerDay))
        self.weekdays = weekdays.filter { (1...7).contains($0) }
    }

    /// 默认计划。
    static let `default` = KeepAliveSchedule()

    /// 归一化后的副本。读盘、写入、UI 三条入口都要过这一道。
    var clamped: KeepAliveSchedule {
        KeepAliveSchedule(times: times, weekdays: weekdays)
    }

    /// 自定义解码：**解码后必须过一遍归一化**。
    ///
    /// 合成的 `init(from:)` 不会调用归一化 init，会把磁盘上的原始数组
    /// 直接塞进成员 —— 手改过的存储（重复时刻、非法星期、几十个时刻）
    /// 就会原样进到运行时。跟 ToolboxLayout 是同一个坑。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let times = try container.decodeIfPresent([KeepAliveTime].self, forKey: .times) ?? []
        let weekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? []
        self.init(times: times, weekdays: weekdays)
    }

    // MARK: - 星期文案

    /// 单个星期的短名。
    static func shortWeekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "日"
        case 2: return "一"
        case 3: return "二"
        case 4: return "三"
        case 5: return "四"
        case 6: return "五"
        case 7: return "六"
        default: return "?"
        }
    }

    /// 星期的完整名字。
    static func fullWeekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "周日"
        case 2: return "周一"
        case 3: return "周二"
        case 4: return "周三"
        case 5: return "周四"
        case 6: return "周五"
        case 7: return "周六"
        default: return "?"
        }
    }

    /// 星期集合的文案。
    ///
    /// 全部七天 → 「每天」；工作日 → 「周一至周五」；其余逐个列出。
    var weekdayDescription: String {
        if weekdays.isEmpty { return "不运行" }
        if weekdays == Self.allWeekdays { return "每天" }
        if weekdays == Set([2, 3, 4, 5, 6]) { return "周一至周五" }
        return Self.weekdayOrder
            .filter { weekdays.contains($0) }
            .map { Self.fullWeekdayName($0) }
            .joined(separator: "、")
    }

    /// 整条计划的文案：「每天 09:00、14:00」。
    var description: String {
        let timeText = times.isEmpty
            ? "未设时刻"
            : times.map(\.display).joined(separator: "、")
        return "\(weekdayDescription) \(timeText)"
    }

    // MARK: - 到点判定

    /// 某一天里属于本计划的时刻（升序）。
    func times(onDay day: Date, calendar: Calendar = .current) -> [Date] {
        times.compactMap { time in
            calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)
        }
    }

    /// 严格晚于给定时刻的下一个触发时刻。找不到返回 nil。
    ///
    /// 往前找 8 天 —— 一周七天下，最坏情况是「今天最后一个时刻已经过了，
    /// 下一次要等到下周同一天」，7 天不够，要留一天余量。
    func nextSlot(after date: Date, calendar: Calendar = .current) -> Date? {
        guard !times.isEmpty, !weekdays.isEmpty else { return nil }
        let startOfDay = calendar.startOfDay(for: date)
        for dayOffset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) else {
                continue
            }
            guard weekdays.contains(calendar.component(.weekday, from: day)) else { continue }
            for slot in times(onDay: day, calendar: calendar) where slot > date {
                return slot
            }
        }
        return nil
    }

    /// 当前是否有一个「到点但还没发过」的触发时刻。
    ///
    /// 规则很简单：
    ///  - 只看**运行日**里的时刻。非运行日（周末、没选中的那天）一律不发。
    ///  - 时刻已经过去、且晚于锚点（上次成功发送 / 任务创建时间）→ 该发。
    ///  - **不补发**：应用关了好几天再打开，那个期间的时刻已经作废，
    ///    等下一个整点时刻再说。这跟用户对「窗口」的直觉一致 ——
    ///    过了的点就该过去，重新开始一个干净的窗口。
    ///
    /// 只回看当天的时刻（而不是往前找几天）：往前找会把「非运行日的时刻」
    /// 或者「几天前就作废的时刻」错当成待发。
    func pendingSlot(now: Date,
                     lastRunAt: Date?,
                     since: Date?,
                     calendar: Calendar = .current) -> Date? {
        guard !times.isEmpty, !weekdays.isEmpty else { return nil }
        // 锚点 = 上次发送与创建时间里较晚的那个。
        let anchor: Date?
        switch (lastRunAt, since) {
        case let (l?, s?): anchor = max(l, s)
        case let (l?, nil): anchor = l
        case let (nil, s?): anchor = s
        case (nil, nil):    anchor = nil
        }
        // 今天不是运行日 → 不发。
        let today = calendar.startOfDay(for: now)
        guard weekdays.contains(calendar.component(.weekday, from: today)) else { return nil }
        var best: Date?
        for slot in times(onDay: today, calendar: calendar) {
            guard slot <= now else { continue }
            if let anchor, slot <= anchor { continue }
            if best == nil || slot > best! { best = slot }
        }
        return best
    }

    // MARK: - 旧数据迁移

    /// 从旧版「固定间隔（分钟）」迁移到每日定时。
    ///
    /// 旧版没有时刻概念，只有一个间隔。迁移策略：把间隔当成一天的步长，
    /// 从 00:00 开始铺开 —— 间隔 240 分钟 → 00:00 / 04:00 / … / 20:00。
    /// 每天的次数与旧版一致，窗口边界从「跟着上次发送漂移」变成对齐整点，
    /// 正好是这次改动的目的。
    ///
    /// 间隔小于 1 小时时按小时铺：不然 1 分钟间隔会铺出 1440 个时刻，
    /// 编辑器根本没法看。
    static func migratedFromLegacyInterval(_ minutes: Int) -> KeepAliveSchedule {
        let step = max(minutes, 60)
        var times: [KeepAliveTime] = []
        var minute = 0
        while minute < 24 * 60 {
            times.append(KeepAliveTime(minutesFromMidnight: minute))
            minute += step
        }
        return KeepAliveSchedule(times: times, weekdays: allWeekdays)
    }
}

// MARK: - 任务模型

/// 一个保活任务。
struct KeepAliveTask: Codable, Identifiable, Equatable, Hashable {

    var id: UUID
    /// 用户起的名字，只用于界面与日志。
    var name: String
    /// 服务端地址，例如 https://api.openai.com 。末尾有没有 /v1 都认。
    var baseURL: String
    /// 请求格式。
    var format: KeepAliveFormat
    /// 模型名。
    var model: String
    /// Keychain 的 account 名（形如 `keepalive.<uuid>`），**不是** key 本身。
    var apiKeyRef: String
    /// 时间计划：每天哪些时刻发、每周哪几天发。
    var schedule: KeepAliveSchedule
    /// 请求内容模板。允许用户自定义。
    var requestTemplate: String
    /// 是否启用。
    var isEnabled: Bool
    /// 上次**成功**发送时间。
    var lastRunAt: Date?
    /// 上次结果摘要（成功 / 失败原因）。脱敏后才允许写进来。
    var lastResult: String?
    /// 创建时间。
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        baseURL: String = "",
        format: KeepAliveFormat = .openAI,
        model: String = "",
        apiKeyRef: String = "",
        schedule: KeepAliveSchedule = .default,
        requestTemplate: String = KeepAliveDefaults.defaultRequestTemplate,
        isEnabled: Bool = true,
        lastRunAt: Date? = nil,
        lastResult: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.format = format
        self.model = model
        self.apiKeyRef = apiKeyRef
        self.schedule = schedule
        self.requestTemplate = requestTemplate
        self.isEnabled = isEnabled
        self.lastRunAt = lastRunAt
        self.lastResult = lastResult
        self.createdAt = createdAt
    }

    /// 归一化后的副本。读盘、写入、UI 三条入口都要过这一道。
    var clamped: KeepAliveTask {
        var copy = self
        copy.schedule = schedule.clamped
        if copy.requestTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.requestTemplate = KeepAliveDefaults.defaultRequestTemplate
        }
        return copy
    }

    /// 到点判定：现在是不是有一个该发没发的时刻。
    func isDue(at now: Date = Date(), calendar: Calendar = .current) -> Bool {
        pendingSlot(at: now, calendar: calendar) != nil
    }

    /// 到点但还没发过的那个时刻。没有则 nil。
    ///
    /// 锚点是「上次成功发送」与「任务创建时间」里较晚的那个：
    /// 失败不推进锚点，下一次 tick 就会重试；而任务存在之前的时刻不算欠账。
    func pendingSlot(at now: Date = Date(), calendar: Calendar = .current) -> Date? {
        schedule.pendingSlot(
            now: now,
            lastRunAt: lastRunAt,
            since: createdAt,
            calendar: calendar
        )
    }

    /// 界面上的计划摘要。
    var scheduleDescription: String {
        schedule.description
    }
}

// MARK: - URL 拼接

/// 把 baseurl 与目标路径拼成最终 URL。
///
/// 规则（OpenAI 与 Anthropic 共用同一套归一化）：
///   - 去掉 baseurl 末尾的 `/`；
///   - baseurl 已以 `/v1` 或 `/v1/` 结尾时不再补 `v1`；
///   - 其余情况补上 `/v1`。
///
/// 于是：
///   - `https://api.openai.com`      → `https://api.openai.com/v1/chat/completions`
///   - `https://api.openai.com/v1`   → `https://api.openai.com/v1/chat/completions`
///   - `https://api.anthropic.com`   → `https://api.anthropic.com/v1/messages`
///
/// baseurl 不合法（空、缺 scheme）时返回 nil，调用方负责报错。
enum KeepAliveEndpoint {

    /// 归一化 baseurl：去尾斜杠 + 补 `/v1`。
    /// 不合法时返回空字符串。
    static func normalizedBaseURL(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.count > 1 && text.hasSuffix("/") {
            text.removeLast()
        }
        guard !text.isEmpty else { return "" }
        let lowered = text.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else {
            return ""
        }
        // 大小写不敏感地判断是否已带 /v1，避免用户写成 /V1 时被拼成 /V1/v1。
        if lowered.hasSuffix("/v1") { return text }
        return text + "/v1"
    }

    /// 拼 URL。`path` 不带首尾斜杠。
    static func url(baseURL: String, path: String) -> URL? {
        let base = normalizedBaseURL(baseURL)
        guard !base.isEmpty else { return nil }
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let full = cleanPath.isEmpty ? base : base + "/" + cleanPath
        return URL(string: full)
    }

    /// 保活请求的端点。
    static func chatURL(baseURL: String, format: KeepAliveFormat) -> URL? {
        switch format {
        case .openAI:
            return url(baseURL: baseURL, path: "chat/completions")
        case .anthropic:
            return url(baseURL: baseURL, path: "messages")
        }
    }

    /// 模型列表的端点。
    static func modelsURL(baseURL: String, format: KeepAliveFormat) -> URL? {
        url(baseURL: baseURL, path: "models")
    }
}
