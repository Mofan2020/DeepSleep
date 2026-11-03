//
//  ExternalCommandLegacy.swift
//  变异测试专用（不入库）。
//
//  这是 v1.11.4 之前的旧实现：同一个 bug 的另一个外壳。
//  用来验证 scripts/test-external-command.swift **真的会红** ——
//  测试绿了不代表它在测东西，必须把实现改坏一次看测试会不会炸。
//

import Foundation

public enum ExternalCommand {

    public struct Result {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public let timedOut: Bool
        public let launchFailure: String?

        /// 命令成功跑完（没超时、没启动失败）。
        public var succeeded: Bool { !timedOut && launchFailure == nil }
    }

    /// 旧实现：在全局队列的线程上同步等命令结束，
    /// 同时把读管道的任务派到**同一个**全局队列。
    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        captureOutput: Bool = true
    ) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(status: -1, stdout: "", stderr: "",
                                                           timedOut: false,
                                                           launchFailure: error.localizedDescription))
                    return
                }
                let group = DispatchGroup()
                var outData = Data()
                var errData = Data()
                let lock = NSLock()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); outData = data; lock.unlock()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); errData = data; lock.unlock()
                    group.leave()
                }
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                var timedOut = false
                if process.isRunning {
                    timedOut = true
                    process.terminate()
                    let hard = Date().addingTimeInterval(0.5)
                    while process.isRunning && Date() < hard {
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                process.waitUntilExit()
                group.wait()
                lock.lock()
                let outText = String(decoding: outData, as: UTF8.self)
                let errText = String(decoding: errData, as: UTF8.self)
                lock.unlock()
                continuation.resume(returning: Result(status: process.terminationStatus,
                                                       stdout: outText,
                                                       stderr: errText,
                                                       timedOut: timedOut,
                                                       launchFailure: nil))
            }
        }
    }
}
