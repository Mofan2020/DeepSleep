//
//  ExternalCommand.swift
//  Deep Sleep
//
//  跑外部命令的统一封装：不占用任何 dispatch 线程等命令结束。
//
//  ## 为什么需要它（v1.11.4 修的「整个未响应」）
//
//  旧实现在 `DispatchQueue.global()` 的线程上同步等命令结束，同时又把
//  「读管道」派到**同一个**全局队列：
//
//      DispatchQueue.global(qos: .userInitiated).async {
//          // 跑命令、轮询进程状态
//          group.wait()          // ← 阻塞占住这条全局队列线程
//      }
//      DispatchQueue.global(qos: .utility).async {
//          outPipe.fileHandleForReading.readDataToEndOfFile()   // ← 排在同一个队列
//          group.leave()
//      }
//
//  扫 /24 时 64 路 ping 并发，**正好占满 libdispatch 根队列的 64 个线程
//  软上限**（`sample` 会报 "Dispatch Thread Soft Limit: 64 reached"）。
//  64 条线程全卡在 `group.wait()` 上等读管道，而读管道的任务排在同一个
//  队列里拿不到线程 —— 双方互等，死锁。
//
//  死锁的后果不限于这一页：全局队列是整个 App 共用的，助手通信
//  （`HelperClient.send`）、温度监控、系统监控、界面刷新全靠它。
//  全局队列一停摆，**整个程序看起来就没响应了** —— 正是用户报的现象。
//
//  ## 现在的做法
//
//    - 等进程退出用 `terminationHandler`（回调），不用 `waitUntilExit()`；
//    - 要输出时走临时文件，不用管道 —— 免掉「读端 / 写端」这一层麻烦，
//      也免掉子进程写满管道缓冲区卡在 write 上的死锁；
//    - 超时用本文件自带的**专用串行队列**定时，不碰全局队列 ——
//      全局队列被占满时定时器跟着停摆，正好是最需要它的时候。
//
//  结果：一条命令从启动到拿到结果，**不占一条 dispatch 线程**。
//

import Foundation

// MARK: - 结果

/// 一次外部命令的执行结果。
public struct ExternalCommandResult: Sendable {

    /// 退出码。启动失败时是 -1。
    public let status: Int32
    /// 标准输出。
    public let stdout: String
    /// 标准错误。
    public let stderr: String
    /// 是否超时（超时后会被 terminate / SIGKILL 收掉）。
    public let timedOut: Bool
    /// 启动失败时的原因。成功启动就是 nil。
    public let launchFailure: String?

    public init(status: Int32,
                stdout: String = "",
                stderr: String = "",
                timedOut: Bool = false,
                launchFailure: String? = nil) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.launchFailure = launchFailure
    }

    /// 命令成功跑完（没超时、没启动失败）。
    public var succeeded: Bool { !timedOut && launchFailure == nil }
}

// MARK: - 状态机

/// 一次命令执行的状态机。线程安全，保证 continuation **只恢复一次**。
///
/// 谁会来唤醒它：`terminationHandler`（进程退出）、超时定时器（兜底）。
/// 两者都可能先到，所以必须有「已恢复就忽略后来者」的判定。
private final class ExternalCommandState: @unchecked Sendable {

    private let lock = NSLock()
    private var resolved = false
    private var status: Int32 = -1
    private var timedOut = false
    private var continuation: CheckedContinuation<(status: Int32, timedOut: Bool), Never>?

    /// 恢复等待方（如果还没恢复过）。
    func resolve(status: Int32, timedOut: Bool) {
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        self.status = status
        self.timedOut = timedOut
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: (status, timedOut))
    }

    /// 挂上等待方。如果命令早就结束了，立刻恢复。
    func attach(_ continuation: CheckedContinuation<(status: Int32, timedOut: Bool), Never>) {
        lock.lock()
        if resolved {
            let finished = (status, timedOut)
            lock.unlock()
            continuation.resume(returning: finished)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }
}

// MARK: - 执行器

/// 外部命令执行器。
public enum ExternalCommand {

    /// 超时定时器用的**专用串行队列**。
    ///
    /// 不用 `DispatchQueue.global()`：全局队列的线程被占满时，
    /// 派到它上面的定时器会跟着停摆 —— 那正是最需要超时兜底的时候。
    /// 串行队列有自己的线程，不占全局队列。
    private static let timerQueue = DispatchQueue(
        label: "com.skyc8266.deepsleep.command.timer",
        qos: .utility
    )

    /// 跑一个外部命令，等它退出。
    ///
    /// - Parameters:
    ///   - executable: 可执行文件绝对路径。
    ///   - arguments: 参数数组（不过 shell）。
    ///   - timeout: 硬上限（秒）。到点就 terminate，0.5 秒后 SIGKILL。
    ///   - captureOutput: 要不要收回标准输出 / 标准错误。
    ///     不需要输出时直接丢进 `/dev/null`，省掉临时文件。
    ///
    /// - Returns: 退出码与输出。启动失败时 `launchFailure` 有值。
    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        captureOutput: Bool = true
    ) async -> ExternalCommandResult {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // 不继承 stdin：有的命令会等输入，继承终端就会永远挂着。
        process.standardInput = FileHandle.nullDevice

        // 输出落临时文件。不用管道 —— 管道要另起线程去读，而那个线程
        // 不能占全局队列（见文件头）。临时文件没有这个问题：
        // 进程写完退出，之后直接读文件。
        var outURL: URL?
        var errURL: URL?
        if captureOutput {
            let directory = FileManager.default.temporaryDirectory
            let stem = "deepsleep-cmd-\(UUID().uuidString)"
            outURL = directory.appendingPathComponent("\(stem).out")
            errURL = directory.appendingPathComponent("\(stem).err")
            FileManager.default.createFile(atPath: outURL!.path, contents: nil)
            FileManager.default.createFile(atPath: errURL!.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: outURL!) {
                process.standardOutput = handle
            } else {
                process.standardOutput = FileHandle.nullDevice
            }
            if let handle = try? FileHandle(forWritingTo: errURL!) {
                process.standardError = handle
            } else {
                process.standardError = FileHandle.nullDevice
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        let state = ExternalCommandState()

        // 进程退出由回调通知 —— 不占线程。
        process.terminationHandler = { finished in
            state.resolve(status: finished.terminationStatus, timedOut: false)
        }

        do {
            try process.run()
        } catch {
            cleanup(outURL, errURL)
            return ExternalCommandResult(status: -1,
                                         stderr: error.localizedDescription,
                                         launchFailure: "无法启动 \(executable)：\(error.localizedDescription)")
        }

        // 超时兜底。用专用队列，不碰全局队列。
        timerQueue.asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            process.terminate()
            timerQueue.asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            state.resolve(status: -1, timedOut: true)
        }

        let outcome = await withCheckedContinuation { continuation in
            state.attach(continuation)
        }

        // 输出文件在进程退出后才有最终内容。超时那次可能只写了一部分，
        // 那是超时该有的结果，不是 bug。
        let outText = readText(outURL)
        let errText = readText(errURL)
        cleanup(outURL, errURL)

        return ExternalCommandResult(status: outcome.status,
                                     stdout: outText,
                                     stderr: errText,
                                     timedOut: outcome.timedOut)
    }

    /// 读一个临时文件的内容。读不到返回空串。
    private static func readText(_ url: URL?) -> String {
        guard let url else { return "" }
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 删掉临时文件。
    private static func cleanup(_ urls: URL?...) {
        for url in urls {
            guard let url else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
