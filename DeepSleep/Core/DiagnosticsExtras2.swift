//
//  DiagnosticsExtras2.swift
//  Deep Sleep
//
//  设备诊断的**第二批扩展检查项**：系统隐藏配置 + 已安装的软件 / 开发环境。
//
//  分工（与 DeviceDiagnostics.swift 的边界，同 DiagnosticsExtras.swift）：
//    - DeviceDiagnostics.swift 负责跑命令、读目录，把原始文本取回来；
//    - 本文件只做解析与判定，不碰系统状态，也不发起任何进程。
//
//  两条硬规矩：
//    1. 全部只读、绝不请求提权。拿不到的项一律写「无法读取（原因）」，
//       严重度按「正常」处理 —— 读不到不是故障。
//    2. 解析函数都是纯函数（String 进、结构体出），单测用**真实采集到的样本文本**
//       做夹具，不用编造的格式。
//
//  命名：新增类型一律带 Dg2 前缀，避免跟别的并行改动重名。
//

import Foundation

// MARK: - 事实类型

/// 通用的「键: 值」集合（sysctl、launchctl limit 这类输出）。
struct Dg2KeyValues: Equatable {
    var values: [String: String]

    func string(_ key: String) -> String? {
        guard let raw = values[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    func int(_ key: String) -> Int? {
        guard let raw = string(key) else { return nil }
        return Int(raw)
    }
}

/// launchctl limit 给出的进程资源上限。
struct Dg2LaunchLimits: Equatable {
    var maxFilesSoft: String?
    var maxFilesHard: String?
    var maxProcSoft: String?
    var maxProcHard: String?
}

/// 交换空间容量。
struct Dg2SwapCapacity: Equatable {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var freeBytes: UInt64
}

/// CPU 物理核 / 逻辑核。
struct Dg2CPUTopology: Equatable {
    var physicalCores: Int?
    var logicalCores: Int?
}

/// 一个没跑起来（或跑挂了）的自启项。
struct Dg2LaunchFailure: Equatable {
    var label: String
    /// 退出码。-9 表示被 SIGKILL 杀掉。
    var exitCode: Int
    var pid: String
}

/// APFS 本地快照。
struct Dg2Snapshots: Equatable {
    var count: Int
    var names: [String]
}

/// Time Machine 备份目标与最近一次备份。
struct Dg2TimeMachine: Equatable {
    var destinations: [String]
    var lastBackup: String?
    /// 读不到时记下原因（备份盘没插上、还没备份过等）。
    var lastBackupError: String?
}

/// 某个卷的聚焦（Spotlight）索引状态。
struct Dg2IndexState: Equatable {
    var path: String
    var state: String
    var indexingDisabled: Bool
}

/// DNS 概览。
struct Dg2DNS: Equatable {
    var nameservers: [String]
    /// 带 mdns 选项的解析器数量（Bonjour / mDNS）。
    var mdnsResolverCount: Int
    var domains: [String]
}

/// 网络服务与各接口上的代理设置。
struct Dg2NetworkServices: Equatable {
    var services: [String]
    /// 被禁用（列表里带 *）的网络服务。
    var disabledServices: [String]
    /// 配了代理的接口。
    var proxiedInterfaces: [String]
}

/// 一个第三方网络扩展（过滤器 / VPN 一类）。
struct Dg2NetworkExtension: Equatable {
    var name: String
    var bundleID: String
    var enabled: Bool
    var state: String
    /// 内容过滤器候选。
    var isFilter: Bool
    /// VPN / 隧道类。
    var isTunnel: Bool
}

/// 一个配置描述文件（MDM / 手动安装的 profile）。
struct Dg2Profile: Equatable {
    var name: String?
    var identifier: String?
    var installedByMDM: Bool
    var payloadTypes: [String]
    /// 含 com.apple.restrictions 载荷，即「限制」类描述文件。
    var restricted: Bool
}

/// 受保护目录的访问概览：只看能不能列目录，不读里面的内容。
struct Dg2ProtectedDir: Equatable {
    var name: String
    var path: String
    var accessible: Bool
    var itemCount: Int
    var note: String?
}

/// 输入法 / 键盘布局。
struct Dg2InputSources: Equatable {
    var total: Int
    var nonKeyboard: Int
}

/// 音频设备。
struct Dg2Audio: Equatable {
    var deviceNames: [String]
    var defaultOutput: String?
    var defaultInput: String?
}

/// 打印机。
struct Dg2Printer: Equatable {
    var name: String
    var status: String?
}

/// 雷雳 / USB4 接口。
struct Dg2USB: Equatable {
    var busCount: Int
    var freePorts: Int
    var occupiedPorts: Int
    /// SPUSBDataType 是否有输出。空输出说明这台机器没读到直连 USB 设备。
    var usbListEmpty: Bool
}

/// 已安装字体。
struct Dg2Fonts: Equatable {
    var total: Int
    var userInstalled: Int
}

/// 电池（ioreg 读到的原始值）。
struct Dg2Battery: Equatable {
    var cycleCount: Int?
    var designCapacity: Int?
    var fullChargeCapacity: Int?
    var maxCapacityPercent: Int?
    var currentCapacityPercent: Int?
    var externallyConnected: Bool?
    var fullyCharged: Bool?

    /// 健康度 = 满充容量 / 设计容量。
    var healthPercent: Double? {
        guard let full = fullChargeCapacity, let design = designCapacity, design > 0 else { return nil }
        return Double(full) / Double(design) * 100
    }
}

/// Shell 配置文件里的异常。
struct Dg2ShellConfig: Equatable {
    /// PATH 里一共列了多少个目录。
    var pathEntryCount: Int
    /// 同一个 PATH 里重复出现的目录。
    var duplicatePathEntries: [String]
    /// 关掉了证书校验之类的变量（变量名）。
    var insecureSettings: [String]
    /// 问题出现在哪个配置文件里。
    var file: String?
}

/// 一个开发工具的多个候选路径。
struct Dg2ToolPath: Equatable {
    var tool: String
    var paths: [String]
}

/// 容器运行时。
struct Dg2ContainerRuntime: Equatable {
    var name: String
    var version: String?
}

/// Homebrew。
struct Dg2Brew: Equatable {
    var formulaCount: Int
    var caskCount: Int
}

/// npm 全局包。
struct Dg2Npm: Equatable {
    var packageCount: Int
    var invalidPackages: [String]
}

/// 一个已安装的应用。
struct Dg2AppEntry: Equatable {
    var name: String
    var path: String
    var bundleID: String?
    /// 疑似损坏的原因（缺 Info.plist、主程序 0 字节等）。
    var brokenReason: String?
}

/// 已安装应用。
struct Dg2Apps: Equatable {
    var entries: [Dg2AppEntry]
}

/// pkgutil 的安装收据。
struct Dg2Receipts: Equatable {
    var total: Int
    var thirdParty: [String]
}

/// 系统登记的后台项（登录项与后台任务的登记册）。
struct Dg2BackgroundItems: Equatable {
    var names: [String]
}

// MARK: - 事实集合

/// 第二批扩展检查项用到的全部事实。
struct Dg2ExtraFacts {
    var kernelLimits: DiagnosticFact<Dg2KeyValues> = .unavailable(reason: "未采集")
    var launchLimits: DiagnosticFact<Dg2LaunchLimits> = .unavailable(reason: "未采集")
    var tcpBuffers: DiagnosticFact<Dg2KeyValues> = .unavailable(reason: "未采集")
    var swapCapacity: DiagnosticFact<Dg2SwapCapacity> = .unavailable(reason: "未采集")
    var cpuTopology: DiagnosticFact<Dg2CPUTopology> = .unavailable(reason: "未采集")
    var launchFailures: DiagnosticFact<[Dg2LaunchFailure]> = .unavailable(reason: "未采集")
    var launchThirdPartyCount: DiagnosticFact<Int> = .unavailable(reason: "未采集")
    var snapshots: DiagnosticFact<Dg2Snapshots> = .unavailable(reason: "未采集")
    var timeMachine: DiagnosticFact<Dg2TimeMachine> = .unavailable(reason: "未采集")
    var spotlight: DiagnosticFact<[Dg2IndexState]> = .unavailable(reason: "未采集")
    var dns: DiagnosticFact<Dg2DNS> = .unavailable(reason: "未采集")
    var networkServices: DiagnosticFact<Dg2NetworkServices> = .unavailable(reason: "未采集")
    var vpn: DiagnosticFact<[String]> = .unavailable(reason: "未采集")
    var networkExtensions: DiagnosticFact<[Dg2NetworkExtension]> = .unavailable(reason: "未采集")
    var xprotectVersion: DiagnosticFact<String> = .unavailable(reason: "未采集")
    var profiles: DiagnosticFact<[Dg2Profile]> = .unavailable(reason: "未采集")
    var securityAgents: DiagnosticFact<[String]> = .unavailable(reason: "未采集")
    var protectedDirs: DiagnosticFact<[Dg2ProtectedDir]> = .unavailable(reason: "未采集")
    var inputSources: DiagnosticFact<Dg2InputSources> = .unavailable(reason: "未采集")
    var audio: DiagnosticFact<Dg2Audio> = .unavailable(reason: "未采集")
    var printers: DiagnosticFact<[Dg2Printer]> = .unavailable(reason: "未采集")
    var usb: DiagnosticFact<Dg2USB> = .unavailable(reason: "未采集")
    var fonts: DiagnosticFact<Dg2Fonts> = .unavailable(reason: "未采集")
    var battery: DiagnosticFact<Dg2Battery> = .unavailable(reason: "未采集")
    var shellConfig: DiagnosticFact<Dg2ShellConfig> = .unavailable(reason: "未采集")
    var devPaths: DiagnosticFact<[Dg2ToolPath]> = .unavailable(reason: "未采集")
    var containers: DiagnosticFact<[Dg2ContainerRuntime]> = .unavailable(reason: "未采集")
    var brew: DiagnosticFact<Dg2Brew> = .unavailable(reason: "未采集")
    var npm: DiagnosticFact<Dg2Npm> = .unavailable(reason: "未采集")
    var pythonEnvs: DiagnosticFact<[String]> = .unavailable(reason: "未采集")
    var apps: DiagnosticFact<Dg2Apps> = .unavailable(reason: "未采集")
    var receipts: DiagnosticFact<Dg2Receipts> = .unavailable(reason: "未采集")
    var kexts: DiagnosticFact<[String]> = .unavailable(reason: "未采集")
    /// 登录时自动打开的应用（System Events 的 login items）。
    var loginItems: DiagnosticFact<[String]> = .unavailable(reason: "未采集")
    /// 系统登记的后台项（sfltool dumpbtm）。
    var backgroundItems: DiagnosticFact<Dg2BackgroundItems> = .unavailable(reason: "未采集")
}

// MARK: - 阈值

/// 第二批检查项用到的阈值。
enum Dg2Thresholds {
    /// kern.maxfilesperproc 低于此值 → 有人把它调低了。
    static let maxFilesPerProcWarning = 10240
    /// kern.maxfiles 低于此值 → 有人把它调低了。
    static let maxFilesWarning = 24576
    /// kern.maxproc 低于此值 → 有人把它调低了。
    static let maxProcWarning = 1000

    /// launchd 给普通任务的句柄软上限低于此值 → 偏紧。
    static let launchMaxFilesSoftWarning = 256
    /// launchd 给普通任务的进程数软上限低于此值 → 偏紧。
    static let launchMaxProcSoftWarning = 500

    /// TCP 收发缓冲区低于此值 → 偏小。
    static let tcpBufferWarning = 65536
    /// TCP 自动调优上限低于此值 → 偏小。
    static let tcpAutoBufferWarning = 1048576

    /// 交换空间总量低于此值（字节）→ 偏小。
    static let swapTotalWarningBytes: UInt64 = 1_073_741_824

    /// 本地快照数量超过此值 → 占用空间偏多。
    static let snapshotCountWarning = 20

    /// 全局 npm 包数量超过此值 → 值得看一眼。
    static let npmPackageCountWarning = 100
}

// MARK: - 解析与判定

/// 第二批扩展检查项的解析与判定。
enum Dg2Extra {

    // MARK: 解析

    /// 「键: 值」→ 字典。sysctl、launchctl limit 都用这个格式。
    static func parseKeyValues(_ text: String) -> Dg2KeyValues {
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            values[key] = value
        }
        return Dg2KeyValues(values: values)
    }

    /// launchctl limit：
    ///     maxproc     1333           2000
    ///     maxfiles    256            unlimited
    static func parseLaunchLimits(_ text: String) -> Dg2LaunchLimits {
        var limits = Dg2LaunchLimits()
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { continue }
            switch fields[0] {
            case "maxfiles":
                limits.maxFilesSoft = fields[1]
                limits.maxFilesHard = fields.count > 2 ? fields[2] : nil
            case "maxproc":
                limits.maxProcSoft = fields[1]
                limits.maxProcHard = fields.count > 2 ? fields[2] : nil
            default:
                break
            }
        }
        return limits
    }

    /// vm.swapusage：total = 9216.00M  used = 8357.19M  free = 858.81M  (encrypted)
    static func parseSwapCapacity(_ text: String) -> Dg2SwapCapacity? {
        func bytes(_ key: String) -> UInt64? {
            guard let range = text.range(of: "\(key) = ") else { return nil }
            let rest = text[range.upperBound...]
            let token = rest.prefix { $0.isNumber || $0 == "." }
            guard !token.isEmpty, var value = Double(token) else { return nil }
            let remainder = rest.dropFirst(token.count)
            if remainder.hasPrefix("G") { value *= 1024 * 1024 * 1024 }
            else if remainder.hasPrefix("M") { value *= 1024 * 1024 }
            else if remainder.hasPrefix("K") { value *= 1024 }
            guard value >= 0 else { return nil }
            return UInt64(value)
        }
        guard let total = bytes("total"),
              let used = bytes("used"),
              let free = bytes("free") else { return nil }
        return Dg2SwapCapacity(totalBytes: total, usedBytes: used, freeBytes: free)
    }

    /// hw.physicalcpu / hw.logicalcpu。
    static func parseCPUTopology(_ text: String) -> Dg2CPUTopology? {
        let values = parseKeyValues(text)
        let physical = values.int("hw.physicalcpu")
        let logical = values.int("hw.logicalcpu")
        guard physical != nil || logical != nil else { return nil }
        return Dg2CPUTopology(physicalCores: physical, logicalCores: logical)
    }

    /// launchctl list：
    ///     PID	Status	Label
    ///     40013	-9	com.apple.cloudphotod
    ///     -	1	org.torproject.tor
    ///
    /// 只看**第三方**自启项（Apple 自带的不算）；状态非 0 视为没跑起来。
    static func parseLaunchList(_ text: String) -> (failures: [Dg2LaunchFailure], thirdPartyCount: Int) {
        var failures: [Dg2LaunchFailure] = []
        var thirdPartyCount = 0
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3 else { continue }
            let pid = fields[0]
            let status = fields[1]
            let label = fields[2]
            guard label != "Label" else { continue }
            guard isThirdPartyLabel(label) else { continue }
            thirdPartyCount += 1
            guard let code = Int(status), code != 0 else { continue }
            failures.append(Dg2LaunchFailure(label: label, exitCode: code, pid: pid))
        }
        return (failures, thirdPartyCount)
    }

    /// 判断一个 launchd 标签是不是第三方的。
    static func isThirdPartyLabel(_ label: String) -> Bool {
        for prefix in ["com.apple.", "application.", "com.openssh.", "system."] where label.hasPrefix(prefix) {
            return false
        }
        return true
    }

    /// diskutil apfs listSnapshots：
    ///     |   Name:        com.apple.os.update-MSUPrepareUpdate
    ///
    /// 输出是树状图，名字前面挂着 "|   "，先把这些竖线去掉再找键。
    static func parseSnapshots(_ text: String) -> Dg2Snapshots {
        var names: [String] = []
        for rawLine in text.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("|") || line.hasPrefix("+") || line.hasPrefix("-") {
                line = line.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            guard line.hasPrefix("Name:") else { continue }
            let name = line.dropFirst("Name:".count).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            names.append(name)
        }
        return Dg2Snapshots(count: names.count, names: names)
    }

    /// tmutil destinationinfo + tmutil listbackups。
    static func parseTimeMachine(destination: String, backups: String) -> Dg2TimeMachine {
        var destinations: [String] = []
        for rawLine in destination.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard key == "Name" else { continue }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            destinations.append(value)
        }

        var lastBackup: String?
        var error: String?
        let trimmed = backups.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            error = "tmutil 没有返回任何备份记录"
        } else if trimmed.contains("Failed to mount") {
            error = "备份目标挂载失败（备份盘可能没插上或已损坏）"
        } else if trimmed.contains("No machine directory") {
            error = "没有找到备份记录（这台机器可能从未成功备份过）"
        } else {
            lastBackup = trimmed.split(separator: "\n").first.map(String.init)
        }
        return Dg2TimeMachine(destinations: destinations,
                              lastBackup: lastBackup,
                              lastBackupError: error)
    }

    /// mdutil -s -a：
    ///     /:
    ///     	Indexing disabled.
    static func parseSpotlight(_ text: String) -> [Dg2IndexState] {
        var result: [Dg2IndexState] = []
        var currentPath: String?
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasSuffix(":") && !line.contains(" ") {
                currentPath = String(line.dropLast())
                continue
            }
            guard let path = currentPath else { continue }
            let lowered = line.lowercased()
            let disabled = lowered.contains("disabled")
            result.append(Dg2IndexState(path: path, state: line, indexingDisabled: disabled))
            currentPath = nil
        }
        return result
    }

    /// scutil --dns。
    static func parseDNS(_ text: String) -> Dg2DNS {
        var nameservers: [String] = []
        var domains: [String] = []
        var mdnsCount = 0
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("nameserver") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty && !nameservers.contains(value) { nameservers.append(value) }
                continue
            }
            if line.hasPrefix("domain") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty && !domains.contains(value) { domains.append(value) }
                continue
            }
            if line.contains("mdns") { mdnsCount += 1 }
        }
        return Dg2DNS(nameservers: nameservers, mdnsResolverCount: mdnsCount, domains: domains)
    }

    /// system_profiler SPNetworkDataType —— 逐个接口看代理开关。
    ///
    /// 接口名在缩进 4 的一行里（"    Ethernet Adapter (en3):"），
    /// 代理开关在更深的缩进里（"          HTTP Proxy Enabled: Yes"）。
    static func parseNetworkInterfaces(_ text: String) -> Dg2NetworkServices {
        var proxied: [String] = []
        var current: String?
        var currentProxied = false

        func flush() {
            if let name = current, currentProxied, !proxied.contains(name) {
                proxied.append(name)
            }
            current = nil
            currentProxied = false
        }

        for rawLine in text.split(separator: "\n") {
            let indent = rawLine.prefix { $0 == " " }.count
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if indent == 4 && line.hasSuffix(":") {
                flush()
                current = String(line.dropLast())
                continue
            }
            for key in ["HTTP Proxy Enabled", "HTTPS Proxy Enabled", "SOCKS Proxy Enabled"] {
                if line.hasPrefix("\(key):") {
                    let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                    if value == "Yes" { currentProxied = true }
                }
            }
        }
        flush()
        return Dg2NetworkServices(services: [], disabledServices: [], proxiedInterfaces: proxied)
    }

    /// networksetup -listallnetworkservices。带 * 的是被禁用的服务。
    static func parseNetworkServiceList(_ text: String) -> (services: [String], disabled: [String]) {
        var services: [String] = []
        var disabled: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("*") {
                let name = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    disabled.append(name)
                    services.append(name)
                }
                continue
            }
            if line.contains("(*) denotes") { continue }
            services.append(line)
        }
        return (services, disabled)
    }

    /// scutil --nc list —— VPN 配置。
    static func parseVPNList(_ text: String) -> [String] {
        var result: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("Available network connection") { continue }
            if line.hasPrefix("*") { continue }
            result.append(line)
        }
        return result
    }

    /// 从 systemextensionsctl list 里挑出第三方网络扩展。
    ///
    /// 复用 DgExtra.parseSystemExtensions（它已经处理了制表符分隔与表头）。
    static func parseNetworkExtensions(_ text: String) -> [Dg2NetworkExtension] {
        DgExtra.parseSystemExtensions(text).compactMap { ext in
            let lower = ext.bundleID.lowercased()
            let nameLower = ext.name.lowercased()
            let isNetwork = lower.contains("network") || lower.contains("filter")
                || lower.contains("vpn") || lower.contains("tunnel")
                || lower.contains("wireguard") || lower.contains("openvpn")
                || lower.contains("tailscale")
                || nameLower.contains("adguard") || nameLower.contains("filter")
                || nameLower.contains("vpn") || nameLower.contains("wireguard")
            guard isNetwork else { return nil }
            let isFilter = lower.contains("filter") || lower.contains("dfnetwork")
                || nameLower.contains("adguard") || nameLower.contains("filter")
            let isTunnel = lower.contains("vpn") || lower.contains("wireguard")
                || lower.contains("openvpn") || lower.contains("tailscale")
                || lower.contains("tunnel")
            return Dg2NetworkExtension(name: ext.name,
                                       bundleID: ext.bundleID,
                                       enabled: ext.enabled,
                                       state: ext.state,
                                       isFilter: isFilter,
                                       isTunnel: isTunnel)
        }
    }

    /// defaults read .../XProtect.bundle/Contents/Info —— CFBundleShortVersionString。
    static func parseXProtectVersion(_ text: String) -> String? {
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("CFBundleShortVersionString") else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ";", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// profiles show -type configuration。
    static func parseProfiles(_ text: String) -> [Dg2Profile] {
        var profiles: [Dg2Profile] = []
        var name: String?
        var identifier: String?
        var byMDM = false
        var payloads: [String] = []

        func flush() {
            guard name != nil || identifier != nil else { return }
            profiles.append(Dg2Profile(name: name,
                                       identifier: identifier,
                                       installedByMDM: byMDM,
                                       payloadTypes: payloads,
                                       restricted: payloads.contains("com.apple.restrictions")))
            name = nil
            identifier = nil
            byMDM = false
            payloads = []
        }

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.contains("attribute:") {
                let after = line.components(separatedBy: "attribute:").last ?? ""
                guard let colon = after.firstIndex(of: ":") else { continue }
                let key = String(after[after.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(after[after.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "name":
                    flush()
                    name = value
                case "profileIdentifier":
                    identifier = value
                case "installedByMDM":
                    byMDM = value.uppercased() == "TRUE"
                default:
                    break
                }
                continue
            }
            if line.contains("payload[") && line.contains("type") {
                guard let equals = line.firstIndex(of: "=") else { continue }
                let value = String(line[line.index(after: equals)...])
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { payloads.append(value) }
            }
        }
        flush()
        return profiles
    }

    /// 常见的安全 / MDM 客户端。进程名或应用名里命中就算装上了。
    static let knownSecurityAgents: [(pattern: String, display: String)] = [
        ("jamf", "Jamf Pro（MDM）"),
        ("crowdstrike", "CrowdStrike Falcon"),
        ("csfalcon", "CrowdStrike Falcon"),
        ("defender", "Microsoft Defender for Endpoint"),
        ("mdatp", "Microsoft Defender for Endpoint"),
        ("sentinelone", "SentinelOne"),
        ("sophos", "Sophos 终端防护"),
        ("bitdefender", "Bitdefender"),
        ("eset", "ESET 终端防护"),
        ("trellix", "Trellix"),
        ("cylance", "Cylance"),
        ("zscaler", "Zscaler 客户端"),
        ("anyconnect", "Cisco Secure Client"),
        ("meraki", "Cisco Meraki 客户端"),
        ("cloudflare", "Cloudflare WARP"),
        ("warp-svc", "Cloudflare WARP"),
        ("tailscale", "Tailscale"),
        ("kolide", "Kolide")
    ]

    /// 从进程名与应用名里找安全 / MDM 客户端。
    static func parseSecurityAgents(processText: String, appNames: [String]) -> [String] {
        var found: [String] = []
        let haystack = (processText + "\n" + appNames.joined(separator: "\n")).lowercased()
        for agent in knownSecurityAgents {
            guard haystack.contains(agent.pattern) else { continue }
            if found.contains(agent.display) { continue }
            found.append(agent.display)
        }
        return found
    }

    /// defaults read com.apple.HIToolbox AppleEnabledInputSources。
    static func parseInputSources(_ text: String) -> Dg2InputSources {
        var total = 0
        var nonKeyboard = 0
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("InputSourceKind") else { continue }
            total += 1
            let value = quotedValue(in: line) ?? ""
            if value == "Keyboard Layout" || value == "Keyboard Input Method" { continue }
            nonKeyboard += 1
        }
        return Dg2InputSources(total: total, nonKeyboard: nonKeyboard)
    }

    /// 取出 "xxx" 形式的引号内容。
    static func quotedValue(in line: String) -> String? {
        guard let first = line.firstIndex(of: "\"") else { return nil }
        guard let second = line[first...].dropFirst().firstIndex(of: "\"") else { return nil }
        return String(line[line.index(after: first)..<second])
    }

    /// system_profiler SPAudioDataType。
    static func parseAudio(_ text: String) -> Dg2Audio {
        var names: [String] = []
        var defaultOutput: String?
        var defaultInput: String?
        var current: String?
        for rawLine in text.split(separator: "\n") {
            let indent = rawLine.prefix { $0 == " " }.count
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if indent == 8 && line.hasSuffix(":") {
                current = String(line.dropLast())
                if let current, !names.contains(current) { names.append(current) }
                continue
            }
            if line.hasPrefix("Default Output Device: Yes") || line.hasPrefix("Default System Output Device: Yes") {
                if defaultOutput == nil { defaultOutput = current }
                continue
            }
            if line.hasPrefix("Default Input Device: Yes") {
                defaultInput = current
            }
        }
        return Dg2Audio(deviceNames: names, defaultOutput: defaultOutput, defaultInput: defaultInput)
    }

    /// system_profiler SPPrintersDataType。
    static func parsePrinters(_ text: String) -> [Dg2Printer] {
        var printers: [Dg2Printer] = []
        var current: String?
        var status: String?

        func flush() {
            if let name = current {
                printers.append(Dg2Printer(name: name, status: status))
            }
            current = nil
            status = nil
        }

        for rawLine in text.split(separator: "\n") {
            let indent = rawLine.prefix { $0 == " " }.count
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if indent == 4 && line.hasSuffix(":") {
                flush()
                current = String(line.dropLast())
                continue
            }
            if line.hasPrefix("Status:") {
                status = String(line.dropFirst("Status:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return printers
    }

    /// system_profiler SPThunderboltDataType（雷雳 / USB4 口）。
    static func parseThunderbolt(_ text: String) -> Dg2USB {
        var busCount = 0
        var freePorts = 0
        var occupiedPorts = 0
        for rawLine in text.split(separator: "\n") {
            let indent = rawLine.prefix { $0 == " " }.count
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if indent == 4 && line.hasSuffix(":") {
                busCount += 1
                continue
            }
            if line.hasPrefix("Status: ") {
                let value = String(line.dropFirst("Status: ".count)).trimmingCharacters(in: .whitespaces)
                if value == "No device connected" {
                    freePorts += 1
                } else {
                    occupiedPorts += 1
                }
            }
        }
        return Dg2USB(busCount: busCount,
                      freePorts: freePorts,
                      occupiedPorts: occupiedPorts,
                      usbListEmpty: true)
    }

    /// system_profiler SPFontsDataType。
    static func parseFonts(_ text: String) -> Dg2Fonts {
        var total = 0
        var userInstalled = 0
        for rawLine in text.split(separator: "\n") {
            let indent = rawLine.prefix { $0 == " " }.count
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if indent == 4 && line.hasSuffix(":") {
                total += 1
                continue
            }
            if line.hasPrefix("Location:") {
                let value = String(line.dropFirst("Location:".count)).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("/Users/") { userInstalled += 1 }
            }
        }
        return Dg2Fonts(total: total, userInstalled: userInstalled)
    }

    /// ioreg -r -c AppleSmartBattery。
    static func parseBattery(_ text: String) -> Dg2Battery? {
        let cycleCount = intValue("CycleCount", in: text)
        let design = intValue("DesignCapacity", in: text)
        let full = intValue("FullChargeCapacity", in: text)
        let maxPercent = intValue("MaxCapacity", in: text)
        let current = intValue("CurrentCapacity", in: text)
        let external = boolValue("ExternalConnected", in: text)
        let charged = boolValue("FullyCharged", in: text)
        guard cycleCount != nil || design != nil || full != nil || maxPercent != nil else {
            return nil
        }
        return Dg2Battery(cycleCount: cycleCount,
                          designCapacity: design,
                          fullChargeCapacity: full,
                          maxCapacityPercent: maxPercent,
                          currentCapacityPercent: current,
                          externallyConnected: external,
                          fullyCharged: charged)
    }

    /// 找 "key" = 数字。
    static func intValue(_ key: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "\"\(key)\"\\s*=\\s*(-?\\d+)"),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        return Int((text as NSString).substring(with: match.range(at: 1)))
    }

    /// 找 "key" = Yes/No。
    static func boolValue(_ key: String, in text: String) -> Bool? {
        guard let regex = try? NSRegularExpression(pattern: "\"\(key)\"\\s*=\\s*(Yes|No)"),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        return (text as NSString).substring(with: match.range(at: 1)) == "Yes"
    }

    /// Shell 配置文件里「关掉了证书校验」的变量。
    ///
    /// 名字本身就是在削弱安全性，但取值有「安全」的一侧：
    /// NODE_TLS_REJECT_UNAUTHORIZED=1 是安全的，=0 才危险。
    static let insecureShellVariables: [(name: String, badValues: [String])] = [
        ("NODE_TLS_REJECT_UNAUTHORIZED", ["0", "false"]),
        ("PYTHONHTTPSVERIFY", ["0", "false"]),
        ("SSL_VERIFY", ["false", "0"]),
        ("GIT_SSL_NO_VERIFY", ["true", "1"]),
        ("npm_config_strict_ssl", ["false", "0"]),
        ("UV_INSECURE", ["1", "true"])
    ]

    /// 解析拼接后的 shell 配置文件文本。
    ///
    /// 采集层把每个文件前面加一行「# --- ~/.zshrc ---」标记，
    /// 这里按标记分段，好知道问题出在哪个文件。
    static func parseShellConfig(_ text: String) -> Dg2ShellConfig {
        var pathEntryCount = 0
        var duplicates: [String] = []
        var seenPaths = Set<String>()
        var insecure: [String] = []
        var file: String?

        var currentFile: String?
        var inPathArray = false

        func note(_ name: String) {
            if file == nil { file = currentFile }
        }

        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("# --- ") {
                let name = line.dropFirst("# --- ".count).trimmingCharacters(in: .whitespaces)
                currentFile = name.hasSuffix(" ---") ? String(name.dropLast(4)) : name
                inPathArray = false
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // zsh 的数组写法：export -T PATH path=( ... )
            if trimmed.contains("PATH") && trimmed.contains("path=(") {
                inPathArray = true
                continue
            }
            if inPathArray {
                if trimmed == ")" || trimmed.hasPrefix(")") {
                    inPathArray = false
                    continue
                }
                if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                    pathEntryCount += 1
                    if !seenPaths.insert(trimmed).inserted, !duplicates.contains(trimmed) {
                        duplicates.append(trimmed)
                    }
                }
                continue
            }

            // 传统写法：export PATH=/a:/b
            if trimmed.contains("PATH=") {
                let value = trimmed.components(separatedBy: "PATH=").last ?? ""
                let entries = value
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .split(separator: ":")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                pathEntryCount += entries.count
                var seen = Set<String>()
                for entry in entries {
                    if !seen.insert(entry).inserted, !duplicates.contains(entry) {
                        duplicates.append(entry)
                    }
                }
            }

            for variable in insecureShellVariables {
                guard trimmed.contains(variable.name) else { continue }
                guard let equals = trimmed.firstIndex(of: "=") else { continue }
                let value = String(trimmed[trimmed.index(after: equals)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                guard variable.badValues.contains(value) else { continue }
                if !insecure.contains(variable.name) { insecure.append(variable.name) }
                note(variable.name)
            }
        }

        return Dg2ShellConfig(pathEntryCount: pathEntryCount,
                              duplicatePathEntries: duplicates,
                              insecureSettings: insecure,
                              file: file)
    }

    /// which -a 的输出：一行一个路径。
    static func parseWhichPaths(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// brew list --formula / --cask。
    static func parseBrew(formulas: String, casks: String) -> Dg2Brew {
        func count(_ text: String) -> Int {
            text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.count
        }
        return Dg2Brew(formulaCount: count(formulas), caskCount: count(casks))
    }

    /// npm ls -g --depth=0。
    ///
    /// 坏掉的全局包在 npm 的输出里长这样：版本号是空的（软链接指到了不存在的地方），
    /// 或者名字后面跟着 invalid / UNMET DEPENDENCY。
    static func parseNpm(_ text: String) -> Dg2Npm {
        var packages: [String] = []
        var invalid: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.contains("invalid") || line.contains("UNMET DEPENDENCY") || line.contains("extraneous") {
                if !invalid.contains(line) { invalid.append(line) }
                continue
            }
            guard line.hasPrefix("├") || line.hasPrefix("└") else { continue }
            let name = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            packages.append(name)
            // 「名字@」后面没有版本号 —— npm 查不到这个包的版本，说明它没装好。
            if name.hasSuffix("@"), !invalid.contains(line) {
                invalid.append(line)
            }
        }
        return Dg2Npm(packageCount: packages.count, invalidPackages: invalid)
    }

    /// conda env list。
    static func parseCondaEnvs(_ text: String) -> [String] {
        var envs: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let name = fields.first, name.hasPrefix("/") == false else { continue }
            guard fields.contains(where: { $0.hasPrefix("/") }) else { continue }
            if !envs.contains(name) { envs.append(name) }
        }
        return envs
    }

    /// osascript 读 System Events 的登录项，返回 "AlDente, Vitals, CleanShot X"。
    ///
    /// 名字里带逗号的会被拆开 —— 极少见到，先不管。
    static func parseLoginItems(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// sfltool dumpbtm —— 系统登记的后台项。
    ///
    /// 每条记录里有一行「Name: xxx」，用来统计到底有多少个后台项被登记了。
    /// Disposition 那一行里的方括号列的是**全部可能的取值**（disabled 也在里面），
    /// 不能拿它判断某一项是不是被关掉了 —— 所以这里只数个数，不猜状态。
    static func parseBackgroundItems(_ text: String) -> Dg2BackgroundItems {
        var names: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Name:") else { continue }
            let value = String(line.dropFirst("Name:".count)).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if !names.contains(value) { names.append(value) }
        }
        return Dg2BackgroundItems(names: names)
    }

    /// pkgutil --pkgs。
    static func parseReceipts(_ text: String) -> Dg2Receipts {
        var all: [String] = []
        var thirdParty: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            all.append(line)
            if line.hasPrefix("com.apple.") { continue }
            thirdParty.append(line)
        }
        return Dg2Receipts(total: all.count, thirdParty: thirdParty)
    }

    /// kmutil showloaded —— 已加载的内核扩展。
    static func parseKexts(_ text: String) -> [String] {
        var kexts: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 6 else { continue }
            let name = fields[5]
            guard name.contains(".") else { continue }
            if name.hasPrefix("com.apple.") { continue }
            if kexts.contains(name) { continue }
            kexts.append(name)
        }
        return kexts
    }

    /// 同一个名字 / 同一个 bundle id 出现在多个位置 —— 重复安装。
    static func duplicateAppNames(_ entries: [Dg2AppEntry]) -> [String] {
        var byName: [String: Int] = [:]
        var byBundleID: [String: Int] = [:]
        for entry in entries {
            byName[entry.name, default: 0] += 1
            if let bundleID = entry.bundleID, !bundleID.isEmpty {
                byBundleID[bundleID, default: 0] += 1
            }
        }
        var duplicates: [String] = []
        for (name, count) in byName.sorted(by: { $0.key < $1.key }) where count > 1 {
            duplicates.append(name)
        }
        for (bundleID, count) in byBundleID.sorted(by: { $0.key < $1.key }) where count > 1 {
            let display = entries.first { $0.bundleID == bundleID }?.name ?? bundleID
            if !duplicates.contains(display) { duplicates.append(display) }
        }
        return duplicates
    }

    // MARK: 分组

    /// 把第二批事实变成报告分组。
    static func sections(from facts: Dg2ExtraFacts) -> [DiagnosticSection] {
        [kernelSection(facts),
         networkSection(facts),
         peripheralSection(facts),
         devSection(facts),
         softwareSection(facts)]
        .filter { !$0.items.isEmpty }
    }

    private static func kernelSection(_ f: Dg2ExtraFacts) -> DiagnosticSection {
        var items: [DiagnosticItem] = []

        // 内核资源上限
        switch f.kernelLimits {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.kernel_limits", "内核资源上限", reason))
        case .value(let values):
            let maxProc = values.int("kern.maxproc")
            let maxFiles = values.int("kern.maxfiles")
            let perProc = values.int("kern.maxfilesperproc")
            var parts: [String] = []
            if let maxProc { parts.append("进程数上限 \(maxProc)") }
            if let maxFiles { parts.append("文件句柄总数上限 \(maxFiles)") }
            if let perProc { parts.append("单进程句柄上限 \(perProc)") }
            var severity: DiagnosticSeverity = .info
            var suggestion: String?
            if let perProc, perProc < Dg2Thresholds.maxFilesPerProcWarning {
                severity = .warning
                suggestion = "单个进程能打开的文件数上限被调低到 \(perProc)（系统默认是 \(Dg2Thresholds.maxFilesPerProcWarning)）。程序会报「Too many open files」而莫名其妙地失败 —— 用 `sudo sysctl -w kern.maxfilesperproc=\(Dg2Thresholds.maxFilesPerProcWarning)` 恢复默认。"
            } else if let maxFiles, maxFiles < Dg2Thresholds.maxFilesWarning {
                severity = .warning
                suggestion = "系统文件句柄总数上限只有 \(maxFiles)，比系统默认低。开太多文件（含浏览器、Docker、虚拟机）时会耗尽。用 `sudo sysctl -w kern.maxfiles=245760` 之类恢复。"
            } else if let maxProc, maxProc < Dg2Thresholds.maxProcWarning {
                severity = .warning
                suggestion = "系统允许的进程数上限只有 \(maxProc)，偏小。开太多应用时会报「系统资源不足」或直接杀进程。"
            }
            items.append(DiagnosticItem(
                id: "dg2.kernel_limits",
                title: "内核资源上限",
                value: parts.isEmpty ? "读到了内核参数，但没有可用数值" : parts.joined(separator: " · "),
                severity: severity,
                suggestion: suggestion,
                detail: "这些值被改过（调低）时，程序会出现「Too many open files」「系统资源不足」这类说不清的失败。"))
        }

        // launchd 给任务的资源上限
        switch f.launchLimits {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.launch_limits", "进程资源上限（launchd）", reason))
        case .value(let limits):
            var parts: [String] = []
            if let soft = limits.maxFilesSoft {
                parts.append("文件句柄 软上限 \(soft)\(limits.maxFilesHard.map { " / 硬上限 \($0)" } ?? "")")
            }
            if let soft = limits.maxProcSoft {
                parts.append("进程数 软上限 \(soft)\(limits.maxProcHard.map { " / 硬上限 \($0)" } ?? "")")
            }
            var severity: DiagnosticSeverity = .info
            var suggestion: String?
            if let soft = limits.maxFilesSoft, let value = Int(soft), value < Dg2Thresholds.launchMaxFilesSoftWarning {
                severity = .warning
                suggestion = "后台任务的文件句柄软上限只有 \(value)，比系统默认还低 —— 跑久了会「Too many open files」。用 `sudo launchctl limit maxfiles \(value) unlimited` 之类放宽。"
            } else if let soft = limits.maxProcSoft, let value = Int(soft), value < Dg2Thresholds.launchMaxProcSoftWarning {
                severity = .warning
                suggestion = "后台任务的进程数软上限只有 \(value)，偏低。开很多应用时会直接失败。"
            }
            items.append(DiagnosticItem(
                id: "dg2.launch_limits",
                title: "进程资源上限（launchd）",
                value: parts.isEmpty ? "读到了 launchd 上限，但没有可用数值" : parts.joined(separator: " · "),
                severity: severity,
                suggestion: suggestion,
                detail: "普通应用实际拿到的上限还受它自己的 rlimit 影响；出现「Too many open files」时先看这一项。"))
        }

        // TCP 缓冲区
        switch f.tcpBuffers {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.tcp_buffers", "TCP 网络缓冲区", reason))
        case .value(let values):
            let send = values.int("net.inet.tcp.sendspace")
            let recv = values.int("net.inet.tcp.recvspace")
            let autoSend = values.int("net.inet.tcp.autosndbufmax")
            let autoRecv = values.int("net.inet.tcp.autorcvbufmax")
            var parts: [String] = []
            if let send { parts.append("发送 \(send) 字节") }
            if let recv { parts.append("接收 \(recv) 字节") }
            if let autoSend { parts.append("自动调优发送上限 \(autoSend) 字节") }
            if let autoRecv { parts.append("自动调优接收上限 \(autoRecv) 字节") }
            var severity: DiagnosticSeverity = .info
            var suggestion: String?
            if let send, send < Dg2Thresholds.tcpBufferWarning {
                severity = .warning
                suggestion = "TCP 发送缓冲区被调小到 \(send) 字节，传大文件 / 远程桌面会明显变慢。"
            } else if let autoSend, autoSend < Dg2Thresholds.tcpAutoBufferWarning {
                severity = .warning
                suggestion = "TCP 缓冲区自动调优上限只有 \(autoSend) 字节，高带宽网络上传下载会跑不满。"
            }
            items.append(DiagnosticItem(
                id: "dg2.tcp_buffers",
                title: "TCP 网络缓冲区",
                value: parts.isEmpty ? "读到了 TCP 参数，但没有可用数值" : parts.joined(separator: " · "),
                severity: severity,
                suggestion: suggestion))
        }

        // 交换空间容量
        switch f.swapCapacity {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.swap_capacity", "交换空间容量", reason))
        case .value(let swap):
            if swap.totalBytes == 0 {
                items.append(DiagnosticItem(
                    id: "dg2.swap_capacity",
                    title: "交换空间容量",
                    value: "没有启用交换空间",
                    severity: .warning,
                    suggestion: "这台机器没有交换空间。内存一紧张系统会直接杀进程，表现为应用莫名退出或系统卡死。"))
            } else {
                items.append(DiagnosticItem(
                    id: "dg2.swap_capacity",
                    title: "交换空间容量",
                    value: "共 \(DiagnosticEvaluator.formatBytes(swap.totalBytes)) · 已用 \(DiagnosticEvaluator.formatBytes(swap.usedBytes))",
                    severity: swap.totalBytes < Dg2Thresholds.swapTotalWarningBytes ? .warning : .info,
                    suggestion: swap.totalBytes < Dg2Thresholds.swapTotalWarningBytes
                        ? "交换空间总量不到 1 GB，内存不够用时系统很快就会开始杀进程。"
                        : nil,
                    detail: "剩余 \(DiagnosticEvaluator.formatBytes(swap.freeBytes))"))
            }
        }

        // CPU 物理核 / 逻辑核
        switch f.cpuTopology {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.cpu_topology", "CPU 物理核与逻辑核", reason))
        case .value(let topology):
            var parts: [String] = []
            if let physical = topology.physicalCores { parts.append("物理核 \(physical)") }
            if let logical = topology.logicalCores { parts.append("逻辑核 \(logical)") }
            items.append(DiagnosticItem(
                id: "dg2.cpu_topology",
                title: "CPU 物理核与逻辑核",
                value: parts.isEmpty ? "读到了 CPU 信息，但没有可用数值" : parts.joined(separator: " · "),
                severity: .info,
                detail: "两个数字相等说明这台机器没有超线程 —— 满载时能用的并行度就是物理核数。"))
        }

        // 加载失败的自启项
        switch f.launchFailures {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.launch_failures", "没跑起来的自启项", reason))
        case .value(let failures):
            let thirdParty = f.launchThirdPartyCount.value ?? 0
            if failures.isEmpty {
                items.append(DiagnosticItem(
                    id: "dg2.launch_failures",
                    title: "没跑起来的自启项",
                    value: thirdParty == 0 ? "没有第三方自启项" : "\(thirdParty) 个第三方自启项都在正常运行",
                    severity: .info,
                    detail: "launchctl 里退出码非 0 的第三方自启项（自启项写错路径、依赖缺失、权限不足都会这样）。"))
            } else {
                let detail = failures.map { item in
                    "\(item.label)（退出码 \(item.exitCode)，PID \(item.pid)）"
                }.joined(separator: "\n")
                items.append(DiagnosticItem(
                    id: "dg2.launch_failures",
                    title: "没跑起来的自启项",
                    value: "\(failures.count) 个第三方自启项没跑起来",
                    severity: .warning,
                    suggestion: "这些自启项登记了但没能正常启动（常见原因：程序被删了、路径变了、依赖缺失）。多数情况下它们每次开机都会失败一次并留下日志；在「系统设置 → 通用 → 登录项」里把对应的项关掉，或者把程序重新装一次。",
                    detail: detail))
            }
        }

        // APFS 本地快照
        switch f.snapshots {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.snapshots", "APFS 本地快照", reason))
        case .value(let snapshots):
            items.append(DiagnosticItem(
                id: "dg2.snapshots",
                title: "APFS 本地快照",
                value: "\(snapshots.count) 个",
                severity: snapshots.count > Dg2Thresholds.snapshotCountWarning ? .warning : .info,
                suggestion: snapshots.count > Dg2Thresholds.snapshotCountWarning
                    ? "本地快照积了 \(snapshots.count) 个，会一直占着磁盘空间。清掉不用的快照可以立刻腾出空间（系统更新留下的快照通常可以删）。"
                    : nil,
                detail: snapshots.names.prefix(10).joined(separator: "\n")
                    + (snapshots.names.count > 10 ? "\n（另有 \(snapshots.names.count - 10) 个）" : "")))
        }

        // Time Machine
        switch f.timeMachine {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.timemachine", "Time Machine 备份", reason))
        case .value(let tm):
            if let last = tm.lastBackup {
                items.append(DiagnosticItem(
                    id: "dg2.timemachine",
                    title: "Time Machine 备份",
                    value: "最近一次备份：\(last)",
                    severity: .info,
                    detail: tm.destinations.isEmpty ? nil : "备份目标：\(tm.destinations.joined(separator: "、"))"))
            } else {
                items.append(DiagnosticItem(
                    id: "dg2.timemachine",
                    title: "Time Machine 备份",
                    value: tm.destinations.isEmpty ? "没有可用的备份目标" : "没有找到可用的备份记录",
                    severity: .warning,
                    suggestion: "这台机器上没有可恢复的备份。磁盘一旦出问题就找不回来了 —— 准备一块外置硬盘，在「系统设置 → 通用 → Time Machine」里设一个备份目标。",
                    detail: tm.lastBackupError))
            }
        }

        // 聚焦索引
        switch f.spotlight {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.spotlight", "聚焦索引状态", reason))
        case .value(let states):
            if states.isEmpty {
                items.append(unavailableItem("dg2.spotlight", "聚焦索引状态", "没有读到任何卷的索引状态"))
            } else {
                let disabled = states.filter(\.indexingDisabled)
                let rootDisabled = disabled.contains { $0.path == "/" }
                items.append(DiagnosticItem(
                    id: "dg2.spotlight",
                    title: "聚焦索引状态",
                    value: rootDisabled ? "系统盘的聚焦索引已关闭" : "\(states.count) 个卷，索引正常",
                    severity: rootDisabled ? .warning : .info,
                    suggestion: rootDisabled
                        ? "系统盘的「聚焦」索引被关掉了 —— 搜索框搜不到文件和应用，Spotlight 建议也会失效。在「系统设置 → Siri 与 Spotlight → Spotlight 隐私」里把它打开。"
                        : nil,
                    detail: states.map { "\($0.path)：\($0.state)" }.joined(separator: "\n")))
            }
        }

        return DiagnosticSection(id: "kernel-extra", title: "内核与系统配置", icon: "gearshape.2", items: items)
    }

    private static func networkSection(_ f: Dg2ExtraFacts) -> DiagnosticSection {
        var items: [DiagnosticItem] = []

        // DNS
        switch f.dns {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.dns", "DNS 配置", reason))
        case .value(let dns):
            var severity: DiagnosticSeverity = .info
            var suggestion: String?
            if dns.nameservers.isEmpty {
                severity = .warning
                suggestion = "没有读到任何 DNS 服务器。DNS 没配好时表现为「网页打不开但别的都正常」——在「系统设置 → 网络 → DNS」里检查。"
            }
            var detail = dns.nameservers.isEmpty ? nil : "DNS 服务器：\(dns.nameservers.joined(separator: "、"))"
            if dns.mdnsResolverCount > 0 {
                detail = (detail ?? "") + "\nBonjour / mDNS 解析器 \(dns.mdnsResolverCount) 个"
            }
            if !dns.domains.isEmpty {
                detail = (detail ?? "") + "\n搜索域：\(dns.domains.prefix(5).joined(separator: "、"))"
            }
            items.append(DiagnosticItem(
                id: "dg2.dns",
                title: "DNS 配置",
                value: dns.nameservers.isEmpty ? "没有读到 DNS 服务器" : "\(dns.nameservers.count) 个 DNS 服务器",
                severity: severity,
                suggestion: suggestion,
                detail: detail))
        }

        // 网络服务与接口代理
        switch f.networkServices {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.network_services", "网络服务与接口代理", reason))
        case .value(let services):
            var severity: DiagnosticSeverity = .info
            var suggestion: String?
            if !services.proxiedInterfaces.isEmpty {
                severity = .warning
                suggestion = "有网络接口配置了代理（\(services.proxiedInterfaces.joined(separator: "、"))）。这不是故障，但代理软件退出后设置常常还留着，表现为「开了代理但没开软件，于是所有网页都打不开」。"
            }
            var detail: [String] = []
            if !services.services.isEmpty {
                detail.append("网络服务：\(services.services.joined(separator: "、"))")
            }
            if !services.disabledServices.isEmpty {
                detail.append("已禁用的服务：\(services.disabledServices.joined(separator: "、"))")
            }
            if !services.proxiedInterfaces.isEmpty {
                detail.append("配了代理的接口：\(services.proxiedInterfaces.joined(separator: "、"))")
            }
            items.append(DiagnosticItem(
                id: "dg2.network_services",
                title: "网络服务与接口代理",
                value: services.proxiedInterfaces.isEmpty
                    ? "\(services.services.count) 个网络服务，没有接口配代理"
                    : "\(services.proxiedInterfaces.count) 个接口配了代理",
                severity: severity,
                suggestion: suggestion,
                detail: detail.isEmpty ? nil : detail.joined(separator: "\n")))
        }

        // VPN
        switch f.vpn {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.vpn", "VPN 配置", reason))
        case .value(let configurations):
            items.append(DiagnosticItem(
                id: "dg2.vpn",
                title: "VPN 配置",
                value: configurations.isEmpty ? "没有配置 VPN 连接" : "\(configurations.count) 个 VPN 配置",
                severity: .info,
                detail: configurations.isEmpty ? nil : configurations.joined(separator: "\n")))
        }

        // 网络扩展（过滤器 / 隧道）
        switch f.networkExtensions {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.network_extensions", "网络扩展（过滤器 / 隧道）", reason))
        case .value(let extensions):
            if extensions.isEmpty {
                items.append(DiagnosticItem(
                    id: "dg2.network_extensions",
                    title: "网络扩展（过滤器 / 隧道）",
                    value: "没有第三方网络扩展",
                    severity: .info))
            } else {
                // 开关与状态不一致：系统里勾了「启用」，扩展自己却报 disabled。
                let mismatched = extensions.filter { $0.enabled && $0.state.lowercased().contains("disabled") }
                let filters = extensions.filter(\.isFilter)
                let tunnels = extensions.filter(\.isTunnel)
                items.append(DiagnosticItem(
                    id: "dg2.network_extensions",
                    title: "网络扩展（过滤器 / 隧道）",
                    value: "\(extensions.count) 个第三方网络扩展"
                        + (filters.isEmpty ? "" : "（含 \(filters.count) 个内容过滤器）")
                        + (tunnels.isEmpty ? "" : "（含 \(tunnels.count) 个隧道 / VPN）"),
                    severity: mismatched.isEmpty ? .info : .warning,
                    suggestion: mismatched.isEmpty
                        ? nil
                        : "这些网络扩展在系统里是「启用」状态，但扩展自己报告已停用：\(mismatched.map(\.name).joined(separator: "、"))。它们没有真正生效 —— 在「系统设置 → 通用 → 登录项与扩展」里关掉再打开一次。",
                    detail: extensions.map { item in
                        let mark = item.enabled ? "已启用" : "未启用"
                        return "\(item.name)（\(item.bundleID)）· \(mark) · \(item.state)"
                    }.joined(separator: "\n")))
            }
        }

        // XProtect 版本
        switch f.xprotectVersion {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.xprotect", "XProtect 版本", reason))
        case .value(let version):
            items.append(DiagnosticItem(
                id: "dg2.xprotect",
                title: "XProtect 版本",
                value: version,
                severity: .info,
                detail: "XProtect 是 macOS 自带的恶意软件识别库。版本偏旧说明很久没更新过系统了。"))
        }

        // 配置描述文件 / MDM
        switch f.profiles {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.profiles", "配置描述文件与 MDM", reason))
        case .value(let profiles):
            if profiles.isEmpty {
                items.append(DiagnosticItem(
                    id: "dg2.profiles",
                    title: "配置描述文件与 MDM",
                    value: "没有安装任何配置描述文件",
                    severity: .info))
            } else {
                let byMDM = profiles.filter(\.installedByMDM)
                let restricted = profiles.filter(\.restricted)
                var severity: DiagnosticSeverity = .info
                var suggestion: String?
                if !restricted.isEmpty {
                    severity = .warning
                    suggestion = "存在「限制」类配置描述文件（\(restricted.compactMap(\.name).joined(separator: "、"))）。它会限制软件安装、摄像头、屏幕录制等权限 —— 某些功能「打不开」往往是它造成的。"
                } else if !byMDM.isEmpty {
                    suggestion = "这台机器受 MDM 管理（\(byMDM.count) 个描述文件由 MDM 下发）。公司设备上的权限限制、代理、后台项都会由它控制，出问题时先问 IT。"
                }
                items.append(DiagnosticItem(
                    id: "dg2.profiles",
                    title: "配置描述文件与 MDM",
                    value: "\(profiles.count) 个描述文件"
                        + (byMDM.isEmpty ? "" : "（\(byMDM.count) 个由 MDM 下发）"),
                    severity: severity,
                    suggestion: suggestion,
                    detail: profiles.map { profile in
                        let name = profile.name ?? "未命名描述文件"
                        let mdm = profile.installedByMDM ? " · MDM 下发" : ""
                        return "\(name)\(mdm)"
                    }.joined(separator: "\n")))
            }
        }

        // 安全 / MDM 客户端
        switch f.securityAgents {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.security_agents", "安全 / MDM 客户端", reason))
        case .value(let agents):
            items.append(DiagnosticItem(
                id: "dg2.security_agents",
                title: "安全 / MDM 客户端",
                value: agents.isEmpty ? "没有检测到安全或 MDM 客户端" : "\(agents.count) 个：\(agents.joined(separator: "、"))",
                severity: .info,
                detail: "这类客户端会接管网络过滤、软件安装与权限审批 —— 出问题时它们常常是根因。"))
        }

        // 受保护目录
        switch f.protectedDirs {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.protected_dirs", "受保护目录访问概览", reason))
        case .value(let dirs):
            let blocked = dirs.filter { !$0.accessible }
            items.append(DiagnosticItem(
                id: "dg2.protected_dirs",
                title: "受保护目录访问概览",
                value: blocked.isEmpty
                    ? "\(dirs.count) 个受保护目录都能正常读取"
                    : "\(blocked.count) 个受保护目录读不到",
                severity: blocked.isEmpty ? .info : .warning,
                suggestion: blocked.isEmpty
                    ? nil
                    : "这些目录系统不允许普通程序读取：\(blocked.map(\.name).joined(separator: "、"))。macOS 出于隐私保护会拦这类访问 —— 需要读它们的应用要在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里被明确授权。",
                detail: dirs.map { dir in
                    "\(dir.name)：\(dir.accessible ? "可读，\(dir.itemCount) 项" : "读不到")"
                }.joined(separator: "\n")))
        }

        return DiagnosticSection(id: "network-extra", title: "网络与安全", icon: "network", items: items)
    }

    private static func peripheralSection(_ f: Dg2ExtraFacts) -> DiagnosticSection {
        var items: [DiagnosticItem] = []

        // 输入法
        switch f.inputSources {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.input_sources", "输入法与键盘布局", reason))
        case .value(let sources):
            items.append(DiagnosticItem(
                id: "dg2.input_sources",
                title: "输入法与键盘布局",
                value: "\(sources.total) 个已启用",
                severity: .info,
                detail: "其中 \(sources.nonKeyboard) 个是输入法 / 特殊键盘。输入法异常（打不出字、候选框不弹）时先在这里看有没有被禁用的输入源。"))
        }

        // 音频设备
        switch f.audio {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.audio", "音频设备", reason))
        case .value(let audio):
            var severity: DiagnosticSeverity = .info
            var suggestion: String?
            if audio.deviceNames.isEmpty {
                severity = .warning
                suggestion = "没有读到任何音频设备。系统里看不到声卡时，程序没有声音却不会报错 —— 检查耳机 / 显示器是否被独占音频。"
            } else if audio.defaultOutput == nil {
                severity = .warning
                suggestion = "读到了音频设备，但没有默认输出设备。没有默认输出时程序会「没声音」，但音量条还是能动。"
            }
            items.append(DiagnosticItem(
                id: "dg2.audio",
                title: "音频设备",
                value: audio.deviceNames.isEmpty
                    ? "没有读到音频设备"
                    : "\(audio.deviceNames.count) 个设备"
                        + (audio.defaultOutput.map { " · 默认输出 \($0)" } ?? ""),
                severity: severity,
                suggestion: suggestion,
                detail: audio.deviceNames.joined(separator: "\n")))
        }

        // 打印机
        switch f.printers {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.printers", "打印机", reason))
        case .value(let printers):
            let offline = printers.filter { ($0.status ?? "").lowercased().contains("offline") }
            items.append(DiagnosticItem(
                id: "dg2.printers",
                title: "打印机",
                value: printers.isEmpty
                    ? "没有配置打印机"
                    : "\(printers.count) 台"
                        + (offline.isEmpty ? "" : "（\(offline.count) 台离线）"),
                severity: .info,
                detail: printers.isEmpty
                    ? nil
                    : printers.map { printer in
                        "\(printer.name)\(printer.status.map { " · \($0)" } ?? "")"
                    }.joined(separator: "\n")))
        }

        // 雷雳 / USB4
        switch f.usb {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.thunderbolt", "雷雳 / USB4 接口", reason))
        case .value(let usb):
            items.append(DiagnosticItem(
                id: "dg2.thunderbolt",
                title: "雷雳 / USB4 接口",
                value: "\(usb.busCount) 条总线 · \(usb.freePorts) 个空闲口",
                severity: .info,
                detail: "已占用 \(usb.occupiedPorts) 个"
                    + (usb.usbListEmpty ? "\nSPUSBDataType 没有输出（这台机器没读到直连 USB 设备，配件多半挂在雷雳总线上）。" : "")))
        }

        // 字体
        switch f.fonts {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.fonts", "已安装字体", reason))
        case .value(let fonts):
            items.append(DiagnosticItem(
                id: "dg2.fonts",
                title: "已安装字体",
                value: "\(fonts.total) 个字体文件",
                severity: .info,
                detail: "其中 \(fonts.userInstalled) 个装在当前用户目录（~/Library/Fonts）。字体缺失会让排版错乱、PDF 变成方块 —— 打开别人的文件前先确认字体齐不齐。"))
        }

        // 电池（ioreg）
        switch f.battery {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.battery_ioreg", "电池循环与容量（ioreg 读取）", reason))
        case .value(let battery):
            var parts: [String] = []
            if let cycles = battery.cycleCount { parts.append("循环 \(cycles) 次") }
            if let full = battery.fullChargeCapacity, let design = battery.designCapacity {
                parts.append("满充 \(full)/\(design) mAh")
            }
            if let health = battery.healthPercent {
                parts.append(String(format: "健康度 %.0f%%", health))
            }
            if let current = battery.currentCapacityPercent { parts.append("电量 \(current)%") }
            if let external = battery.externallyConnected {
                parts.append(external ? "已接电源" : "未接电源")
            }
            var severity: DiagnosticSeverity = .info
            var suggestion: String?
            if let health = battery.healthPercent, health < 80 {
                severity = .warning
                suggestion = "电池健康度只剩 \(String(format: "%.0f", health))%，续航会明显变短。到「系统设置 → 电池 → 电池健康」看是否提示需要维修。"
            } else if let cycles = battery.cycleCount, cycles >= 1000 {
                severity = .warning
                suggestion = "电池已经循环 \(cycles) 次，容量衰减明显。留意续航变化，必要时更换电池。"
            }
            items.append(DiagnosticItem(
                id: "dg2.battery_ioreg",
                title: "电池循环与容量（ioreg 读取）",
                value: parts.isEmpty ? "读到了电池信息，但没有可用数值" : parts.joined(separator: " · "),
                severity: severity,
                suggestion: suggestion,
                detail: "这一项直接从内核的电池信息读，跟「存储与电池」组里的读数互相印证。"))
        }

        return DiagnosticSection(id: "peripheral-extra", title: "外设与输入", icon: "printer", items: items)
    }

    private static func devSection(_ f: Dg2ExtraFacts) -> DiagnosticSection {
        var items: [DiagnosticItem] = []

        // Shell 配置
        switch f.shellConfig {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.shell_config", "Shell 配置与 PATH", reason))
        case .value(let config):
            var severity: DiagnosticSeverity = .info
            var suggestion: String?
            var detail: [String] = []
            if !config.insecureSettings.isEmpty {
                severity = .warning
                suggestion = "这些环境变量关掉了证书校验（\(config.insecureSettings.joined(separator: "、"))）\(config.file.map { "，出现在 \($0)" } ?? "")。开了之后抓包、代理、翻墙类操作不会被证书拦住，但中间人也能插进来 —— 只在明确需要时保留。"
                detail.append("来源：\(config.file ?? "shell 配置文件")")
            }
            if !config.duplicatePathEntries.isEmpty {
                if severity == .info { severity = .warning }
                suggestion = suggestion ?? "PATH 里有重复目录（\(config.duplicatePathEntries.joined(separator: "、"))）。重复目录会让同名的可执行文件「到底是哪一个」变得不确定 —— 清理掉重复项。"
                detail.append("PATH 重复目录：\(config.duplicatePathEntries.joined(separator: "、"))")
            }
            detail.append("PATH 里共 \(config.pathEntryCount) 个目录")
            items.append(DiagnosticItem(
                id: "dg2.shell_config",
                title: "Shell 配置与 PATH",
                value: config.insecureSettings.isEmpty && config.duplicatePathEntries.isEmpty
                    ? "PATH \(config.pathEntryCount) 个目录，没有发现异常"
                    : "发现 \(config.insecureSettings.count + config.duplicatePathEntries.count) 处异常",
                severity: severity,
                suggestion: suggestion,
                detail: detail.joined(separator: "\n")))
        }

        // 开发工具路径
        switch f.devPaths {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.dev_paths", "开发工具路径", reason))
        case .value(let tools):
            let conflicting = tools.filter { $0.paths.count > 1 }
            items.append(DiagnosticItem(
                id: "dg2.dev_paths",
                title: "开发工具路径",
                value: tools.isEmpty
                    ? "没有找到常见的开发工具"
                    : "\(tools.count) 个工具，\(conflicting.count) 个有多个候选路径",
                severity: .info,
                detail: tools.map { tool in
                    "\(tool.tool)：\(tool.paths.joined(separator: " → "))"
                }.joined(separator: "\n")))
        }

        // 容器运行时
        switch f.containers {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.containers", "容器运行时", reason))
        case .value(let runtimes):
            items.append(DiagnosticItem(
                id: "dg2.containers",
                title: "容器运行时",
                value: runtimes.isEmpty ? "没有检测到容器运行时" : "\(runtimes.count) 个",
                severity: .info,
                detail: runtimes.isEmpty
                    ? "没有 Docker / Podman / OrbStack 之类的容器运行时。"
                    : runtimes.map { runtime in
                        "\(runtime.name)\(runtime.version.map { " · \($0)" } ?? "")"
                    }.joined(separator: "\n")))
        }

        // Homebrew
        switch f.brew {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.brew", "Homebrew 全局包", reason))
        case .value(let brew):
            items.append(DiagnosticItem(
                id: "dg2.brew",
                title: "Homebrew 全局包",
                value: "\(brew.formulaCount) 个 formula · \(brew.caskCount) 个 cask",
                severity: .info,
                detail: "brew 的全局包会往 PATH 里塞自己的 bin 目录；装得太多时 PATH 会变得很长，命令到底跑的是哪一个就不确定了。"))
        }

        // npm 全局包
        switch f.npm {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.npm", "Node 全局包", reason))
        case .value(let npm):
            var severity: DiagnosticSeverity = .info
            var suggestion: String?
            if !npm.invalidPackages.isEmpty {
                severity = .warning
                suggestion = "有 \(npm.invalidPackages.count) 个全局包依赖没装齐（npm 标成 invalid）。这类包运行时会直接报模块找不到 —— 用 `npm ls -g` 看具体是哪个，然后重装它。"
            } else if npm.packageCount > Dg2Thresholds.npmPackageCountWarning {
                severity = .warning
                suggestion = "全局装了 \(npm.packageCount) 个包，偏多。全局包越多越容易和项目里的本地版本打架。"
            }
            items.append(DiagnosticItem(
                id: "dg2.npm",
                title: "Node 全局包",
                value: "\(npm.packageCount) 个全局包",
                severity: severity,
                suggestion: suggestion,
                detail: npm.invalidPackages.isEmpty ? nil : npm.invalidPackages.joined(separator: "\n")))
        }

        // Python 环境
        switch f.pythonEnvs {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.python_envs", "Python 环境", reason))
        case .value(let envs):
            items.append(DiagnosticItem(
                id: "dg2.python_envs",
                title: "Python 环境",
                value: envs.isEmpty ? "没有检测到 conda 环境" : "\(envs.count) 个 conda 环境",
                severity: .info,
                detail: envs.isEmpty ? nil : envs.joined(separator: "、")))
        }

        return DiagnosticSection(id: "dev-extra", title: "开发环境", icon: "terminal", items: items)
    }

    private static func softwareSection(_ f: Dg2ExtraFacts) -> DiagnosticSection {
        var items: [DiagnosticItem] = []

        // 已安装应用
        switch f.apps {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.apps", "已安装应用", reason))
        case .value(let apps):
            let broken = apps.entries.filter { $0.brokenReason != nil }
            items.append(DiagnosticItem(
                id: "dg2.apps",
                title: "已安装应用",
                value: "\(apps.entries.count) 个"
                    + (broken.isEmpty ? "" : "（\(broken.count) 个疑似损坏）"),
                severity: broken.isEmpty ? .info : .warning,
                suggestion: broken.isEmpty
                    ? nil
                    : "这些应用看起来不完整：\(broken.map(\.name).joined(separator: "、"))。删掉重装通常就好了 —— 直接拖废纸篓可能清不干净，要用 App Cleaner 之类的工具删掉残留。",
                detail: broken.isEmpty
                    ? nil
                    : broken.map { entry in
                        "\(entry.name)：\(entry.brokenReason ?? "")（\(entry.path)）"
                    }.joined(separator: "\n")))
        }

        // 重复安装
        switch f.apps {
        case .unavailable:
            break
        case .value(let apps):
            let duplicates = duplicateAppNames(apps.entries)
            if duplicates.isEmpty {
                items.append(DiagnosticItem(
                    id: "dg2.app_duplicates",
                    title: "重复安装的应用",
                    value: "没有重复安装的应用",
                    severity: .info))
            } else {
                items.append(DiagnosticItem(
                    id: "dg2.app_duplicates",
                    title: "重复安装的应用",
                    value: "\(duplicates.count) 个应用装了多份",
                    severity: .warning,
                    suggestion: "同一个应用装在多个位置时，系统只会认其中一个，另一个会变成「打不开」或者打开的是旧版本。删掉多余的副本，只留一份。",
                    detail: duplicates.joined(separator: "、")))
            }
        }

        // 登录项
        switch f.loginItems {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.login_items", "登录时自动打开的应用", reason))
        case .value(let loginItems):
            items.append(DiagnosticItem(
                id: "dg2.login_items",
                title: "登录时自动打开的应用",
                value: loginItems.isEmpty ? "没有登录项" : "\(loginItems.count) 个",
                severity: .info,
                detail: loginItems.isEmpty ? nil : loginItems.joined(separator: "、")))
        }

        // 系统登记的后台项
        switch f.backgroundItems {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.background_items", "系统登记的后台项", reason))
        case .value(let background):
            items.append(DiagnosticItem(
                id: "dg2.background_items",
                title: "系统登记的后台项",
                value: background.names.isEmpty ? "没有登记的后台项" : "\(background.names.count) 个",
                severity: .info,
                detail: background.names.isEmpty
                    ? nil
                    : background.names.prefix(20).joined(separator: "、")
                        + (background.names.count > 20 ? "（另有 \(background.names.count - 20) 个）" : "")))
        }

        // 安装收据
        switch f.receipts {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.receipts", "已安装软件包收据", reason))
        case .value(let receipts):
            items.append(DiagnosticItem(
                id: "dg2.receipts",
                title: "已安装软件包收据",
                value: "\(receipts.total) 个收据",
                severity: .info,
                detail: receipts.thirdParty.isEmpty
                    ? "没有第三方安装包收据（全是系统自带的）。"
                    : "其中 \(receipts.thirdParty.count) 个是第三方安装包。"))
        }

        // 第三方内核扩展
        switch f.kexts {
        case .unavailable(let reason):
            items.append(unavailableItem("dg2.kexts", "第三方内核扩展", reason))
        case .value(let kexts):
            items.append(DiagnosticItem(
                id: "dg2.kexts",
                title: "第三方内核扩展",
                value: kexts.isEmpty ? "没有第三方内核扩展" : "\(kexts.count) 个",
                severity: .info,
                detail: kexts.isEmpty
                    ? "没有加载第三方内核扩展 —— 虚拟磁盘、杀毒、网络过滤之类的驱动都没装。"
                    : kexts.joined(separator: "\n")))
        }

        return DiagnosticSection(id: "software-extra", title: "已安装软件", icon: "app.badge", items: items)
    }

    // MARK: 小工具

    /// 造一条「读不到」的项。跟判定层一个写法：值里带上原因，严重度按正常处理。
    private static func unavailableItem(_ id: String, _ title: String, _ reason: String) -> DiagnosticItem {
        DiagnosticItem(id: id,
                       title: title,
                       value: "无法读取（\(reason)）",
                       severity: .info)
    }
}
