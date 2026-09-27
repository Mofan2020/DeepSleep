//
//  PowerActivityMonitor.swift
//  Deep Sleep
//
//  观察外部世界对电源管理的干预，回答两个问题：
//    1. 现在有哪些进程在阻止休眠？（断言）
//    2. 系统的电源设置什么时候被改动了？（与 Deep Sleep 争夺控制权）
//
//  能确定的和不能确定的，必须分清楚：
//    - **断言**：内核直接给出，进程、类型、原因都是确定的。
//    - **设置改动**：能确定「哪个键、从什么变成什么、什么时候」，
//      也能确定「是不是 Deep Sleep 自己写的」——因为我们跟踪了自己的写入。
//      但 macOS 没有公开 API 能告诉我们「是哪个进程写进 pmset 的」，
//      所以这里不编造进程名，只给出改动本身，外加当时持有断言的进程作为线索。
//

import AppKit
import Darwin
import Foundation
import IOKit.pwr_mgt

/// 一个断言条目。
struct AssertionInfo: Identifiable, Equatable {
    var id: String { "\(type)|\(name)|\(level)" }
    let type: String
    let name: String
    let reason: String
    let level: Int

    /// 会阻止系统/空闲睡眠的类型。
    /// `UserIsActive` 这类不算：那是系统对「用户正在操作」的描述，
    /// 不是哪个程序在索要保持清醒。
    var preventsSystemSleep: Bool {
        Self.systemSleepTypes.contains(type)
    }

    /// 只阻止显示器睡眠的类型。
    var preventsDisplaySleepOnly: Bool {
        Self.displaySleepTypes.contains(type) && !preventsSystemSleep
    }

    private static let systemSleepTypes: Set<String> = [
        "PreventSystemSleep",
        "PreventUserIdleSystemSleep",
        "NoIdleSleepAssertion",
    ]
    private static let displaySleepTypes: Set<String> = [
        "PreventUserIdleDisplaySleep",
        "NoDisplaySleepAssertion",
    ]
}

/// 一个正在持有断言的进程。
struct SleepBlocker: Identifiable, Equatable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    let assertions: [AssertionInfo]
    /// 是否属于 Deep Sleep 自己（本进程或我们的特权助手）。
    let isSelf: Bool

    var systemSleepAssertions: [AssertionInfo] {
        assertions.filter(\.preventsSystemSleep)
    }

    var isPreventingSystemSleep: Bool {
        !systemSleepAssertions.isEmpty
    }
}

/// 一次电源设置的改动。
struct PowerSettingChange: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let key: String
    let oldValue: String?
    let newValue: String
    /// 是否由 Deep Sleep 自己造成。false 即「外部程序改的」。
    let bySelf: Bool
}

@MainActor
final class PowerActivityMonitor: ObservableObject {

    static let shared = PowerActivityMonitor()

    /// 当前持有断言的进程，按「是否阻止系统睡眠」和 pid 排序。
    @Published private(set) var blockers: [SleepBlocker] = []
    /// 设置改动历史，最新的在前。
    @Published private(set) var changes: [PowerSettingChange] = []
    @Published private(set) var lastScanAt: Date?

    /// 上一轮看到的设置，用于 diff 出改动。
    private var baseline: [String: String] = [:]

    /// 自己刚写过的键值。写完立刻更新基线，这样下一轮 diff 不会
    /// 把自己的改动误报成「外部干预」。
    private var selfWrites: [String: String] = [:]

    /// 改动列表上限，避免无限增长。
    private let maxChanges = 200

    /// 去重窗口：同一个键在短时间内反复变成同一个值只记一次，
    /// 免得某个键抖动时把列表刷满。
    private var recentKeys: [String: Date] = [:]
    private let dedupeWindow: TimeInterval = 30

    /// 只关注与睡眠控制有关的键。全量 diff 会被无关键的噪声淹没。
    private static let watchedKeys: Set<String> = [
        "SleepDisabled", "sleep", "displaysleep", "disksleep",
        "hibernatemode", "standby", "powernap", "womp",
        "ttyskeepawake", "lowpowermode", "autorestart", "lidwake",
        "halfdim", "networkoversleep", "SleepServices", "Sleep On Power Button",
    ]

    private init() {}

    // MARK: - 扫描

    /// 刷新一次断言列表与设置基线。
    /// - Parameter currentSettings: 调用方若刚读过设置可以传进来，省一次 `pmset` 调用。
    func scan(currentSettings: [String: String]? = nil) {
        blockers = Self.currentBlockers()

        let current = currentSettings ?? PMSetOutput.readCurrent()
        defer {
            baseline = current
            lastScanAt = Date()
        }

        // 首轮只建立基线，不产生「改动」——否则会把开机以来的全部设置
        // 都报成一次外部改动。
        guard !baseline.isEmpty else { return }

        for key in Self.watchedKeys {
            let newValue = current[key]
            let oldValue = baseline[key]
            guard newValue != oldValue else { continue }
            // 键消失也算一次改动（例如 pmset 不再输出它）。
            recordChange(key: key, oldValue: oldValue, newValue: newValue ?? "（无）")
        }
    }

    /// 通知监控器「这个键是 Deep Sleep 自己写的」，避免误报。
    func noteSelfWrite(key: String, value: String) {
        selfWrites[key] = value
        baseline[key] = value
    }

    private func recordChange(key: String, oldValue: String?, newValue: String) {
        // 自己写的改动也要记录 —— 用户需要看到完整的时间线，
        // 只是要标明来源，而不是从列表里抹掉。
        let bySelf = selfWrites[key] == newValue
        if bySelf { selfWrites.removeValue(forKey: key) }

        let dedupeKey = "\(key)=\(newValue)"
        if let last = recentKeys[dedupeKey], Date().timeIntervalSince(last) < dedupeWindow {
            return
        }
        recentKeys[dedupeKey] = Date()

        changes.insert(
            PowerSettingChange(date: Date(), key: key,
                               oldValue: oldValue, newValue: newValue, bySelf: bySelf),
            at: 0
        )
        if changes.count > maxChanges {
            changes.removeLast(changes.count - maxChanges)
        }
    }

    func clearChanges() {
        changes.removeAll()
        recentKeys.removeAll()
    }

    // MARK: - 断言枚举

    /// 枚举当前所有持有电源断言的进程。
    static func currentBlockers() -> [SleepBlocker] {
        var rawDict: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsByProcess(&rawDict)
        guard result == kIOReturnSuccess, let unmanaged = rawDict else { return [] }
        // Copy 规则：+1 引用，交给 ARC。CFDictionary 与 NSDictionary
        // 是 toll-free bridged，直接转换即可（用 as? 会被编译器警告恒真）。
        let byProcess = unmanaged.takeRetainedValue() as NSDictionary

        let ownPID = getpid()
        var found: [SleepBlocker] = []

        for (key, value) in byProcess {
            guard let pidNumber = key as? NSNumber,
                  let list = value as? [[String: Any]] else { continue }
            let pid = pid_t(truncating: pidNumber)

            let assertions = list.map { raw -> AssertionInfo in
                AssertionInfo(
                    type: raw["AssertType"] as? String ?? "?",
                    name: raw["AssertName"] as? String ?? "",
                    reason: raw["HumanReadableReason"] as? String ?? "",
                    level: (raw["AssertLevel"] as? NSNumber)?.intValue ?? -1
                )
            }
            // 只保留真正和睡眠有关的进程，UserIsActive 之类的噪声不要。
            let relevant = assertions.filter {
                $0.preventsSystemSleep || $0.preventsDisplaySleepOnly
            }
            guard !relevant.isEmpty else { continue }

            let name = processName(for: pid)
            found.append(SleepBlocker(
                pid: pid,
                name: name,
                assertions: relevant,
                isSelf: pid == ownPID || name == "deepsleep-helper"
            ))
        }

        return found.sorted { lhs, rhs in
            if lhs.isPreventingSystemSleep != rhs.isPreventingSystemSleep {
                return lhs.isPreventingSystemSleep
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 进程显示名。
    /// `NSRunningApplication` 对 powerd、coreaudiod 这类系统守护进程返回 nil，
    /// 所以退回用 libproc 取可执行文件路径的末段。
    static func processName(for pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return "pid \(pid)"
        }
        let path = String(cString: buffer)
        let leaf = (path as NSString).lastPathComponent
        return leaf.isEmpty ? "pid \(pid)" : leaf
    }
}
