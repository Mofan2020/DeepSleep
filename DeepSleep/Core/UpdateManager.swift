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

    /// 自动检查的间隔。GitHub 对匿名 API 有 60 次/小时的限额，
    /// 一天一次既够用又不会撞限额。
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    // MARK: - 状态

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case available(version: String)
        case downloading(version: String)
        case ready(version: String)
        case failed(String)

        var text: String {
            switch self {
            case .idle:                      return "尚未检查"
            case .checking:                  return "正在检查…"
            case .upToDate(let current):     return "已是最新版本（\(current)）"
            case .available(let version):    return "发现新版本 \(version)"
            case .downloading(let version):  return "正在下载 \(version)…"
            case .ready(let version):        return "\(version) 已就绪，可立即安装"
            case .failed(let reason):        return "检查失败：\(reason)"
            }
        }

        var isBusy: Bool {
            switch self {
            case .checking, .downloading: return true
            default:                      return false
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

    /// 已下载并校验通过、等待安装的新版本。
    private var prepared: (version: String, appPath: String, workDirectory: String)?

    /// 当前应用版本。取自 bundle，保证与「关于」里显示的一致。
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private init() {
        automaticallyChecks = UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true
        asksBeforeInstalling = UserDefaults.standard.object(forKey: Self.askKey) as? Bool ?? true
    }

    // MARK: - 检查

    /// 启动后的自动检查入口。超过间隔才真的发请求。
    func autoCheckIfDue() async {
        guard automaticallyChecks else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.checkInterval else { return }
        await checkForUpdates()
    }

    /// 检查是否有新版本可用。
    /// - Parameter automaticallyInstall: 准备好后不等用户确认直接安装。
    func checkForUpdates(automaticallyInstall: Bool = false) async {
        guard !phase.isBusy else { return }
        phase = .checking
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

        do {
            let release = try await fetchLatestRelease()

            // 版本判断全压在 isUpgrade 上：它只在「严格更新」时返回 true，
            // 版本号解析不了时返回 false。这样即使 GitHub 那边 tag 写错了，
            // 也只会「不更新」，不会陷入反复安装。
            guard SemanticVersion.isUpgrade(from: currentVersion, to: release.version) else {
                let note = SemanticVersion.parse(release.version) == nil
                    ? "最新 Release 的版本号「\(release.version)」无法解析，已忽略"
                    : "已是最新版本（\(currentVersion)）"
                phase = .upToDate(current: currentVersion)
                updateLog(note)
                return
            }

            phase = .available(version: release.version)
            updateLog("发现新版本 \(release.version)（当前 \(currentVersion)）")

            guard automaticallyInstall || !asksBeforeInstalling else { return }
            await downloadAndPrepare(release)
        } catch {
            phase = .failed(error.localizedDescription)
            updateLog("检查更新失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 下载与校验

    private func downloadAndPrepare(_ release: ReleaseInfo) async {
        phase = .downloading(version: release.version)

        var workDirectory: String?
        do {
            // 每次更新都用全新的临时目录，避免上一次的残留被误当成新包。
            let work = NSTemporaryDirectory() + "DeepSleepUpdate-\(UUID().uuidString)"
            workDirectory = work
            try FileManager.default.createDirectory(
                atPath: work, withIntermediateDirectories: true)

            // 1) 下载 zip
            let zipData = try await fetch(release.downloadURL)
            guard zipData.count > 0 else { throw UpdateError.emptyDownload }
            let zipPath = work + "/\(Self.assetName)"
            try zipData.write(to: URL(fileURLWithPath: zipPath))

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
            updateLog("\(release.version) 已下载并校验通过，可立即安装")

            if !asksBeforeInstalling {
                installAndRelaunch()
            }
        } catch {
            if let workDirectory { try? FileManager.default.removeItem(atPath: workDirectory) }
            prepared = nil
            phase = .failed(error.localizedDescription)
            updateLog("更新准备失败：\(error.localizedDescription)")
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

    /// 启动临时目录里的更新器，然后退出自己。
    ///
    /// 更新器等本进程真的退出后才动手 —— 直接用 `mv` 覆盖正在运行的
    /// .app 会让进程读到已释放的 inode，行为不可预期。
    func installAndRelaunch() {
        guard let prepared else { return }

        let targetPath = Bundle.main.bundleURL.path
        let script = Self.updaterScript(
            target: targetPath,
            source: prepared.appPath,
            workDirectory: prepared.workDirectory,
            pid: getpid())
        let scriptPath = prepared.workDirectory + "/updater.sh"

        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: scriptPath)
        } catch {
            phase = .failed("无法写入更新器：\(error.localizedDescription)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
        do {
            try process.run()
        } catch {
            phase = .failed("无法启动更新器：\(error.localizedDescription)")
            return
        }

        updateLog("更新器已启动，即将退出以完成替换")
        // 给日志与 banner 一点落盘时间，然后退出。更新器会负责重启。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSApp.terminate(nil)
        }
    }

    /// 生成更新器脚本。
    /// 做成静态方法是为了让 `--update-script` 能在不执行任何东西的前提下把它
    /// 打印出来：替换正在运行的应用是本项目第二危险的动作，执行前应该能一眼看完。
    static func updaterScript(target: String, source: String,
                              workDirectory: String, pid: Int32) -> String {
        """
        #!/bin/sh
        # 由 Deep Sleep 生成：等应用退出后替换它，然后重新打开。
        # 这个脚本在临时目录里，因此不会被它自己要替换的 .app 带走。
        set -u

        TARGET=\(Self.quoted(target))
        SOURCE=\(Self.quoted(source))
        PID=\(getpid())
        WORK=\(Self.quoted(workDirectory))
        OLD=\(Self.quoted(target + ".updating"))

        # 等应用真正退出（最多 30 秒）。不这么做的话，替换会发生在它还在运行时。
        i=0
        while [ "$i" -lt 150 ]; do
            /bin/kill -0 "$PID" 2>/dev/null || break
            /bin/sleep 0.2
            i=$((i + 1))
        done

        /bin/rm -rf "$OLD" 2>/dev/null || true

        # 先挪走旧的，再放新的。特意不写成「先 rm -rf 清干净再放」：
        # 如果挪走那一步失败，rm 会把用户的应用直接删掉，而回滚又会因为
        # 备份根本不存在而同样失败 —— 应用就彻底没了。
        if /bin/mv -f "$TARGET" "$OLD" 2>/dev/null; then
            if /bin/mv -f "$SOURCE" "$TARGET" 2>/dev/null; then
                /bin/rm -rf "$OLD" 2>/dev/null || true
                /bin/rm -rf "$WORK" 2>/dev/null || true
                /usr/bin/open "$TARGET"
            else
                # 新的放不进去（磁盘满、权限不足…）就把旧的放回原位。
                # 宁可停在旧版本，也不能留下一个装不上的应用。
                /bin/mv -f "$OLD" "$TARGET" 2>/dev/null || true
                /usr/bin/open "$TARGET"
            fi
        else
            # 旧的压根没挪动，说明原状未被破坏，直接重开即可。
            /usr/bin/open "$TARGET"
        fi

        /bin/rm -f "$0"
        """
    }

    // MARK: - 网络

    private struct ReleaseInfo {
        let version: String
        let downloadURL: URL
        let checksumURL: URL?
    }

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

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest")!
        let data = try await fetch(url)

        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.malformedRelease
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
        var request = URLRequest(url: url)
        // GitHub API 要求带 User-Agent，否则直接 403。
        request.setValue("DeepSleep", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.network("没有收到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError.network("HTTP \(http.statusCode)")
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

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func updateLog(_ text: String) {
        SleepController.shared.appendLog(text)
    }

    enum UpdateError: LocalizedError {
        case malformedRelease
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
                return detail
            }
        }
    }
}
