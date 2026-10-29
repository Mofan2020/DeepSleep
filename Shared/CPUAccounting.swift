//
//  CPUAccounting.swift
//  Deep Sleep
//
//  CPU 占用的两套读数。**应用与特权助手编译同一份。**
//
//  # 为什么不用 proc_pidinfo 的 pti_total_user
//
//  原实现用 `proc_taskinfo.pti_total_user + pti_total_system` 算 CPU%，
//  在 macOS 27.2（本机实测）上这个计数是**错的**：
//
//    - 同进程内对撞：`getrusage` / `CLOCK_PROCESS_CPUTIME_ID` = 2.867 s，
//      `pti_total_user` 只给 0.0688 s，差 42 倍。
//    - `proc_pid_rusage(RUSAGE_INFO_V4)` 给出同样的 0.0688 s —— 两者一致，
//      说明是内核这一条路径的问题，不是解码错。
//    - 横向扫全机进程，差值在 45×–832× 之间漂，不是固定倍率，无法标定。
//    - `getrusage` 与 Mach 的 `thread_info` 比值为 1.000（精确一致）。
//
//  所以：
//    - **单进程 CPU%** 走 Mach：task_for_pid → task_threads →
//      thread_info(THREAD_BASIC_INFO)，把所有线程的 user+system 加起来。
//      需要 root（别的用户的进程拿不到 task 端口），所以只能在助手侧跑。
//    - **整机 CPU%** 走 host_statistics(HOST_CPU_LOAD_INFO)，取两次采样的增量。
//      跟 `top` 对照过：同一时刻 host_statistics 算 86.69%，top 报
//      64.12% user + 24.15% sys = 88.28% 忙，两者一致。
//
//  整机占用**不能**用「把所有进程的 CPU% 加起来」代替：
//  内核时间（kernel_task）不属于任何用户进程，求和会漏掉；
//  而且各进程的 CPU% 口径是「占整机百分比」，加起来的含义也不对。
//

import Foundation
import Darwin

// MARK: - 整机 CPU

/// 整机 CPU 占用采样器。用法：每轮取一次 `sample()`，返回的是「距上一轮」的平均占用。
///
/// 口径与 `top` 一致：0–100，100% = 全机所有核都跑满。
public final class SystemCPUSampler: @unchecked Sendable {

    public static let shared = SystemCPUSampler()

    private var previous: (user: Double, system: Double, idle: Double, nice: Double)?
    private let lock = NSLock()

    public init() {}

    /// 当前整机占用百分比（0–100）。第一次调用没有「上一轮」可比较，返回 0。
    public func sample() -> Double {
        lock.lock()
        defer { lock.unlock() }

        guard let current = Self.readTicks() else { return 0 }
        defer { previous = current }

        guard let last = previous else { return 0 }
        let dUser = current.user - last.user
        let dSystem = current.system - last.system
        let dIdle = current.idle - last.idle
        let dNice = current.nice - last.nice
        let total = dUser + dSystem + dIdle + dNice
        guard total > 0 else { return 0 }
        let busy = (total - dIdle) / total * 100
        return min(100, max(0, busy))
    }

    /// 读一次内核的 CPU 计数。`cpu_ticks` 依次是 user / system / idle / nice。
    private static func readTicks() -> (user: Double, system: Double, idle: Double, nice: Double)? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (Double(info.cpu_ticks.0),
                Double(info.cpu_ticks.1),
                Double(info.cpu_ticks.2),
                Double(info.cpu_ticks.3))
    }
}

// MARK: - 单进程 CPU

/// 读单个进程的 CPU 时间（纳秒），走 Mach 线程路径。
///
/// 只有拿到 task 端口才读得到 —— 别的用户的进程需要 root。
/// 拿不到时返回 nil，调用方应当把该进程的 CPU 记为 0，而不是拿旧计数凑。
public enum ProcessCPUTime {

    /// 进程所有线程的 user + system 时间（纳秒）。
    public static func nanoseconds(pid: pid_t) -> UInt64? {
        var task = task_t()
        guard task_for_pid(mach_task_self_, pid, &task) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, task) }

        var threads: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(task, &threads, &threadCount) == KERN_SUCCESS,
              let threadList = threads else { return nil }

        defer {
            for index in 0..<Int(threadCount) {
                mach_port_deallocate(mach_task_self_, threadList[index])
            }
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: threadList),
                          vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_act_t>.size))
        }

        var total: UInt64 = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info_data_t()
            // THREAD_BASIC_INFO_COUNT 是带 cast 的宏，Swift 导不进来，自己算。
            var infoCount = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { rebound in
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), rebound, &infoCount)
                }
            }
            guard kr == KERN_SUCCESS else { continue }
            total += timeValue(info.user_time)
            total += timeValue(info.system_time)
        }
        return total
    }

    /// `time_value_t`（秒 + 微秒）转纳秒。
    private static func timeValue(_ value: time_value_t) -> UInt64 {
        let seconds = value.seconds > 0 ? UInt64(value.seconds) : 0
        let micros = value.microseconds > 0 ? UInt64(value.microseconds) : 0
        return seconds * 1_000_000_000 + micros * 1_000
    }
}
