//
//  ProcessPriority.swift
//  Shared
//
//  进程 nice 值（POSIX 优先级）的封装。**应用与特权助手共用。**
//
//  为什么放 Shared：
//    - 应用侧只读 nice 不需要特权；
//    - 写 nice 必须 root（即使是「调高」降低优先级，正值仍要 root，
//      这是 POSIX 的硬约束，macOS 也沿用）；
//    - 应用与助手共用「合法范围」「解析错误」「系统进程判定」
//      三个判据，避免两边各写一份后规则漂移。
//
//  nice 与真实性的边界：
//    - nice ∈ [-20, 19]，其中 -20 = 最高优先级、19 = 最低优先级。
//    - 应用**只能调高**优先级（正值，>0）而不需要特权；
//      调低（负值，<0）任何 nice 都要求 root。
//    - 我们在助手侧集中做 root 校验；应用只能给 pid + 期望值，
//      不预判能不能改（与 `terminateProcesses` 同模式）。
//
//  「系统进程」的边界（与 `ProcessGuard` 共享）：
//    - 可执行文件路径落在 `/System/Library/*` / `/usr/libexec/*` /
//      `/usr/sbin/*` / `/usr/bin/` 的属于系统关键进程；
//    - bundle id 以 `com.apple.` 开头、或 Info.plist 里
//      `LSUIElement` 之外、签名是 Apple 出品的 app 也按系统进程处理；
//    - 这些进程**拒绝**改 nice（助手侧校验）。原因详见 README
//      「进程优先级（nice）」一节的告警。
//
//

import Foundation
import Darwin

/// nice 值的合法范围。POSIX.1 定义的硬下/上限。
public enum NiceLevel {
    public static let minValue: Int = -20
    public static let maxValue: Int = 19
    public static let defaultValue: Int = 0

    /// 解析用户输入或命令行传入的字符串。
    /// 接受十进制整数、可选带 `+` 前缀；其余一律失败。
    public static func parse(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let signed = trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
        guard let value = Int(signed) else { return nil }
        guard value >= minValue, value <= maxValue else { return nil }
        return value
    }

    /// 字符串化。
    public static func format(_ value: Int) -> String {
        "\(value >= 0 ? "+" : "")\(value)"
    }
}

/// POSIX nice 操作封装。`which` 限定为 `PRIO_PROCESS`（单进程），
/// 其它维度（PRIO_PGRP / PRIO_USER）有授权范围更广的副作用，
/// 本工具不开放。
public enum ProcessPriority {

    /// 读 nice。失败（进程已退出 / 权限不足）返回 nil。
    public static func nice(of pid: pid_t) -> Int? {
        errno = 0
        let value = getpriority(PRIO_PROCESS, id_t(pid))
        if errno != 0 { return nil }
        // `getpriority` 的返回是 -20..19，但 C 接口用 id_t = Int32，
        // 这里把 -1 与「合法 -1」区分开：errno 已被上面清零，
        // 失败时 errno != 0。所以不需要额外处理 -1 的歧义。
        return Int(value)
    }

    /// 写 nice。返回是否成功，失败原因放在 `error` 里。
    ///
    /// 这里不做「能不能改」的判定 —— 那是 `ProcessGuard.canChangeNice`
    /// 的职责。本函数假定调用方已校验过目标不是系统进程、且目标属于
    /// 调用方有权操作的 uid。
    @discardableResult
    public static func setNice(_ value: Int, of pid: pid_t) -> Result<Int, ErrorReason> {
        guard value >= NiceLevel.minValue, value <= NiceLevel.maxValue else {
            return .failure(.outOfRange(value))
        }
        errno = 0
        let rc = setpriority(PRIO_PROCESS, id_t(pid), Int32(value))
        if rc != 0 {
            let code = errno
            return .failure(.posix(code))
        }
        // 再读一次回执 —— 进程在我们 set 期间退出会读不到，
        // 那是「设置完了但立刻死了」，按成功报告、UI 自检时再核对。
        let verified = ProcessPriority.nice(of: pid) ?? value
        return .success(verified)
    }

    public enum ErrorReason: Error, CustomStringConvertible, Equatable {
        case outOfRange(Int)
        case posix(Int32)

        public var description: String {
            switch self {
            case .outOfRange(let v):
                return "nice 值 \(v) 超出范围 [\(NiceLevel.minValue), \(NiceLevel.maxValue)]"
            case .posix(let code):
                let message = String(cString: strerror(code))
                return "setpriority 失败（errno \(code)：\(message)）"
            }
        }
    }
}
