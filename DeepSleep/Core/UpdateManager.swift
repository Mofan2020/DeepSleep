//
//  UpdateManager.swift
//  Deep Sleep
//
//  应用自身的自动更新：从 GitHub Release 拉取 DeepSleep.zip，校验通过后
//  由一个临时目录里的更新器脚本替换本应用并重新启动。
//
//  更新器为什么必须独立出去：替换「正在运行的自己」要求先退出自己，
//  而进程一旦退出，就没有代码可以继续执行了。所以脚本写在临时目录 ——
//  不能写在 .app 里，因为 .app 正是要被替换掉的东西。
//
//  校验顺序（任何一步不过就放弃，绝不安装）：
//    1. Release 的 tag 能解析出**严格更新**的版本号；
//       解析失败一律当作「没有更新」，绝不当作「有更新」；
//    2. 下载下来的 zip 能解开；
//    3. 解出来的 .app 的 bundle id 正确；
//    4. 解出来的 .app 版本号与 Release 声称的一致；
//    5. 解出来的 .app 能通过 codesign 结构校验；
//    6. Release 若附带 DeepSleep.zip.sha256，则比对摘要。
//
//  链路上每一步都必须是用户看得见的（v1.11.1 修的就是这件事）：
//    检查 → 发现新版本 → **自动下载** → 校验 → （按开关）安装 → 重启
//  以前「自动检查」在下载之前就 return 了 —— 界面上写着「会自动下载」，
//  代码里根本没下过包。这条链路现在由 UpdateFlow（纯逻辑，可离线回归）
//  判定下一步该做什么，UpdateManager 只负责执行。
//

import AppKit
import CryptoKit
import Foundation

@MainActor
final class UpdateManager: ObservableObject {

    static let shared = UpdateManager()

    // MARK: - 更新源

    /// 唯一的更新源。改仓库改这里。
    private static let owner = "Mofan2020"
    private static let repo = "DeepSleep"
    /// Release 资产文件名是固定的。
    private static let assetName = "DeepSleep.zip"
    private static let checksumAssetName = "DeepSleep.zip.sha256"
    private static let expectedBundleID = "com.skyc8266.deepsleep"

    private static let autoCheckKey = "com.skyc8266.deepsleep.autoCheckUpdates"
    private static let askKey = "com.skyc8266.deepsleep.askBeforeInstalling"
    private static let lastCheckKey = "com.skyc8266.deepsleep.lastUpdateCheckAt"
    private static let skipPrereleaseKey = "com.skyc8266.deepsleep.skipPrereleaseUpdates"
    /// 「上一轮真的动过手」的标记。应用下次启动时看到它，就去读结果文件。
    private static let pendingInstallKey = "com.skyc8266.deepsleep.pendingUpdateInstall"
    /// 上一次安装结果（结果文件的原文）。存一份是为了跨重启还在。
    private static let lastResultKey = "com.skyc8266.deepsleep.lastUpdateResult"
    /// 自动重试退避：网络 / 临时错误按指数退避（5s / 30s / 5min），非临时错误不再试。
    private static let retryDelays: [TimeInterval] = [5, 30, 5 * 60]
    private var retryCount = 0

    /// 自动检查的间隔。GitHub 对匿名 API 有 60 次/小时的限额，
    /// 一天一次既够用又不会撞限额。
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    // MARK: - 状态

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case available(version: String)
        case downloading(version: String, progress: Double)
        /// 下载完了，正在校验（摘要 / bundle id / 版本号 / 签名）。
        case verifying(version: String)
        /// 已下载并校验通过，等用户点「立即更新并重启」。
        case ready(version: String)
        /// 正在替换应用本体。
        case installing(version: String)
        /// 已经发起一次性管理员授权，正在等用户输密码。
        case awaitingAuthorization(version: String)
        /// 替换失败（权限被拒、磁盘满、被取消…）。
        case installFailed(version: String, reason: String)
        /// 检查或准备阶段失败。
        case failed(String)

        var text: String {
            switch self {
            case .idle:                      return "尚未检查"
            case .checking:                  return "正在检查…"
            case .upToDate(let current):     return "已是最新版本（\(current)）"
            case .available(let version):    return "发现新版本 \(version)"
            case .downloading(let version, let progress):
                return "正在下载 \(version)（\(Int(progress * 100))%）"
            case .verifying(let version):    return "正在校验 \(version)"
            case .ready(let version):        return "\(version) 已就绪，可立即安装"
            case .installing(let version):   return "正在安装 \(version)"
            case .awaitingAuthorization(let version):
                return "等待管理员授权（安装 \(version)）"
            case .installFailed(let version, let reason):
                return "\(version) 安装失败：\(reason)"
            case .failed(let reason):        return "失败：\(reason)"
            }
        }

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .verifying, .installing, .awaitingAuthorization:
                return true
            default:                      return false
            }
        }

        /// 已下载并校验通过、可以装的版本号（没有就 nil）。
        var readyVersion: String? {
            switch self {
            case .ready(let version):        return version
            case .installFailed(let version, _): return version
            default:                         return nil
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    /// 是否自动检查更新。
    @Published var automaticallyChecks: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyChecks, forKey: Self.autoCheckKey)
        }
    }

    /// 下载校验完成后是否先问过用户再安装。
    /// 关掉它意味着「准备好就自己重启装掉」，适合不想被打断的场景。
    @Published var asksBeforeInstalling: Bool {
        didSet {
            UserDefaults.standard.set(asksBeforeInstalling, forKey: Self.askKey)
        }
    }

    /// 跳过预发布版本（仅装正式版）。默认 true —— 仓库的发布习惯是标 Pre-release，
    /// 不勾这个开关就会一直装 prerelease。
    @Published var skipPrereleaseUpdates: Bool {
        didSet {
            UserDefaults.standard.set(skipPrereleaseUpdates, forKey: Self.skipPrereleaseKey)
        }
    }

    /// 已下载并校验通过、等待安装的新版本。
    private var prepared: (version: String, appPath: String, workDirectory: String)?

    /// 上一次更新的结果。启动时读一次 —— 用户只有重启之后才知道更新成没成。
    @Published private(set) var lastUpdateOutcome: UpdateFlow.LastOutcome = .never

    /// 当前应用版本。取自 bundle，保证与「关于」里显示的一致。
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 替换应用本体时需不需要管理员权限。
    ///
    /// 判据是「目标目录当前用户能不能写」：~/Applications 与开发期 build 目录
    /// 能写（直接换），/Applications 一般不能（要一次管理员授权）。
    var installNeedsAdministrator: Bool {
        UpdateFlow.installMethod(
            targetDirectoryWritable: FileManager.default.isWritableFile(atPath: targetDirectory)
        ) == .elevated
    }

    /// 应用本体所在目录（替换时的目标）。
    private var targetDirectory: String {
        Bundle.main.bundleURL.deletingLastPathComponent().path
    }

    private init() {
        automaticallyChecks = UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true
        asksBeforeInstalling = UserDefaults.standard.object(forKey: Self.askKey) as? Bool ?? true
        skipPrereleaseUpdates = UserDefaults.standard.object(forKey: Self.skipPrereleaseKey) as? Bool ?? true
        lastUpdateOutcome = Self.loadLastOutcome()
    }

    // MARK: - 检查

    /// 启动后的自动检查入口。超过间隔才真的发请求。
    func autoCheckIfDue() async {
        guard automaticallyChecks else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.checkInterval else { return }
        // 标记这是「自动触发」的一次调用。
        await checkForUpdates(automaticallyInstall: true)
    }

    /// 检查是否有新版本可用；发现有就**继续往下走**。
    ///
    /// 完整链路：检查 → 发现新版本 → 自动下载 → 校验 → （按开关）安装。
    /// 以前这里有一句 `guard automaticallyInstall || !asksBeforeInstalling else { return }`
    /// 挡在下载之前 —— 默认参数是 false、开关默认又是 true，于是**自动检查从来
    /// 没下载过任何东西**，而界面上写着「会自动下载并校验」。承诺与代码不一致，
    /// 这句 guard 就是根因。现在没有提前 return 的地方了。
    ///
    /// - Parameter automaticallyInstall: 这一次调用是不是**自动触发**的
    ///   （自动检查 = true，界面上手点「立即检查」= false）。
    ///   它只影响日志措辞与重试行为，**不决定要不要直接装** ——
    ///   装不装由「安装前先询问」这个开关决定：用户的显式选择优先于调用方。
    func checkForUpdates(automaticallyInstall: Bool = false) async {
        guard !phase.isBusy else { return }
        phase = .checking
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

        let release: ReleaseInfo
        do {
            release = try await fetchLatestRelease(
                skipPrerelease: skipPrereleaseUpdates
            )
        } catch let error as UpdateError {
            await handleFailure(error, prefix: "检查更新失败",
                               automaticallyInstall: automaticallyInstall)
            return
        } catch {
            phase = .failed(error.localizedDescription)
            updateLog("检查更新失败：\(error.localizedDescription)")
            return
        }

        // 版本判断全压在 isUpgrade 上：它只在「严格更新」时返回 true，
        // 版本号解析不了时返回 false。这样即使 GitHub 那边 tag 写错了，
        // 也只会「不更新」，不会陷入反复安装。
        switch UpdateFlow.action(afterCheck: currentVersion, releaseVersion: release.version) {
        case .none:
            let note = SemanticVersion.parse(release.version) == nil
                ? "最新 Release 的版本号「\(release.version)」无法解析，已忽略"
                : "已是最新版本（\(currentVersion)）"
            phase = .upToDate(current: currentVersion)
            updateLog(note)
            retryCount = 0  // 「无更新」也是成功路径，重置退避计数
            return
        case .download(let version):
            phase = .available(version: version)
            updateLog("\(automaticallyInstall ? "自动检查" : "手动检查")："
                    + "发现新版本 \(version)（当前 \(currentVersion)），开始下载")
            retryCount = 0
        case .awaitConfirmation, .install:
            return  // 走不到：这两个分支只在校验之后才出现
        }

        // 发现新版本 → 直接进入下载与校验，不等用户点任何按钮。
        do {
            try await downloadAndPrepare(release)
        } catch let error as UpdateError {
            await handleFailure(error, prefix: "更新准备失败",
                               automaticallyInstall: automaticallyInstall)
        } catch {
            phase = .failed(error.localizedDescription)
            updateLog("更新准备失败：\(error.localizedDescription)")
        }
    }

    /// 失败处理：可重试的按指数退避重试，不可重试的就如实说。
    private func handleFailure(_ error: UpdateError, prefix: String,
                               automaticallyInstall: Bool) async {
        if error.isRetryable, retryCount < Self.retryDelays.count {
            let delay = Self.retryDelays[retryCount]
            retryCount += 1
            let detail = error.errorDescription ?? "未知"
            phase = .failed("\(detail)（\(Int(delay))s 后重试）")
            updateLog("\(prefix)：\(detail)。\(Int(delay))s 后自动重试。")
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await checkForUpdates(automaticallyInstall: automaticallyInstall)
            }
        } else {
            phase = .failed(error.errorDescription ?? "未知错误")
            updateLog("\(prefix)：\(error.errorDescription ?? "未知错误")")
        }
    }

    // MARK: - 下载与校验

    /// 拉取最新发布信息 + zip + sha256（顺序执行；sha256 用来校验）。
    ///
    /// 校验顺序一步都不放宽：摘要对不上、bundle id 不对、版本号对不上、
    /// 签名不过 —— 任何一条不满足都直接抛错，**绝不安装**。
    /// 失败会抛给调用方，由调用方决定是退避重试还是如实报给用户。
    private func downloadAndPrepare(_ release: ReleaseInfo) async throws {
        phase = .downloading(version: release.version, progress: 0)

        // 每次更新都用全新的临时目录，避免上一次的残留被误当成新包。
        let work = NSTemporaryDirectory() + "DeepSleepUpdate-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(
                atPath: work, withIntermediateDirectories: true)

            // 1) 下载 zip（带进度）
            let zipData = try await fetch(release.downloadURL, onProgress: { progress in
                Task { @MainActor in
                    self.phase = .downloading(version: release.version, progress: progress)
                }
            })
            guard zipData.count > 0 else { throw UpdateError.emptyDownload }
            let zipPath = work + "/\(Self.assetName)"
            try zipData.write(to: URL(fileURLWithPath: zipPath))

            // 下载完了，接下来是校验。单独一个阶段，用户能看出卡在哪一步。
            phase = .verifying(version: release.version)

            // 2) 若 Release 提供 sha256，先比对摘要
            if let checksumURL = release.checksumURL {
                let checksumText = String(
                    data: try await fetch(checksumURL), encoding: .utf8) ?? ""
                let expected = checksumText
                    .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                    .first.map(String.init)?.lowercased() ?? ""
                guard expected.count == 64 else { throw UpdateError.badChecksumFile }
                guard let zipBytes = FileManager.default.contents(atPath: zipPath) else {
                    throw UpdateError.emptyDownload
                }
                let actual = SHA256.hash(data: zipBytes)
                    .map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { throw UpdateError.checksumMismatch }
                updateLog("下载包 SHA-256 校验通过")
            }

            // 3) 解压（ditto 会保留签名与权限，unzip 有时会破坏它们）
            let extractDirectory = work + "/extracted"
            try run("/usr/bin/ditto", ["-x", "-k", zipPath, extractDirectory])

            guard let appPath = findApp(in: extractDirectory) else {
                throw UpdateError.noAppInArchive
            }

            // 4) bundle id 必须对
            guard let bundle = Bundle(path: appPath),
                  bundle.bundleIdentifier == Self.expectedBundleID else {
                throw UpdateError.wrongBundleIdentifier
            }

            // 5) 版本号必须与 Release 声称的一致 —— 防止下到的包与 tag 不是一回事
            let archiveVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            guard SemanticVersion.compare(archiveVersion, release.version) == 0 else {
                throw UpdateError.versionMismatch(archive: archiveVersion, release: release.version)
            }

            // 6) 签名结构校验（ad-hoc 签名也能过，主要用于发现损坏的包）
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath])

            // 7) 清掉互联网下载标记，否则每次重启都会弹「来自互联网」提示
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appPath])

            prepared = (version: release.version, appPath: appPath, workDirectory: work)
            phase = .ready(version: release.version)
            updateLog("\(release.version) 已下载并校验通过")

            // 装不装由「安装前先询问」决定：
            //   开着 → 停在 .ready，等用户点「立即更新并重启」；
            //   关着 → 校验通过就直接装，并重启。
            switch UpdateFlow.action(afterVerification: release.version,
                                     asksBeforeInstalling: asksBeforeInstalling) {
            case .install:
                updateLog("「安装前先询问」已关闭，直接安装 \(release.version)")
                await installAndRelaunch()
            case .awaitConfirmation:
                updateLog("等你确认后安装 \(release.version)")
            case .none, .download:
                break
            }
        } catch {
            try? FileManager.default.removeItem(atPath: work)
            prepared = nil
            throw error
        }
    }

    func discardPreparedUpdate() {
        if let prepared {
            try? FileManager.default.removeItem(atPath: prepared.workDirectory)
        }
        prepared = nil
        phase = .idle
    }

    // MARK: - 安装

    /// 替换应用本体，然后退出自己。
    ///
    /// 更新器等本进程真的退出后才动手 —— 直接用 `mv` 覆盖正在运行的
    /// .app 会让进程读到已释放的 inode，行为不可预期。
    ///
    /// 两条路：
    ///   · 目标目录当前用户可写（~/Applications、开发期 build 目录）→ 直接跑脚本；
    ///   · 目标目录不可写（典型是 /Applications）→ 用 osascript 请求**一次性**
    ///     管理员授权，让脚本以 root 身份跑。
    ///
    /// 为什么不走特权助手：助手那条命令要改 `DeepSleepHelper/main.swift`，
    /// 而助手不一定装了（用户可能没启用「完全控制」）。osascript 这条路
    /// 不依赖任何前置条件，装不装助手都能用。
    func installAndRelaunch() async {
        guard let prepared else { return }

        let targetPath = Bundle.main.bundleURL.path
        let writable = FileManager.default.isWritableFile(atPath: targetDirectory)
        let method = UpdateFlow.installMethod(targetDirectoryWritable: writable)

        let resultPath = Self.resultFilePath()
        // 上一轮的结果不能被当成本轮的结果：先清掉。
        // 目录是用户自己的，所以即使用 root 写的文件也删得掉。
        try? FileManager.default.removeItem(atPath: resultPath)

        let script = Self.updaterScript(
            target: targetPath,
            source: prepared.appPath,
            workDirectory: prepared.workDirectory,
            pid: getpid(),
            resultPath: resultPath,
            version: prepared.version)
        let scriptPath = prepared.workDirectory + "/updater.sh"

        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: scriptPath)
        } catch {
            phase = .installFailed(version: prepared.version,
                                   reason: "无法写入更新器：\(error.localizedDescription)")
            return
        }

        switch method {
        case .direct:
            phase = .installing(version: prepared.version)
            updateLog("正在安装 \(prepared.version)（目标目录可写，不需要管理员权限）")
            guard launchInstaller(scriptPath) else {
                phase = .installFailed(version: prepared.version,
                                       reason: "无法启动更新器")
                return
            }
            markInstallPending()
            terminateSoon()

        case .elevated:
            // 目标目录不可写 —— 明说需要管理员权限，再去要这个授权。
            phase = .awaitingAuthorization(version: prepared.version)
            updateLog("目标目录 \(targetDirectory) 当前用户不可写，"
                    + "安装 \(prepared.version) 需要管理员权限")
            do {
                try await Self.runInstallerWithAdministratorPrivileges(scriptPath: scriptPath)
            } catch {
                // 授权被拒或失败：应用不动，继续跑，告诉用户为什么。
                let reason = error.localizedDescription
                phase = .installFailed(version: prepared.version, reason: reason)
                updateLog("安装没有开始：\(reason)")
                return
            }
            markInstallPending()
            terminateSoon()
        }
    }

    /// 启动更新器脚本，并让它活过我们自己的退出。
    ///
    /// 用 `nohup … &` 把它甩到后台：脚本要等本进程退出才动手，
    /// 如果它是我们的子进程，我们退出时它得还在。
    private func launchInstaller(_ scriptPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c",
            "/usr/bin/nohup /bin/sh \(UpdateFlow.shellQuoted(scriptPath)) >/dev/null 2>&1 &"]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    /// 用 osascript 请求一次性管理员授权，把更新器脚本以 root 身份跑起来。
    ///
    /// 脚本必须**后台**跑：osascript 会等命令结束，而脚本要等本进程退出才
    /// 动手 —— 前台跑就是互相等，死锁。
    private static func runInstallerWithAdministratorPrivileges(scriptPath: String) async throws {
        let command = "/usr/bin/nohup /bin/sh \(UpdateFlow.shellQuoted(scriptPath))"
            + " >/dev/null 2>&1 &"

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // AppleScript 字符串内的反斜杠与双引号需要转义。
                let escaped = command
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", appleScript]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: UpdateError.commandFailed(
                        "无法请求管理员授权：\(error.localizedDescription)"))
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume()
                } else if output.contains("-128")
                            || output.localizedCaseInsensitiveContains("User canceled") {
                    continuation.resume(throwing: UpdateError.commandFailed(
                        "已取消管理员授权，没有改动任何文件"))
                } else {
                    continuation.resume(throwing: UpdateError.commandFailed(
                        "管理员授权失败："
                        + (output.isEmpty ? "退出码 \(process.terminationStatus)" : output)))
                }
            }
        }
    }

    /// 记下「这一轮真的动过手」。
    ///
    /// 应用退出前读不到结果没关系 —— 下次启动时看到这个标记，就去读结果文件，
    /// 那一行才是「上一次更新到底成没成」的答案。
    private func markInstallPending() {
        UserDefaults.standard.set(true, forKey: Self.pendingInstallKey)
    }

    /// 给日志与 banner 一点落盘时间，然后退出。更新器会负责重启。
    private func terminateSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - 上一次安装结果

    /// 结果文件的位置。
    ///
    /// 放在用户自己的 Application Support 下，而不是临时目录 —— 临时目录会被
    /// 更新器脚本清掉，而且结果要活过一次重启。
    /// 目录由应用（普通用户身份）先建好，这样 root 写出来的文件也在
    /// 用户自己的目录里，用户读得到、也删得掉。
    static func resultFilePath() -> String {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSleep",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: base,
                                                 withIntermediateDirectories: true)
        return base.appendingPathComponent("update-result.txt").path
    }

    /// 读上一次安装的结果。
    ///
    /// 顺序很重要：先看有没有「正在安装」的标记 ——
    ///   · 有标记：说明上一轮我们真的动过手，结果文件才是那一轮的权威答案；
    ///     读不到就如实说「不知道」，不猜。
    ///   · 没标记：说明没有正在进行的安装，读缓存（跨重启保留）即可。
    private static func loadLastOutcome() -> UpdateFlow.LastOutcome {
        let pending = UserDefaults.standard.bool(forKey: pendingInstallKey)
        let cached = UserDefaults.standard.string(forKey: lastResultKey) ?? ""

        if pending {
            let text = (try? String(contentsOfFile: resultFilePath(),
                                    encoding: .utf8)) ?? ""
            UserDefaults.standard.set(false, forKey: pendingInstallKey)
            if let result = UpdateFlow.InstallResult.parse(text) {
                UserDefaults.standard.set(text, forKey: lastResultKey)
                return UpdateFlow.LastOutcome(result)
            }
            // 没拿到结果：如实说「没成」，但别编一个原因出来。
            return .failure(version: nil, message: "安装没有完成，也没有留下结果")
        }

        if let result = UpdateFlow.InstallResult.parse(cached) {
            return UpdateFlow.LastOutcome(result)
        }
        return .never
    }

    /// 生成更新器脚本。
    ///
    /// 做成静态方法是为了让 `--update-script` 能在不执行任何东西的前提下把它
    /// 打印出来：替换正在运行的应用是本项目第二危险的动作，执行前应该能一眼看完。
    /// 脚本本体放在 `UpdateFlow` 里 —— 那里不依赖 AppKit，可以被测试直接断言。
    static func updaterScript(target: String, source: String,
                              workDirectory: String, pid: Int32,
                              resultPath: String = "",
                              version: String = "") -> String {
        UpdateFlow.updaterScript(target: target, source: source,
                                 workDirectory: workDirectory, pid: pid,
                                 resultPath: resultPath, version: version)
    }

    // MARK: - 网络

    private struct ReleaseInfo {
        let version: String
        let downloadURL: URL
        let checksumURL: URL?
    }

    /// GitHub 上的一条 release。
    /// 注意它没有 `latest` 的含义 —— 我们是把列表拉回来自己挑的。
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        let tagName: String
        let assets: [Asset]
        /// 草稿状态的 release 只有仓库维护者能看到，绝不该装给用户。
        let draft: Bool
        /// 预发布版本。**保留它** —— 本仓库的发布习惯就是标 Pre-release。
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
            case draft
            case prerelease
        }
    }

    /// 拉取可用 Release 里版本最高的那一个。
    ///
    /// **不用 `/releases/latest`**：那个接口不返回预发布版本。本仓库的发布习惯
    /// 就是标 Pre-release，用它的结果是明明有 Release 却永远 404 —— 曾经就
    /// 因为这个接口少考虑了一层，把「有 Release 但都是预发布」误判成了「没有 Release」。
    ///
    /// 改为列出最近若干条，丢掉草稿（未发布的东西不该自动装给用户），
    /// 保留预发布（默认行为），再用版本号比较取最高的那条。
    /// `skipPrerelease=true` 时进一步丢掉预发布，只装正式版。
    private func fetchLatestRelease(skipPrerelease: Bool = false) async throws -> ReleaseInfo {
        let url = URL(string:
            "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases?per_page=30")!
        let data = try await fetch(url)

        let releases: [GitHubRelease]
        do {
            releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        } catch {
            throw UpdateError.malformedRelease
        }

        // 版本号解析不出来的条目直接跳过：判断不了就不让它参与比较，
        // 而不是硬塞一个「版本 0」或「版本无限大」进去。
        let candidates = releases
            .filter { !$0.draft }
            .filter { !skipPrerelease || !$0.prerelease }
            .filter { SemanticVersion.parse($0.tagName) != nil }

        guard let release = candidates.max(by: { lhs, rhs in
            (SemanticVersion.compare(lhs.tagName, rhs.tagName) ?? 0) < 0
        }) else {
            throw UpdateError.noUsableRelease
        }

        guard let asset = release.assets.first(where: { $0.name == Self.assetName }),
              let downloadURL = URL(string: asset.browserDownloadURL) else {
            throw UpdateError.missingAsset(Self.assetName)
        }
        let checksumURL = release.assets
            .first { $0.name == Self.checksumAssetName }
            .flatMap { URL(string: $0.browserDownloadURL) }

        return ReleaseInfo(version: release.tagName,
                           downloadURL: downloadURL,
                           checksumURL: checksumURL)
    }

    private func fetch(_ url: URL) async throws -> Data {
        try await fetch(url, onProgress: { _ in })
    }

    /// 带进度的下载：每收到 chunk 回调 `onProgress(0.0–1.0)`。
    /// chunk 累计成单一 Data 返回 —— SHA-256 校验时一次性 hash 整个文件，
    /// 比「边下边 hash」简单得多；下载几百 MB 不构成瓶颈。
    private func fetch(_ url: URL, onProgress: @escaping (Double) -> Void) async throws -> Data {
        var request = URLRequest(url: url)
        // GitHub API / 资产下载都要求带 User-Agent。
        request.setValue("DeepSleep", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if url.path.hasPrefix("/repos/") {
            // API 请求保持短超时；资产下载用更长超时。
            request.timeoutInterval = 60
        } else {
            request.timeoutInterval = 5 * 60
        }

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.network("没有收到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError.network("HTTP \(http.statusCode)")
        }

        let expected = http.expectedContentLength
        var data = Data()
        data.reserveCapacity(expected > 0 ? Int(expected) : 0)
        var lastReportedProgress: Double = 0
        for try await byte in asyncBytes {
            data.append(byte)
            if expected > 0 {
                let progress = Double(data.count) / Double(expected)
                // 节流：变化 ≥ 1% 才上报，避免每字节更新一次 phase 触发 UI 重绘。
                if progress - lastReportedProgress >= 0.01 || progress >= 1.0 {
                    lastReportedProgress = progress
                    onProgress(progress)
                }
            }
        }
        if expected > 0 {
            onProgress(1.0)
        }
        return data
    }

    // MARK: - 辅助

    private func findApp(in directory: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return nil
        }
        // 优先取名字正确的那一个，其余 .app 兜底。
        if entries.contains("Deep Sleep.app") { return directory + "/Deep Sleep.app" }
        return entries.first { $0.hasSuffix(".app") }.map { directory + "/" + $0 }
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UpdateError.commandFailed(
                "\((executable as NSString).lastPathComponent)：\(text.isEmpty ? "退出码 \(process.terminationStatus)" : text)")
        }
    }

    private func updateLog(_ text: String) {
        SleepController.shared.appendLog(text)
    }

    enum UpdateError: LocalizedError {
        case malformedRelease
        /// 列出了 Release，但没有一条能用于自动更新（全是草稿，或版本号解析不了）。
        case noUsableRelease
        case missingAsset(String)
        case emptyDownload
        case badChecksumFile
        case checksumMismatch
        case noAppInArchive
        case wrongBundleIdentifier
        case versionMismatch(archive: String, release: String)
        case commandFailed(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .malformedRelease:
                return "Release 信息无法解析"
            case .noUsableRelease:
                return "没有可用于自动更新的 Release（都是草稿，或版本号无法解析）"
            case .missingAsset(let name):
                return "该 Release 里没有 \(name)"
            case .emptyDownload:
                return "下载到的文件是空的"
            case .badChecksumFile:
                return "校验和文件格式不对"
            case .checksumMismatch:
                return "SHA-256 校验不通过，已放弃安装"
            case .noAppInArchive:
                return "压缩包里没有找到 .app"
            case .wrongBundleIdentifier:
                return "压缩包里的应用不是 Deep Sleep"
            case .versionMismatch(let archive, let release):
                return "压缩包版本（\(archive)）与 Release 声称的（\(release)）不一致"
            case .commandFailed(let detail):
                return detail
            case .network(let detail):
                return "网络错误：\(detail)"
            }
        }

        /// 「临时性」错误：网络抖动、5xx 等。按 retryDelays 退避重试。
        /// 「永久性」错误（checksum mismatch / wrongBundleID）不重试。
        var isRetryable: Bool {
            switch self {
            case .network: return true
            case .emptyDownload: return true
            case .malformedRelease: return true   // GitHub 临时返回脏数据也算
            default: return false
            }
        }
    }
}
