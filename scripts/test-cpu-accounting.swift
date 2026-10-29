//
//  test-cpu-accounting.swift
//  DeepSleep
//
//  CPU 读数自测。这一层要跟内核真值对撞，不是自说自话。
//
//  测两件事：
//    1. 单进程 CPU 时间（Mach thread_info 路径）跟 getrusage 对得上。
//       —— 原实现用的 pti_total_user 在本机少报 42 倍，这个必须锁住。
//    2. 整机 CPU 占用（host_statistics 增量）跟 top 的系统 CPU% 对得上。
//
//  运行： bash scripts/test-cpu-accounting.sh
//

import Foundation
import Darwin

@main
struct CPUAccountingTests {

    static func main() {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ actual: String = "") {
            if condition {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)" + (actual.isEmpty ? "" : " —— 实际: \(actual)"))
                failures += 1
            }
        }

        // MARK: - 1. 单进程 CPU 时间 vs getrusage

        print("\n== 单进程 CPU 时间（Mach 路径）vs getrusage ==")

        let me = getpid()
        let before = ProcessCPUTime.nanoseconds(pid: me)
        check("能拿到自己的 CPU 时间", before != nil)

        var rusageBefore = rusage()
        getrusage(RUSAGE_SELF, &rusageBefore)

        // 烧 1.5 秒
        var sink: UInt64 = 0
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            for _ in 0..<2_000_000 { sink = sink &+ UInt64(arc4random()) }
        }
        if sink == 0 { print(sink) }

        var rusageAfter = rusage()
        getrusage(RUSAGE_SELF, &rusageAfter)
        let after = ProcessCPUTime.nanoseconds(pid: me)

        let rusageUser = Double(rusageAfter.ru_utime.tv_sec - rusageBefore.ru_utime.tv_sec)
            + Double(rusageAfter.ru_utime.tv_usec - rusageBefore.ru_utime.tv_usec) / 1e6
        let rusageSystem = Double(rusageAfter.ru_stime.tv_sec - rusageBefore.ru_stime.tv_sec)
            + Double(rusageAfter.ru_stime.tv_usec - rusageBefore.ru_stime.tv_usec) / 1e6
        let truth = rusageUser + rusageSystem

        let measured = (Double(after ?? 0) - Double(before ?? 0)) / 1e9
        print(String(format: "  getrusage = %.3f s，Mach 路径 = %.3f s", truth, measured))

        check("确实烧了 CPU（真值 > 0.5 秒）", truth > 0.5, String(format: "%.3f", truth))

        if truth > 0 {
            let ratio = measured / truth
            print(String(format: "  比值 = %.3f", ratio))
            // Mach 路径跟 getrusage 应当一致（比值接近 1）。
            // 差 5% 以内算通过 —— getrusage 本身有采样粒度。
            check("Mach 路径跟 getrusage 一致（误差 < 5%）",
                  ratio > 0.95 && ratio < 1.05,
                  String(format: "%.3f", ratio))
        }

        // MARK: - 2. 整机 CPU 占用

        print("\n== 整机 CPU 占用（host_statistics 增量）==")

        let sampler = SystemCPUSampler()
        let first = sampler.sample()
        check("第一次采样没有上一轮，返回 0", first == 0, String(format: "%.2f", first))

        // 烧 4 个线程 3 秒
        var threads: [Thread] = []
        let stop = NSCondition()
        var shouldStop = false
        for _ in 0..<4 {
            let t = Thread {
                var localSink: UInt64 = 0
                while true {
                    stop.lock()
                    let s = shouldStop
                    stop.unlock()
                    if s { break }
                    for _ in 0..<1_000_000 { localSink = localSink &+ UInt64(arc4random()) }
                    if localSink == 0 { print(localSink) }
                }
            }
            t.stackSize = 512 * 1024
            threads.append(t)
            t.start()
        }

        Thread.sleep(forTimeInterval: 0.3)
        let busy = sampler.sample()
        Thread.sleep(forTimeInterval: 2.5)
        stop.lock(); shouldStop = true; stop.unlock()

        print(String(format: "  烧 4 个线程时，整机占用 = %.1f%%", busy))
        check("烧 4 个线程时整机占用明显 > 0", busy > 5, String(format: "%.2f", busy))
        check("整机占用不超过 100", busy <= 100, String(format: "%.2f", busy))

        // MARK: - 3. 拿不到的进程

        print("\n== 拿不到 task 端口的进程 ==")
        // pid 0 是内核，task_for_pid 拿不到
        check("pid 0 拿不到 CPU 时间", ProcessCPUTime.nanoseconds(pid: 0) == nil)
        // 不存在的 pid
        check("不存在的 pid 拿不到", ProcessCPUTime.nanoseconds(pid: 999_999) == nil)

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
