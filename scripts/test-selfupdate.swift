//
//  test-selfupdate.swift
//  Deep Sleep 回归测试
//
//  验证助手自我更新的三条校验 —— 这是全项目权限最高的一条路径
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

        func message(_ result: Result<Void, HelperSelfUpdate.Failure>) -> String {
            switch result {
            case .success:            return "(成功)"
            case .failure(let error): return error.message
            }
        }

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // scripts/
            .deletingLastPathComponent()          // 项目根
        let debugApp = projectRoot
            .appendingPathComponent("build/Build/Products/Debug/Deep Sleep.app").path
        let legitSource = debugApp + "/Contents/Library/PrivilegedHelperTools/deepsleep-helper"
        let goodDigest = digest(of: legitSource)

        print("== 参数缺失 ==")
        check("缺 source",
              message(HelperSelfUpdate.perform(arguments: [:])).contains("缺少 source"))
        check("缺 sha256",
              message(HelperSelfUpdate.perform(arguments: ["source": legitSource]))
                  .contains("sha256"))
        check("sha256 长度不对",
              message(HelperSelfUpdate.perform(arguments: [
                  "source": legitSource, "sha256": "abc"
              ])).contains("sha256"))

        print("\n== 来源路径校验（防止任意二进制被提权安装）==")
        for bad in [
            "/tmp/evil",
            "/tmp/Deep Sleep.app/Contents/MacOS/Deep Sleep",
            "/tmp/deepsleep-helper",
            "/Users/someone/Downloads/x.app/Contents/Library/PrivilegedHelperTools/deepsleep-helper/../../evil",
        ] {
            let result = HelperSelfUpdate.perform(arguments: [
                "source": bad,
                "sha256": String(repeating: "a", count: 64),
            ])
            check("拒绝来源 \(bad)", message(result).contains("拒绝"), message(result))
        }

        let fakeApp = "/tmp/NotDeepSleep.app/Contents/Library/PrivilegedHelperTools/deepsleep-helper"
        check("拒绝 bundle id 不匹配（或 Info.plist 缺失）的应用",
              message(HelperSelfUpdate.perform(arguments: [
                  "source": fakeApp, "sha256": String(repeating: "a", count: 64),
              ])).contains("拒绝"))

        print("\n== 摘要校验 ==")
        if !FileManager.default.fileExists(atPath: legitSource) {
            print("  [跳过] Debug 产物不存在，先构建再跑本测试：\(debugApp)")
            print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
            exit(failures == 0 ? 0 : 1)
        }

        var result = HelperSelfUpdate.perform(arguments: [
            "source": legitSource,
            "sha256": String(repeating: "0", count: 64),
        ])
        check("摘要不匹配时拒绝（这是防「损坏或被替换」的那条）",
              message(result).contains("校验和不匹配"), message(result))

        print("\n== 幂等分支 ==")
        // 「来源内容与当前完全相同」这个分支在真实使用中几乎不会被触发：
        // 应用只有在自己内置的那份和装着的那份**不同**时才会发 updateSelf。
        // 它是防御性的 —— 万一应用判断有误，也不该白替换一次、重启一遍进程。
        //
        // 无法用真实文件构造这个用例：合法来源路径必须在 .app 内部，
        // 而「当前这份」在 /Library 下，两个位置的内容天然不同。
        // 所以这里验证能验证的两件事：内容不同时放行，以及校验顺序。
        result = HelperSelfUpdate.perform(arguments: [
            "source": legitSource,
            "sha256": goodDigest,
        ])
        check("内容与当前不同时放行（真实场景正是如此）",
              !message(result).contains("校验和不匹配"), message(result))

        result = HelperSelfUpdate.perform(arguments: [
            "source": "/tmp/copy-of-helper",
            "sha256": goodDigest,
        ])
        check("校验顺序：来源路径非法时先于内容被拒绝",
              message(result).contains("来源不是"), message(result))

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }

    /// 与生产代码一致：用 shasum 算，避免为测试单独引入 CryptoKit 依赖。
    static func digest(of path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
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
