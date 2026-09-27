//
//  test-selfupdate.swift
//  Deep Sleep 回归测试
//
//  验证助手自我更新的四条校验 —— 这是全项目权限最高的一条路径
//  （它能把一个 root 二进制写进 /Library），任何一条校验失效都意味着
//  本地用户可以直接提权。
//
//  运行：
//    swiftc Shared/HelperProtocol.swift DeepSleepHelper/SelfUpdate.swift \
//           scripts/test-selfupdate.swift -o /tmp/utest && /tmp/utest
//

import Foundation

@main
struct SelfUpdateTests {

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

        /// 从 errno 风格的结果里取消息，方便断言。
        func message(_ result: Result<Void, HelperSelfUpdate.Failure>) -> String {
            switch result {
            case .success:                 return "(成功)"
            case .failure(let error):      return error.message
            }
        }

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // scripts/
            .deletingLastPathComponent()          // 项目根
        let debugApp = projectRoot
            .appendingPathComponent("build/Build/Products/Debug/Deep Sleep.app").path
        let legitSource = debugApp + "/Contents/Library/PrivilegedHelperTools/deepsleep-helper"

        print("== 参数缺失 ==")
        check("缺 source",
              message(HelperSelfUpdate.perform(arguments: [:])).contains("缺少 source"))
        check("缺 sha256",
              message(HelperSelfUpdate.perform(arguments: [
                  "source": legitSource, "build": "99"
              ])).contains("sha256"))
        check("sha256 长度不对",
              message(HelperSelfUpdate.perform(arguments: [
                  "source": legitSource, "sha256": "abc", "build": "99"
              ])).contains("sha256"))
        check("缺 build",
              message(HelperSelfUpdate.perform(arguments: [
                  "source": legitSource, "sha256": String(repeating: "a", count: 64)
              ])).contains("build"))

        print("\n== 来源路径校验（防止任意二进制被提权安装）==")
        for bad in [
            "/tmp/evil",
            "/tmp/Deep Sleep.app/Contents/MacOS/Deep Sleep",
            "/tmp/deepsleep-helper",
            "/Users/someone/Downloads/malware.app/Contents/Library/PrivilegedHelperTools/deepsleep-helper/../../evil",
        ] {
            let result = HelperSelfUpdate.perform(arguments: [
                "source": bad,
                "sha256": String(repeating: "a", count: 64),
                "build": "9999",
            ])
            check("拒绝来源 \(bad)", message(result).contains("拒绝"), message(result))
        }

        // 路径像样但 .app 不存在 / bundle id 不对 → 也必须拒绝。
        let fakeApp = "/tmp/NotDeepSleep.app/Contents/Library/PrivilegedHelperTools/deepsleep-helper"
        check("拒绝 bundle id 不匹配（或 Info.plist 缺失）的应用",
              message(HelperSelfUpdate.perform(arguments: [
                  "source": fakeApp,
                  "sha256": String(repeating: "a", count: 64),
                  "build": "9999",
              ])).contains("拒绝"))

        print("\n== 摘要校验 ==")
        if FileManager.default.fileExists(atPath: legitSource) {
            var result = HelperSelfUpdate.perform(arguments: [
                "source": legitSource,
                "sha256": String(repeating: "0", count: 64),
                "build": "9999",
            ])
            check("摘要不匹配时拒绝",
                  message(result).contains("校验和不匹配"), message(result))

            print("\n== 版本校验（防循环的关键：不降级、不重装）==")
            // 摘要对但 build 不大于当前 → 必须拒绝。
            // 用极大 build 才能真正走到「通过校验」那一步 —— 这里反过来验证：
            // 只要 build 不大于当前内置值，就一定被挡在版本校验上。
            for candidate in ["0", "1", "-5"] {
                result = HelperSelfUpdate.perform(arguments: [
                    "source": legitSource,
                    "sha256": digest(of: legitSource),
                    "build": candidate,
                ])
                check("build=\(candidate)（不大于当前 \(HelperConstants.helperBuild)）被拒绝",
                      message(result).contains("构建序号"), message(result))
            }
        } else {
            print("  [跳过] Debug 产物不存在，先构建再跑本测试：\(debugApp)")
        }

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }

    static func digest(of path: String) -> String {
        // 与生产代码一致：用 shasum 算，避免为测试单独引入 CryptoKit 依赖。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: " ").first.map(String.init) ?? ""
    }
}
