//
//  test-disk-idle-assertion.swift
//  DeepSleep
//
//  验证「阻止外部磁盘空闲休眠」这个 assertion 在普通用户进程里真的能用。
//
//  为什么值得单独测：
//  这一项和别的 assertion 不同 —— 它不需要 root（kIOPMAssertPreventDiskIdle
//  是 IOPMAssertionCreateWithName 的普通用户级 assertion），但它能不能在
//  这台机器上生效、有没有真的登记进系统，是可以验的。
//  只验「调用没抛错」是不够的：那可能只是一个被系统忽略的空请求。
//  所以这里做三件事：创建 → 用 pmset -g assertions 确认系统认了 → 释放 → 再确认它没了。
//
//  运行： bash scripts/test-disk-idle-assertion.sh
//

import Foundation
import IOKit.pwr_mgt

@main
struct DiskIdleAssertionTests {

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

        // MARK: - 前置：pmset 能读到 assertions

        print("\n== 前置检查 ==")

        let baseline = pmsetAssertions()
        check("pmset -g assertions 可读", baseline != nil)

        // MARK: - 创建

        print("\n== 创建 assertion ==")

        var identifier = IOPMAssertionID(0)
        let createResult = IOPMAssertionCreateWithName(
            kIOPMAssertPreventDiskIdle as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Deep Sleep - prevent disk idle" as CFString,
            &identifier
        )

        check("创建返回 kIOReturnSuccess",
              createResult == kIOReturnSuccess,
              "0x\(String(UInt32(bitPattern: createResult), radix: 16))")

        guard createResult == kIOReturnSuccess else {
            print("\n测试结论: \(failures) 项失败（无法继续验证）")
            exit(1)
        }
        check("assertion id 非零", identifier != 0, "\(identifier)")

        // MARK: - 系统是否真的认了

        print("\n== 系统登记验证 ==")

        let withAssertion = pmsetAssertions() ?? ""
        check("pmset -g assertions 里出现 PreventDiskIdle",
              withAssertion.contains("PreventDiskIdle"))
        check("登记的进程名正确",
              withAssertion.contains("prevent disk idle"),
              "没找到断言名")

        // MARK: - 释放

        print("\n== 释放 ==")

        let releaseResult = IOPMAssertionRelease(identifier)
        check("释放返回 kIOReturnSuccess",
              releaseResult == kIOReturnSuccess,
              "0x\(String(UInt32(bitPattern: releaseResult), radix: 16))")

        let afterRelease = pmsetAssertions() ?? ""
        check("释放后从 pmset 输出里消失",
              !afterRelease.contains("PreventDiskIdle"))

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }

    /// 读 `pmset -g assertions` 的输出。
    private static func pmsetAssertions() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
