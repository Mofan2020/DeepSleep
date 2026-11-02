//
//  test-keychain-auth-behavior.swift
//  Deep Sleep 回归测试
//
//  实测 macOS 钥匙串的授权判定到底看什么 —— 结论是**看代码签名身份，
//  不看 designated requirement 的声明**。
//
//  背景：Deep Sleep 用 ad-hoc 签名（没有 Developer ID 证书），ad-hoc 的
//  身份就是可执行文件的哈希（cdhash），每次重新构建都变。于是钥匙串
//  每次更新后都认成新应用，读条目时弹框要密码。
//
//  直觉上会想「把 designated requirement 固定成 bundle id 就不变了」。
//  这个测试证明那条路**没用**，免得以后有人再走一遍。
//
//  测试怎么做的：
//  - 造一个真正的 GUI App（走 NSApplication 生命周期）。
//    **这一点是关键**：用命令行二进制放在 .app 里跑，钥匙串记下的
//    「创建者身份」是空的，条目 ACL 也是空的，怎么读都不弹框 ——
//    会得出「根本不会弹框」的错误结论。
//  - 造两个二进制内容不同、但 designated requirement 完全相同
//    （都是 identifier）的 app，A 写条目、B 读。
//  - 如果钥匙串按 requirement 判定，B 应该能直接读到；
//    实际上 B 会挂起 —— 因为它按签名身份判定，两个 app 身份不同。
//
//  挂起是「等待钥匙串弹框要密码」的表现。所以判据是「有没有在
//  短时间内返回」，不是「返回什么状态码」。
//
//  运行：
//  swiftc -parse-as-library scripts/test-keychain-auth-behavior.swift \
//         -o /tmp/kc-auth-test && /tmp/kc-auth-test
//
//  ⚠️ **这个测试会弹钥匙串授权框，要你输密码。**
//
//  它必须弹框才能测出「挂起」—— 而「挂起」正是这个测试要观察的现象。
//  所以它**不能进常规回归**：跑一次就弹一次框，密码长的话每弹一次都是折磨。
//  它已经从 `scripts/run-all-tests.sh` 里移出去了。
//
//  什么时候才跑：
//    - 改了钥匙串相关代码之后；
//    - 有人又想验证「固定 requirement 能不能解决」的时候；
//    - 跑之前先跟用户说一声会弹框。
//
//  跑完记得确认没留下临时条目：
//    security dump-keychain | grep kcauth
//  （正常应该 0 条；不为 0 就用 `security delete-generic-password -s <service> -a acct1` 清）
//

import Foundation

@main
struct KeychainAuthBehaviorTests {

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

        // 没有显式同意就不跑 —— 这个测试的代价是弹框要密码，
        // 不能因为「跑回归顺手」就替用户决定了。
        if ProcessInfo.processInfo.environment["DS_KEYCHAIN_AUTH_TEST"] != "1" {
            print("  [跳过] 这个测试会弹钥匙串授权框（要输密码），默认不跑。")
            print("         确认要跑的话：DS_KEYCHAIN_AUTH_TEST=1 " + (CommandLine.arguments.first ?? "test"))
            print("\n测试结论: 已跳过")
            exit(0)
        }

        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/swiftc") else {
            print("  [失败] 缺少 codesign 或 swiftc，无法验证")
            print("\n测试结论: 1 项失败")
            exit(1)
        }

        let work = "/tmp/ds-kc-auth-test"
        try? FileManager.default.createDirectory(
            atPath: work, withIntermediateDirectories: true)
        let outPath = work + "/out.txt"

        // ---------------------------------------------------- 探针源码
        //
        // 它是**嵌在 Swift 多行字符串里的**，所以内部一律用字符串拼接、
        // 不用插值：写成插值 Swift 会在外层求值（找不到 base/q，编译失败），
        // 转义成双反斜杠又会被 check-docs.py 的「转义插值」规则判为 bug。
        let probeSource = """
        import Foundation
        import Security
        import AppKit

        #if SECOND
        let __variant = "second"
        #else
        let __variant = "first"
        #endif

        final class D: NSObject, NSApplicationDelegate {
            func applicationDidFinishLaunching(_ n: Notification) {
                let a = CommandLine.arguments
                let mode = a.count > 1 ? a[1] : "read"
                let account = a.count > 2 ? a[2] : "acct1"
                let service = a.count > 3 ? a[3] : "svc"
                let outPath = a.count > 4 ? a[4] : "/tmp/ds-kc-auth-out.txt"

                func base() -> [String: Any] {
                    [kSecClass as String: kSecClassGenericPassword,
                     kSecAttrService as String: service,
                     kSecAttrAccount as String: account]
                }

                var out = ""
                if mode == "delete" {
                    let st = SecItemDelete(base() as CFDictionary)
                    out = "delete=" + String(st) + " variant=" + __variant
                } else if mode == "write" {
                    var q = base()
                    q[kSecValueData as String] = Data("v".utf8)
                    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                    let st = SecItemAdd(q as CFDictionary, nil)
                    out = "write=" + String(st) + " variant=" + __variant
                } else {
                    var q = base()
                    q[kSecReturnData as String] = true
                    q[kSecMatchLimit as String] = kSecMatchLimitOne
                    var item: CFTypeRef?
                    let st = SecItemCopyMatching(q as CFDictionary, &item)
                    if st == errSecSuccess {
                        out = "read=0 variant=" + __variant
                    } else {
                        out = "read=" + String(st) + " variant=" + __variant
                    }
                }
                try? out.write(toFile: outPath, atomically: true, encoding: .utf8)
                exit(0)
            }
        }
        let app = NSApplication.shared
        let d = D()
        app.delegate = d
        app.setActivationPolicy(.prohibited)
        app.run()
        """

        let probePath = work + "/probe.swift"
        try? probeSource.write(toFile: probePath, atomically: true, encoding: .utf8)

        /// 编译探针。`second` 决定要不要带 SECOND 宏 ——
        /// 靠它让两个产物内容不同（否则实验没有意义）。
        func compile(_ out: String, second: Bool) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
            p.arguments = ["-O", probePath, "-o", out] + (second ? ["-D", "SECOND=1"] : [])
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }

        let binA = work + "/probeA"
        let binB = work + "/probeB"
        guard compile(binA, second: false), compile(binB, second: true) else {
            print("  [失败] 编译探针失败")
            print("\n测试结论: 1 项失败")
            exit(1)
        }

        let identifier = "com.skyc8266.deepsleep.kcauth"

        /// 造一个带指定 requirement 的 .app。
        func makeApp(_ name: String, binary: String, fixedRequirement: Bool) -> String? {
            let app = work + "/" + name + ".app"
            let macOS = app + "/Contents/MacOS"
            try? FileManager.default.createDirectory(
                atPath: macOS, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(atPath: binary, toPath: macOS + "/Probe")
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(identifier)</string>
            <key>CFBundleExecutable</key><string>Probe</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleName</key><string>Probe</string>
            <key>NSPrincipalClass</key><string>NSApplication</string>
            <key>LSUIElement</key><true/>
            </dict></plist>
            """
            try? plist.write(toFile: app + "/Contents/Info.plist",
                             atomically: true, encoding: .utf8)

            var args = ["/usr/bin/codesign", "--force", "--sign", "-"]
            if fixedRequirement {
                args += ["--requirements",
                         "=designated => identifier \"" + identifier + "\""]
            }
            args.append(app)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: args[0])
            p.arguments = Array(args.dropFirst())
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return app
        }

        /// 读出一个 bundle 的 designated requirement。
        func requirement(of app: String) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["-d", "-r-", app]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            for line in (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n") {
                if let r = line.range(of: "designated => ") {
                    return String(line[r.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }

        /// 跑探针，返回「是否在超时前返回」以及它写下的输出。
        /// 挂起 = 钥匙串在等弹框要密码。
        @discardableResult
        func runProbe(_ app: String, mode: String, account: String,
                      service: String, timeout: TimeInterval) -> (finished: Bool, output: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: app + "/Contents/MacOS/Probe")
            p.arguments = [mode, account, service, outPath]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do { try p.run() } catch { return (true, "") }

            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if p.isRunning {
                p.terminate()
                p.waitUntilExit()
                return (false, "")
            }
            p.waitUntilExit()
            let out = ((try? String(contentsOfFile: outPath, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (true, out)
        }

        /// 文件内容的 sha256。用来确认两个 app 的二进制**确实不一样**
        /// （比大小不可靠 —— 大小可能碰巧相同）。
        func sha256(_ path: String) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
            p.arguments = ["-a", "256", path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do { try p.run() } catch { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let line = (String(data: data, encoding: .utf8) ?? "")
                .split(separator: " ").first.map(String.init) ?? ""
            return line
        }

        // ------------------------------------------------ 造两个 app
        guard let appA = makeApp("AuthA", binary: binA, fixedRequirement: true),
              let appB = makeApp("AuthB", binary: binB, fixedRequirement: true) else {
            print("  [失败] 造测试 app 失败")
            print("\n测试结论: 1 项失败")
            exit(1)
        }

        // ------------------------------------------------ 前置条件
        let reqA = requirement(of: appA)
        let reqB = requirement(of: appB)
        check("两个 app 的 designated requirement 相同",
              reqA != nil && reqA == reqB, "A=" + (reqA ?? "nil") + " B=" + (reqB ?? "nil"))
        check("requirement 内容确实是 identifier",
              (reqA ?? "").contains("identifier"), reqA ?? "nil")

        let hashA = sha256(appA + "/Contents/MacOS/Probe")
        let hashB = sha256(appB + "/Contents/MacOS/Probe")
        check("两个 app 的二进制内容不同（sha256 不同）",
              !hashA.isEmpty && hashA != hashB,
              "A=" + String(hashA.prefix(12)) + " B=" + String(hashB.prefix(12)))

        // ------------------------------------------------ 关键实验
        //
        // service 每次运行都换一个。
        //
        // 为什么不能用固定名字：条目是「上一个版本的这个 app」写的，
        // 删除它同样要钥匙串授权（实测会挂起），所以固定名字会导致
        // 第二次运行时 SecItemAdd 撞上 errSecDuplicateItem。
        let service = "com.skyc8266.deepsleep.kcauth.exp." + UUID().uuidString
        let write = runProbe(appA, mode: "write", account: "acct1",
                             service: service, timeout: 15)
        check("A 能写入条目", write.finished && write.output.contains("write=0"),
              write.output)

        // B 的二进制跟 A 不同，但 requirement 相同。
        // 如果钥匙串按 requirement 判定 → 直接读到；
        // 实际按签名身份判定 → 挂起等密码。
        let read = runProbe(appB, mode: "read", account: "acct1",
                            service: service, timeout: 8)
        check("requirement 相同的另一个 app 读取时**挂起**（说明按签名身份判定，不按 requirement）",
              !read.finished,
              read.finished ? "读到了：" + read.output : "")

        // ------------------------------------------------ 自读对照
        //
        // 同一个 app 读自己写的条目必须能读到 —— 否则上面的「挂起」
        // 可能是别的原因造成的，不能拿来支撑结论。
        let selfRead = runProbe(appA, mode: "read", account: "acct1",
                                service: service, timeout: 8)
        check("同一个 app 读自己写的条目能读到（对照实验）",
              selfRead.finished && selfRead.output.contains("read=0"),
              selfRead.finished ? selfRead.output : "挂起了")

        // ------------------------------------------------ 收尾：删掉临时条目
        //
        // 删除也要钥匙串授权（条目 ACL 里记的是「上一个版本的那个 app」，
        // 现在这个 app 身份又变了）—— 所以这一句**自己也会弹框要密码**。
        //
        // 实测：用户点了「拒绝」之后，SecItemDelete 返回 -128（errSecUserCanceled），
        // 条目就留在钥匙串里了。所以这里必须：
        //   1. 删完**回读确认**真的没了；
        //   2. 没删掉就把 service 名字打出来，让人能手动清。
        let cleanup = runProbe(appA, mode: "delete", account: "acct1",
                               service: service, timeout: 8)
        let stillThere = runProbe(appA, mode: "read", account: "acct1",
                                  service: service, timeout: 5)
        let cleanedUp = stillThere.finished && !stillThere.output.contains("read=0")
        if !cleanedUp {
            print("  [警告] 临时条目没删干净（删除可能被拒绝了），请手动清理：")
            print("         security delete-generic-password -s " + service + " -a acct1")
            if !cleanup.finished {
                print("         （删除本身也挂起了 —— 删除同样要授权，"
                      + "用户点了拒绝就会这样）")
            }
        } else {
            print("  [通过] 临时条目已清理")
        }

        // ------------------------------------------------ 汇总
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
