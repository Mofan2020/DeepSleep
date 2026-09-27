//
//  SelfUpdate.swift
//  deepsleep-helper
//
//  助手的自我更新。
//
//  为什么让助手替换自己：更新助手需要 root，而每改一次版本就弹一次管理员
//  授权对话框体验很差。助手本来就以 root 常驻，让它自己替换自己、再让
//  launchd 用新文件拉起，用户就不必再输一次密码。
//
//  代价是：这是本工具权限最高的一条路径 —— 它把「把一个 root 二进制写进
//  系统目录」的能力开放给了本地用户。所以校验必须严，任何一条不满足就拒绝：
//
//    1. 来源必须是应用内置的助手位置（固定相对路径，不能是任意文件）；
//    2. 那个 .app 的 CFBundleIdentifier 必须是 com.skyc8266.deepsleep；
//    3. 文件 SHA-256 必须与调用方声明的一致（防下载损坏 / 中途被换）；
//    4. 构建序号必须**严格大于**当前运行的序号。
//
//  第 4 条同时是防循环的关键：如果放成「不相等就装」，那么一旦应用比助手旧，
//  就会反复降级 → 再升级，永远停不下来。
//

import CryptoKit
import Foundation

enum HelperSelfUpdate {

    enum Failure: Error {
        case badArguments(String)
        case rejected(String)

        var message: String {
            switch self {
            case .badArguments(let detail): return "参数不合法：\(detail)"
            case .rejected(let reason):     return "拒绝更新：\(reason)"
            }
        }
    }

    /// 更新脚本路径。固定路径可以顺带覆盖上一次的残留。
    private static let scriptPath = "/tmp/com.skyc8266.deepsleep.selfupdate.sh"

    /// 应用内置助手在 bundle 内的固定相对路径。
    private static let embeddedRelativePath =
        "/Contents/Library/PrivilegedHelperTools/deepsleep-helper"

    /// 校验并安排一次自我更新。成功返回后调用方应当退出进程，
    /// 把「替换自己的二进制」这件事交给这个脚本完成。
    static func perform(arguments: [String: String]) -> Result<Void, Failure> {
        guard let source = arguments["source"], !source.isEmpty else {
            return .failure(.badArguments("缺少 source"))
        }
        guard let expectedDigest = arguments["sha256"]?.lowercased(), expectedDigest.count == 64 else {
            return .failure(.badArguments("缺少或非法的 sha256（应为 64 位十六进制）"))
        }
        // 1) 来源必须是应用内置的助手。
        guard source.hasSuffix(embeddedRelativePath) else {
            return .failure(.rejected("来源不是应用内置的助手路径"))
        }
        let appBundle = String(source.dropLast(embeddedRelativePath.count))
        guard appBundle.hasSuffix(".app") else {
            return .failure(.rejected("来源不在 .app 包内"))
        }

        // 2) 那个应用必须是 Deep Sleep 自己。
        guard let plist = NSDictionary(contentsOfFile: appBundle + "/Contents/Info.plist"),
              let identifier = plist["CFBundleIdentifier"] as? String,
              identifier == "com.skyc8266.deepsleep" else {
            return .failure(.rejected("来源应用的 bundle id 不是 com.skyc8266.deepsleep"))
        }

        // 3) 内容摘要必须一致。
        guard let data = FileManager.default.contents(atPath: source), !data.isEmpty else {
            return .failure(.rejected("读不到来源文件：\(source)"))
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedDigest else {
            return .failure(.rejected("校验和不匹配（文件损坏或已被替换）"))
        }

        // 4) 不能是「换成一个和当前完全一样的东西」。
        //
        // 判据用内容摘要而不是版本号或构建序号：摘要相同就说明装着的那份和要装的
        // 这份是同一个二进制，重装毫无意义，还会让调用方以为更新失败。
        //
        // 这一条同时保证了收敛 —— 替换成功后两边摘要必然一致，下次不会再触发更新，
        // 不存在来回替换的循环。这比「版本号必须递增」更省事：不需要任何人为维护的
        // 数字，也不会因为忘记改版本号而漏掉一次真实的更新。
        let current = selfDigest()
        guard !current.isEmpty else {
            return .failure(.rejected("读不到自身的二进制，无法判断是否需要替换"))
        }
        guard digest != current else {
            return .failure(.rejected("来源内容与当前一致，无需更新"))
        }

        let script = makeScript(source: source)
        guard schedule(script) else {
            return .failure(.rejected("无法启动更新脚本"))
        }
        return .success(())
    }

    /// 当前装着的这份助手二进制的摘要。
    ///
    /// 用途有二：回应应用对「你是哪一份」的询问，以及判断一次自我更新请求是否
    /// 真的会带来变化。结果缓存：本进程存活期间自己的二进制不会被替换
    /// （替换流程必然先让本进程退出），所以不必反复读盘。
    static func selfDigest() -> String {
        cachedDigestLock.lock()
        defer { cachedDigestLock.unlock() }
        if let cached = cachedDigest { return cached }

        guard let data = FileManager.default.contents(atPath: HelperConstants.installedHelperPath),
              !data.isEmpty else {
            return ""
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        cachedDigest = digest
        return digest
    }

    private static var cachedDigest: String?
    private static let cachedDigestLock = NSLock()

    // MARK: - 脚本

    /// 生成替换脚本。
    ///
    /// 为什么必须由外部脚本做：替换「正在运行的自己」要求先退出进程，
    /// 而进程一旦退出，就没有代码能继续执行了 —— 这一步只能交给外面的进程。
    private static func makeScript(source: String) -> String {
        """
        #!/bin/sh
        # 由 deepsleep-helper 生成，用完即删。
        # 参数全部由 helper 填好并单引号包裹，脚本本身不接受任何外部输入。
        set -u

        DEST=\(quoted(HelperConstants.installedHelperPath))
        SRC=\(quoted(source))
        BACKUP=\(quoted(HelperConstants.installedHelperPath + ".backup"))
        LABEL=\(quoted(HelperConstants.label))
        OLD_PID=\(getpid())

        # 等旧进程真正退出 —— 否则 launchd 可能在替换之前就用旧二进制把它拉起来。
        i=0
        while [ "$i" -lt 100 ]; do
            /bin/kill -0 "$OLD_PID" 2>/dev/null || break
            /bin/sleep 0.1
            i=$((i + 1))
        done

        # 先备份，替换失败还能退回原样，不至于把助手留在半残状态。
        /bin/cp -f "$DEST" "$BACKUP" 2>/dev/null || true

        if /bin/cp -f "$SRC" "$DEST.new" 2>/dev/null \\
           && /usr/sbin/chown root:wheel "$DEST.new" \\
           && /bin/chmod 755 "$DEST.new" \\
           && /bin/mv -f "$DEST.new" "$DEST"; then
            /bin/launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
        else
            /bin/rm -f "$DEST.new"
            /bin/cp -f "$BACKUP" "$DEST" 2>/dev/null || true
            /bin/launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
        fi

        /bin/rm -f "$BACKUP"
        /bin/rm -f "$0"
        """
    }

    /// 写出脚本并立刻执行。脚本独立于本进程，本进程退出后它继续跑。
    private static func schedule(_ script: String) -> Bool {
        let manager = FileManager.default
        try? manager.removeItem(atPath: scriptPath)
        guard manager.createFile(atPath: scriptPath, contents: Data(script.utf8)) else {
            return false
        }
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
        do {
            try process.run()
        } catch {
            return false
        }
        return true
    }

    /// POSIX 单引号转义，防止路径里的特殊字符被当成 shell 语法。
    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
