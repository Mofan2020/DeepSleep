//
//  UpdateFlow.swift
//  Deep Sleep
//
//  自动更新链路里的**纯逻辑**部分。
//
//  为什么把它从 UpdateManager 里摘出来：这几件事最容易写错、又最难靠肉眼看
//  出来 ——
//    · 「检查完了该做什么」（下载？等人点？还是直接装？）
//    · 「校验完了该做什么」（同一个问题的后半段）
//    · 「要不要提权」（目标目录当前用户能不能写）
//    · 「结果文件怎么解析」（上一次更新到底成没成）
//    · 「更新器脚本长什么样」（替换逻辑 + 回滚 + 写结果）
//
//  摘出来之后，它不碰网络、不碰磁盘、不碰进程 —— 只有能被脚本直接编译、
//  在没有网络的情况下回归测试的东西（scripts/test-update-flow.swift）。
//
//  这一层是纯的，UpdateManager 才敢在真机上乱跑。
//

import Foundation

public enum UpdateFlow {

    // MARK: - 链路判定

    /// 「走到这一步了，下一步该做什么」。
    public enum Action: Equatable {
        /// 没什么可做的：已是最新，或者版本号解析不了。
        case none
        /// 需要下载并校验。
        case download(version: String)
        /// 已校验通过，等用户点「立即更新并重启」。
        case awaitConfirmation(version: String)
        /// 直接安装并重启。
        case install(version: String)
    }

    /// 检查完（拿到 Release 声称的版本号）之后的下一步。
    ///
    /// 版本判断全压在 `SemanticVersion.isUpgrade` 上：它只在「严格更新」时
    /// 返回 true，版本号解析不了时返回 false。解析不了宁可漏掉一次更新，
    /// 也不能陷入反复安装。
    public static func action(afterCheck currentVersion: String,
                              releaseVersion: String) -> Action {
        guard SemanticVersion.isUpgrade(from: currentVersion, to: releaseVersion) else {
            return .none
        }
        return .download(version: releaseVersion)
    }

    /// 校验通过之后的下一步。
    ///
    /// **装不装由「安装前先询问」这个开关决定**，不由调用方决定 ——
    /// 那是用户在界面上的显式选择，优先于任何自动触发的默认值。
    public static func action(afterVerification version: String,
                              asksBeforeInstalling: Bool) -> Action {
        asksBeforeInstalling
            ? .awaitConfirmation(version: version)
            : .install(version: version)
    }

    // MARK: - 提权

    /// 用什么方式替换应用。
    public enum InstallMethod: Equatable {
        /// 目标目录当前用户可写（~/Applications、开发期 build 目录）—— 直接换。
        case direct
        /// 目标目录不可写（典型是 /Applications）—— 需要管理员权限。
        case elevated
    }

    /// 由「目标目录能不能写」决定用哪条路。
    ///
    /// 判据刻意做得很窄：只回答「能不能直接写」，不回答「能不能装」——
    /// 能不能装要等真替换时才知道。
    public static func installMethod(targetDirectoryWritable: Bool) -> InstallMethod {
        targetDirectoryWritable ? .direct : .elevated
    }

    // MARK: - 结果文件

    /// 更新器写下来的结果。
    public struct InstallResult: Equatable {

        public enum Status: String, Equatable {
            case success
            case failure
        }

        public let status: Status
        public let version: String?
        public let message: String

        public init(status: Status, version: String?, message: String) {
            self.status = status
            self.version = version
            self.message = message
        }

        /// 解析结果文件的内容。
        ///
        /// 格式是每行一个 `键=值`：
        ///
        ///     status=success
        ///     version=1.11.1
        ///     message=已更新到 1.11.1
        ///
        /// 认不出来就返回 nil —— **宁可显示「不知道」，也不猜**。
        /// 猜错的代价是让用户以为更新成功了。
        public static func parse(_ text: String) -> InstallResult? {
            var fields: [String: String] = [:]
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let parts = line.split(separator: "=", maxSplits: 1,
                                       omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                fields[key] = value
            }
            guard let raw = fields["status"],
                  let status = Status(rawValue: raw.lowercased()) else {
                return nil
            }
            let version = fields["version"].flatMap { $0.isEmpty ? nil : $0 }
            return InstallResult(status: status,
                                 version: version,
                                 message: fields["message"] ?? "")
        }
    }

    /// 上一次更新的结果 —— 界面显示用的形态。
    public enum LastOutcome: Equatable {
        /// 没装过。
        case never
        case success(version: String?, message: String)
        case failure(version: String?, message: String)

        public init(_ result: InstallResult) {
            switch result.status {
            case .success:
                self = .success(version: result.version, message: result.message)
            case .failure:
                self = .failure(version: result.version, message: result.message)
            }
        }

        /// 一句话摘要。界面直接用它。
        public var summary: String {
            switch self {
            case .never:
                return "还没有装过更新"
            case .success(let version, let message):
                return "上一次更新成功" + versionSuffix(version)
                    + (message.isEmpty ? "" : "：\(message)")
            case .failure(let version, let message):
                return "上一次更新失败" + versionSuffix(version)
                    + (message.isEmpty ? "" : "：\(message)")
            }
        }

        /// 状态词。状态一律「颜色 + 文字」双编码，文字不能省。
        public var statusText: String {
            switch self {
            case .never:    return "未装过"
            case .success:  return "成功"
            case .failure:  return "失败"
            }
        }

        private func versionSuffix(_ version: String?) -> String {
            guard let version, !version.isEmpty else { return "" }
            return "（\(version)）"
        }
    }

    // MARK: - 更新器脚本

    /// 生成更新器脚本。
    ///
    /// 这个脚本做四件事：
    ///    1. 等本进程真的退出（替换正在运行的应用，必须先让它走）；
    ///    2. 先把旧的挪走，再把新的放进去 —— 挪不动就原样不动；
    ///    3. 新的放不进去就把旧的放回原位（宁可停在旧版本，也不留半残状态）；
    ///    4. 把这一轮的结果写进结果文件 —— 用户只有重启之后才知道成没成。
    ///
    /// 做成静态函数有两个理由：一是 `--update-script` 要能在不执行任何东西的
    /// 前提下把它打印出来供人工检查（替换正在运行的应用是第二危险的动作）；
    /// 二是它能被测试直接断言。
    ///
    /// - Parameters:
    ///   - resultPath: 结果文件路径。传空字符串则不写结果（供 `--update-script` 打印用）。
    ///   - version: 新版本号，写进结果里，方便用户对上号。
    public static func updaterScript(target: String, source: String,
                                     workDirectory: String, pid: Int32,
                                     resultPath: String, version: String) -> String {
        let old = target + ".updating"
        return """
        #!/bin/sh
        # 由 Deep Sleep 生成：等应用退出后替换它，然后重新打开。
        # 这个脚本在临时目录里，因此不会被它自己要替换的 .app 带走。
        #
        # 结果写进 RESULT 指的文件：应用退出前读不到没关系，
        # 下次启动时它会读 —— 用户重启后才知道这一次更新到底成没成。
        set -u

        TARGET=\(shellQuoted(target))
        SOURCE=\(shellQuoted(source))
        PID=\(pid)
        WORK=\(shellQuoted(workDirectory))
        OLD=\(shellQuoted(old))
        RESULT=\(shellQuoted(resultPath))
        VERSION=\(shellQuoted(version))

        write_result() {
            [ -n "$RESULT" ] || return 0
            # 先删旧的：上一轮的结果不能被当成本轮的结果。
            # 用 rm 而不是直接写，是因为上一轮的文件可能是 root 写的，
            # 直接重定向会因权限失败。
            /bin/rm -f "$RESULT" 2>/dev/null || true
            {
                printf 'status=%s\n' "$1"
                printf 'version=%s\n' "$VERSION"
                printf 'message=%s\n' "$2"
            } > "$RESULT" 2>/dev/null || true
            /bin/chmod 644 "$RESULT" 2>/dev/null || true
        }

        reopen() {
            /usr/bin/open "$TARGET" 2>/dev/null || true
        }

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
        if ERR=$(/bin/mv -f "$TARGET" "$OLD" 2>&1); then
            if ERR2=$(/bin/mv -f "$SOURCE" "$TARGET" 2>&1); then
                write_result success "已更新到 $VERSION"
                /bin/rm -rf "$OLD" 2>/dev/null || true
                /bin/rm -rf "$WORK" 2>/dev/null || true
                reopen
            else
                # 新的放不进去（磁盘满、权限不足…）就把旧的放回原位。
                # 宁可停在旧版本，也不能留下一个装不上的应用。
                /bin/mv -f "$OLD" "$TARGET" 2>/dev/null || true
                write_result failure "新版本放不进去：$ERR2"
                reopen
            fi
        else
            # 旧的压根没挪动，说明原状未被破坏，直接重开即可。
            write_result failure "无法移动旧版本（可能需要管理员权限）：$ERR"
            reopen
        fi

        /bin/rm -f "$0" 2>/dev/null || true
        """
    }

    /// POSIX 单引号转义：把值安全地包进单引号，内部的单引号用 '\'' 表示。
    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
