//
//  ProcessSnapshot.swift
//  Deep Sleep
//
//  抓取当前所有进程的 RSS / CPU% / 启动时间，供系统过载监控与
//  内存泄漏检测使用。**应用与特权助手编译同一份。**
//
//  这份实现只为「监控场景」服务，所以：
//    - 不读其他用户的进程（proc_pidinfo 会返回 ESRCH，直接跳过）；
//    - 不读内核线程（监控的是用户态任务，不是系统调度）；
//    - 不维护历史进程表（应用侧有自己的 LeakDetector 环形缓冲）。
//
//  CPU% 的算法：
//    - 第一次抓时只能拿到当前 CPU 计数，没有「上次」可参考 → 写 0。
//    - 第二次抓开始，用两次采样间隔作为时间窗，用两次 CPU 计数差值除以
//      时间窗，得到百分比。窗口为 0 时写 0（不会除零）。
//    - 多核机器上单进程 CPU% 可达 N×100；监控侧再做聚合。
//
//  助手进程必须单线程访问这个快照（自身就有并发连接），用一个 actor 包裹。
//

import Foundation
import Darwin

public actor ProcessSnapshotCache {

    public static let shared = ProcessSnapshotCache()

    private struct Sample {
        let cpuTime: UInt64
        let timestamp: TimeInterval
    }

    private var lastSamples: [pid_t: Sample] = [:]

    /// 抓一份新快照。CPU% 基于上一次缓存；首次调用的记录写 0。
    ///
    /// CPU% 的口径：**0–100 表示「整个 CPU」用了多少**，不看核心数。
    ///   - 100% = 全机所有核都跑满
    ///   - 50%  = 8 核机器相当于 4 核跑满（也相当于所有核都用一半）
    /// 转换：
    ///   per-core percent = delta_cpu_nanos / dt_seconds / 1e7
    ///   whole-cpu percent = per-core percent / coreCount
    /// coreCount 用 `hw.ncpu` 一次缓存，整个 [ThermalBoard] 寿命内不变。
    public func snapshot(now: TimeInterval = Date().timeIntervalSince1970) -> [ProcessStats.Record] {
        let coreCount = Self.cpuCoreCount()
        let current = Self.collectRaw()
        var records: [ProcessStats.Record] = []
        records.reserveCapacity(current.count)

        for raw in current {
            let cpuPercent: Double
            if let last = lastSamples[raw.pid] {
                let dt = now - last.timestamp
                // pti_total_user / pti_total_system 单位是**纳秒**（mach 绝对时间）。
                // per-core 单核 100% = 1 秒内 1e9 纳秒；多核可叠加 → per-core percent。
                // whole-cpu = per-core / coreCount，锁在 0–100。
                let dCpu = raw.cpuTime >= last.cpuTime ? raw.cpuTime - last.cpuTime : 0
                let perCore = dt > 0 ? Double(dCpu) / dt / 10_000_000.0 : 0
                cpuPercent = coreCount > 0 ? perCore / Double(coreCount) : 0
            } else {
                cpuPercent = 0
            }
            records.append(ProcessStats.Record(
                pid: raw.pid,
                name: raw.name,
                rssBytes: raw.rssBytes,
                cpuPercent: cpuPercent,
                startTime: raw.startTime
            ))
        }

        // 用本轮快照替换缓存 —— 只保留本次抓到的进程。
        var next: [pid_t: Sample] = [:]
        for raw in current {
            next[raw.pid] = Sample(cpuTime: raw.cpuTime, timestamp: now)
        }
        lastSamples = next

        return records
    }

    /// 物理 CPU 核心数（hw.ncpu）。读不到时回 1（保守值：避免 per-core / 0）。
    private static var _coreCountCached: Int?
    private static func cpuCoreCount() -> Int {
        if let cached = _coreCountCached { return cached }
        var count: Int32 = 0
        var sizeLen = MemoryLayout<Int32>.size
        let ret = sysctlbyname("hw.ncpu", &count, &sizeLen, nil, 0)
        let value = ret == 0 && count > 0 ? Int(count) : 1
        _coreCountCached = value
        return value
    }

    // MARK: - 原始采集

    private struct RawSample {
        let pid: pid_t
        let name: String
        let rssBytes: UInt64
        let cpuTime: UInt64
        let startTime: Int64
    }

    /// 抓一次原始数据，不算 CPU%。
    /// 读不到的进程（其他用户、内核线程）静默跳过。
    private static func collectRaw() -> [RawSample] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        guard count > 0 else { return [] }

        var result: [RawSample] = []
        result.reserveCapacity(count)
        for i in 0..<min(count, pids.count) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            if let raw = describe(pid: pid) {
                result.append(raw)
            }
        }
        return result
    }

    private static func describe(pid: pid_t) -> RawSample? {
        // 进程名：p_comm 限长 16 字节，最稳定也最省权限。
        var comm = [CChar](repeating: 0, count: 32)
        let commLen = proc_name(pid, &comm, UInt32(comm.count))
        let name: String
        if commLen > 0 {
            name = String(cString: comm)
        } else {
            name = "pid \(pid)"
        }

        // RSS 与 CPU 计数：走 proc_pidinfo. PROC_PIDTBSDINFO 拿 BSD info，
        // PROC_PIDTASKINFO 拿 task 维度的 resident size 与 CPU 计数。
        // 这两个 flavor 在 libproc.h 里定义；Swift 能直接看到 PROC_PIDTBSDINFO，
        // PROC_PIDTASKINFO 是按宏展开的常数。
        var info = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bsdResult = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, bsdSize)
        guard bsdResult == bsdSize else {
            return nil
        }

        var tinfo = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let taskResult = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &tinfo, taskSize)
        // PROC_PIDTASKINFO 对内核线程也会成功（但 pti_resident_size 是 0）；
        // RSS 为 0 且 CPU 计数为 0 视为不可读。
        let rssBytes = taskResult == taskSize
            ? UInt64(tinfo.pti_resident_size) : 0
        let cpuTime: UInt64
        if taskResult == taskSize {
            cpuTime = UInt64(tinfo.pti_total_system) + UInt64(tinfo.pti_total_user)
        } else {
            cpuTime = 0
        }

        let startTime = Int64(info.pbi_start_tvsec)

        return RawSample(
            pid: pid,
            name: name,
            rssBytes: rssBytes,
            cpuTime: cpuTime,
            startTime: startTime
        )
    }
}