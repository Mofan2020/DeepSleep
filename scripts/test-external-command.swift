//
//  test-external-command.swift
//  Deep Sleep
//
//  `ExternalCommand` 的自测：跑命令、拿输出、超时不挂死。
//
//  ## 为什么这层要单独测
//
//  v1.11.4 修的「整个未响应」是**死锁**：旧实现在
//  `DispatchQueue.global()` 的线程上同步等命令结束，同时把读管道的任务
//  派到同一个全局队列。64 路并发正好占满 libdispatch 根队列的 64 个
//  线程软上限，于是「等命令结束」等「读管道」，「读管道」拿不到线程 ——
//  互相死等。全局队列一停摆，整个程序看起来就没响应了。
//
//  这类 bug **光看代码看不出来**（代码是对的，只是并发模型错了），
//  光看「测试通过」也看不出来。所以这个测试要验证的是**并发行为**：
//
//    1. 同时跑 64 个命令时，**全局队列必须还能调度别的任务** ——
//       这是死锁的直接判据。旧实现在这里必然超时。
//    2. 大量并发下本进程的线程数不能失控。
//    3. 命令确实跑完了、退出码和输出都对。
//    4. 超时的命令会自己返回，不会永远挂着。
//
//  运行（不需要 root、不需要网络）：
//  swiftc -parse-as-library DeepSleep/Core/ExternalCommand.swift \
//      scripts/test-external-command.swift -o /tmp/t_extcmd && /tmp/t_extcmd
//

import Foundation

/// 本进程当前的线程数（用 Mach 的 task_threads，够准）。
func currentThreadCount() -> Int {
    var count: mach_msg_type_number_t = 0
    var threads: thread_act_array_t?
    guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS else { return 0 }
    return Int(count)
}

@main
struct ExternalCommandTests {

    static func main() async {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ actual: String = "") {
            if condition {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)" + (actual.isEmpty ? "" : " —— 实际: \(actual)"))
                failures += 1
            }
        }

        // MARK: 基本功能

        print("== 基本功能 ==")

        let echo = await ExternalCommand.run("/bin/echo", ["hello", "world"], timeout: 5)
        check("退出码为 0", echo.status == 0, "实际 \(echo.status)")
        check("标准输出正确", echo.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello world",
              "实际「\(echo.stdout)」")
        check("没有超时", !echo.timedOut)
        check("没有启动失败", echo.launchFailure == nil)

        let stderrResult = await ExternalCommand.run("/bin/sh", ["-c", "echo oops >&2"], timeout: 5)
        check("标准错误被单独捕获", stderrResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == "oops",
              "实际「\(stderrResult.stderr)」")
        check("标准输出里没有 stderr 的内容", stderrResult.stdout.isEmpty,
              "实际「\(stderrResult.stdout)」")

        let missing = await ExternalCommand.run("/nonexistent/binary", [], timeout: 5)
        check("启动失败被如实报告", missing.launchFailure != nil)
        check("启动失败时退出码为 -1", missing.status == -1, "实际 \(missing.status)")

        // MARK: 超时

        print("")
        print("== 超时 ==")

        let start = Date()
        let slow = await ExternalCommand.run("/bin/sleep", ["30"], timeout: 1.5)
        let elapsed = Date().timeIntervalSince(start)
        check("超时的命令会自己返回", slow.timedOut)
        check("超时用时接近设定值（不超过 4 秒）", elapsed < 4.0, String(format: "实际 %.2f 秒", elapsed))
        check("超时标记为失败", !slow.succeeded)

        // MARK: 并发不死锁（核心回归）

        print("")
        print("== 并发不死锁 ==")

        let baselineThreads = currentThreadCount()
        let concurrent = 64

        // 心跳：每 100 毫秒记一次。用来判断全局队列是不是被饿死了。
        //
        // **不能直接数心跳次数** —— 扫描可能只花 0.05 秒就结束，
        // 心跳当然跳不满 3 次，那是测试自己写错了。
        // 正确的判据是「相对基准」：同样长的时间里，扫描期间的心跳
        // 次数与空闲时相比不能塌掉。死锁时全局队列完全停摆，
        // 心跳会停在扫描开始前的那一次。
        let idleHeartbeat = Heartbeat()
        let idleTask = Task {
            while !Task.isCancelled {
                idleHeartbeat.beat()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        // 先跑一小段空闲期，建立基准。
        try? await Task.sleep(nanoseconds: 400_000_000)
        idleTask.cancel()
        let idleBeats = idleHeartbeat.count

        let heartbeatBox = Heartbeat()
        let heartbeatTask = Task {
            while !Task.isCancelled {
                heartbeatBox.beat()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        let scanStart = Date()
        let results = await withTaskGroup(of: Int32.self) { group in
            for index in 0..<concurrent {
                group.addTask {
                    let result = await ExternalCommand.run(
                        "/bin/echo",
                        ["task-\(index)"],
                        timeout: 10,
                        captureOutput: false
                    )
                    return result.status
                }
            }
            var collected: [Int32] = []
            for await status in group {
                collected.append(status)
            }
            return collected
        }
        let scanElapsed = Date().timeIntervalSince(scanStart)

        heartbeatTask.cancel()

        check("64 个命令全部返回", results.count == concurrent, "实际 \(results.count)")
        check("64 个命令全部成功", results.allSatisfy { $0 == 0 })

        // 核心判据：扫描期间全局队列还能调度任务。
        //
        // 死锁时（旧实现）：全局队列的 64 个线程全被「等命令结束」占住，
        // 心跳任务再也调度不上 —— 扫描期间的心跳次数为 0 或 1。
        let beats = heartbeatBox.count
        let expected = max(1, Int(scanElapsed / 0.1))
        check("扫描期间全局队列仍在调度（心跳没有被饿死）",
              beats >= max(1, expected / 2),
              "扫描 \(String(format: "%.2f", scanElapsed)) 秒只跳了 \(beats) 次，"
              + "空闲时同样时长能跳 \(idleBeats) 次")

        // 线程数不能失控 —— 新实现不占 dispatch 线程。
        let peakThreads = heartbeatBox.peakThreads
        check("线程数没有失控", peakThreads < concurrent,
              "峰值 \(peakThreads) 线程，并发 \(concurrent)")

        check("并发扫描在合理时间内完成", scanElapsed < 20.0,
              String(format: "实际 %.2f 秒", scanElapsed))

        print("")
        print("并发 \(concurrent) 个命令：耗时 \(String(format: "%.2f", scanElapsed)) 秒，"
              + "扫描期心跳 \(beats) 次（空闲基准 \(idleBeats) 次 / 0.4 秒），"
              + "峰值线程 \(peakThreads)（基线 \(baselineThreads)）")

        // MARK: 收尾

        print("")
        if failures == 0 {
            print("全部通过")
            exit(0)
        } else {
            print("\(failures) 项失败")
            exit(1)
        }
    }
}

/// 心跳记录器：记下心跳次数与观察到的线程数峰值。
private final class Heartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var beats = 0
    private var peak = 0

    func beat() {
        lock.lock()
        beats += 1
        peak = max(peak, currentThreadCount())
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return beats
    }

    var peakThreads: Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }
}
