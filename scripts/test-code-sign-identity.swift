//
//  test-code-sign-identity.swift
//  Deep Sleep 回归测试
//
//  验证「发布产物的 designated requirement 与二进制内容无关」这条性质。
//
//  为什么要有这个测试：
//
//  Deep Sleep 用 ad-hoc 签名（没有 Developer ID 证书）。ad-hoc 签名的
//  designated requirement 默认是 cdhash（可执行文件的哈希），也就是
//  「这个 App 是哪个 App」每次构建答案都不一样。钥匙串靠 requirement
//  判断来读的是不是同一个应用，于是每次发版都被当成新应用 → 更新后
//  读取 API Key 时弹框要求输入钥匙串密码。
//
//  修法是打包时用 `codesign --requirements '=designated => identifier "..."'`
//  把 requirement 固定成 bundle id。**这条性质必须被锁住**：哪天有人
//  改了打包脚本、或者 CI 换了构建方式，requirement 悄悄变回 cdhash，
//  用户就会重新遇到「每次更新都要输密码」，而代码里没有任何东西会报错。
//
//  这个测试做的是差分：同样两个可执行文件，
//  - 不加 --requirements → 两次签名的 requirement 不同（cdhash 变了）
//  - 加了 --requirements → 两次签名的 requirement 相同（只有 identifier）
//
//  运行：
//  swiftc scripts/test-code-sign-identity.swift -o /tmp/sig-test && /tmp/sig-test
//

import Foundation

@main
struct CodeSignIdentityTests {

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

        // codesign 不在就别装作测过了 —— 直接判失败。
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign") else {
            print("  [失败] 找不到 /usr/bin/codesign，无法验证签名行为")
            print("\n测试结论: 1 项失败")
            exit(1)
        }

        let work = "/tmp/ds-sigtest"
        try? FileManager.default.createDirectory(
            atPath: work, withIntermediateDirectories: true)

        let identifier = "com.skyc8266.deepsleep.sigtest"

        /// 造一个可签名的最小 bundle，返回它的可执行文件路径。
        func makeApp(_ name: String, padding: Int) -> String? {
            let app = "\(work)/\(name).app"
            let macOS = "\(app)/Contents/MacOS"
            let bin = "\(macOS)/Probe"
            try? FileManager.default.createDirectory(
                atPath: macOS, withIntermediateDirectories: true)

            // 可执行文件内容必须每次不同，才能让 cdhash 变化。
            var bytes = Data(repeating: 0x41, count: 64 + padding)
            bytes.append(contentsOf: [0x00, 0x01, 0x02, 0x03])
            try? bytes.write(to: URL(fileURLWithPath: bin))

            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(identifier)</string>
            <key>CFBundleExecutable</key><string>Probe</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            </dict></plist>
            """
            try? plist.write(to: URL(fileURLWithPath: "\(app)/Contents/Info.plist"),
                             atomically: true, encoding: .utf8)
            return app
        }

        /// 签名并把 designated requirement 取回来。
        func signAndRequirement(_ app: String, fixed: Bool) -> String? {
            var args = ["/usr/bin/codesign", "--force", "--sign", "-"]
            if fixed {
                args += ["--requirements", "=designated => identifier \"\(identifier)\""]
            }
            args.append(app)
            let status = run(args)
            guard status.status == 0 else { return nil }
            return requirement(of: app)
        }

        /// 读出一个 bundle 的 designated requirement 字符串。
        func requirement(of app: String) -> String? {
            let r = run(["/usr/bin/codesign", "-d", "-r-", app])
            guard r.status == 0 else { return nil }
            // 输出形如 "# designated => cdhash H\"...\""
            for line in r.output.split(separator: "\n") {
                if let range = line.range(of: "designated => ") {
                    return String(line[range.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }

        func run(_ args: [String]) -> (status: Int32, output: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: args[0])
            p.arguments = Array(args.dropFirst())
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do {
                try p.run()
            } catch {
                return (127, "无法启动 \(args[0])")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }

        // ------------------------------------------------ 对照组：默认签名
        guard let appA = makeApp("Plain", padding: 0),
              let appB = makeApp("Plain2", padding: 64) else {
            print("  [失败] 造测试 bundle 失败")
            print("\n测试结论: 1 项失败")
            exit(1)
        }
        let plainA = signAndRequirement(appA, fixed: false)
        let plainB = signAndRequirement(appB, fixed: false)

        check("默认签名能读出 requirement",
              plainA != nil && plainB != nil,
              "A=\(plainA ?? "nil") B=\(plainB ?? "nil")")

        if let a = plainA, let b = plainB {
            check("默认（ad-hoc）签名的 requirement 是 cdhash",
                  a.hasPrefix("cdhash"), a)
            check("二进制内容不同 → 默认 requirement 也不同（这正是问题根源）",
                  a != b, "A=\(a) B=\(b)")
        }

        // ------------------------------------------------ 实验组：固定 identifier
        let fixedA = signAndRequirement(appA, fixed: true)
        let fixedB = signAndRequirement(appB, fixed: true)

        check("加 --requirements 后能签出固定的 requirement",
              fixedA != nil && fixedB != nil,
              "A=\(fixedA ?? "nil") B=\(fixedB ?? "nil")")

        if let a = fixedA, let b = fixedB {
            check("固定后的 requirement 是 identifier 而不是 cdhash",
                  a.contains("identifier"), a)
            check("固定后的 requirement 内容正是 bundle id",
                  a.contains(identifier), a)
            check("两个不同二进制得到**同一个** requirement（更新后不会失配）",
                  a == b, "A=\(a) B=\(b)")
        }

        // ------------------------------------------------ 再签一次：模拟下次发版
        //
        // 这一步是整个测试的关键：不是「两个不同的 app」，
        // 而是**同一个 app 被重新签一次**（构建产物每次都不一样）。
        guard let appC = makeApp("Same", padding: 0) else {
            print("  [失败] 造测试 bundle 失败")
            print("\n测试结论: 1 项失败")
            exit(1)
        }
        let firstSign = signAndRequirement(appC, fixed: true)
        // 改内容 → cdhash 变 → 重新签名
        var bytes = Data(repeating: 0x42, count: 256)
        try? bytes.write(to: URL(fileURLWithPath: "\(appC)/Contents/MacOS/Probe"))
        let secondSign = signAndRequirement(appC, fixed: true)

        check("同一个 app 重新签名后 requirement 不变（这才是「更新后不再失配」）",
              firstSign != nil && firstSign == secondSign,
              "第一次=\(firstSign ?? "nil") 第二次=\(secondSign ?? "nil")")

        // ------------------------------------------------ 严格校验仍然通过
        //
        // CI 的发布流程里有 `codesign --verify --deep --strict`。
        // 固定 requirement 之后这条校验还必须过，否则 CI 会红。
        let verify = run(["/usr/bin/codesign", "--verify", "--deep", "--strict", appC])
        check("固定 requirement 后 codesign --verify --deep --strict 仍然通过",
              verify.status == 0, verify.output)

        // ------------------------------------------------ 汇总
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
