//
//  DiagnosticsExtras.swift
//  Deep Sleep
//
//  设备诊断的**扩展检查项**：把命令的原始输出解析成事实，再把事实变成报告里的条目。
//
//  分工（与 DeviceDiagnostics.swift 的边界）：
//    - DeviceDiagnostics.swift 负责跑命令、把原始文本取回来；
//    - 本文件只做解析与判定，不碰系统状态，也不发起任何进程。
//
//  为什么单独一个文件：
//    这一层是纯逻辑（只依赖 Foundation），scripts/test-diagnostic-rules.swift
//    能把它跟 Shared/DiagnosticModel.swift 一起单独编译起来跑断言 ——
//    不用启动 App、不用连特权助手、更不碰真机状态。
//
//  命名：新增类型一律带 Dg 前缀，避免跟别的并行改动重名。
//

import Foundation

// MARK: - 事实类型

/// SPHardwareDataType：硬件概览。
struct DgHardwareProfile: Equatable {
    var modelName: String?
    var chipName: String?
    var cores: DgCoreProfile?
    /// 「8 GB」
    var memoryText: String?
    /// 「20457.41.3」
    var firmwareVersion: String?
    /// 「Enabled」/「Disabled」
    var activationLock: String?
    /// 内存插槽数。只有 Intel 机型会报这个字段，Apple Silicon 是统一内存。
    var memorySlots: Int?
}

/// CPU 核心构成。
struct DgCoreProfile: Equatable {
    var total: Int?
    var performance: Int?
    var efficiency: Int?

    /// 人话版本：「8 核（4 性能 + 4 能效）」。
    var summary: String {
        guard let total else { return "核心数未知" }
        if let performance, let efficiency {
            return "\(total) 核（\(performance) 性能 + \(efficiency) 能效）"
        }
        return "\(total) 核"
    }
}

/// SPDisplaysDataType：显卡。
struct DgGraphicsProfile: Equatable {
    /// 「Apple M2」
    var chipsetModel: String?
    /// GPU 核心数。
    var coreCount: Int?
    /// 显存（Intel 独显才有这个字段）。
    var videoMemory: String?
}

/// 一块物理磁盘。
struct DgStorageDrive: Equatable {
    /// 「APPLE SSD AP0512Z」
    var deviceName: String?
    /// 「SSD」
    var mediumType: String?
    /// 「Verified」
    var smartStatus: String?

    /// SMART 是否通过。
    var smartVerified: Bool {
        guard let smartStatus else { return false }
        return smartStatus.lowercased().contains("verified")
    }

    /// SMART 明确没通过。没报 SMART 状态不算「没通过」——
    /// 虚拟磁盘、挂载镜像本来就没有这一项。
    var smartFailed: Bool {
        guard let smartStatus else { return false }
        return !smartStatus.lowercased().contains("verified")
    }
}

/// SPSoftwareDataType：软件与启动状态。
struct DgSoftwareProfile: Equatable {
    /// 「Normal」/「Safe Mode」
    var bootMode: String?
    /// 「Enabled」/「Disabled」
    var secureVirtualMemory: String?
    /// 「Macintosh HD」
    var bootVolume: String?

    /// 是否安全启动。
    var isSafeMode: Bool {
        guard let bootMode else { return false }
        return bootMode.lowercased().contains("safe")
    }
}

/// 电源状态（pmset -g batt）。
struct DgPowerProfile: Equatable {
    /// 「交流电」/「电池」
    var source: String?
    /// 电量百分比。
    var percent: Int?
}

/// 一个进程的 CPU 占用。
struct DgCPUProcess: Equatable {
    var pid: Int
    var name: String
    var cpuPercent: Double
}

/// 一个第三方系统扩展。
struct DgSystemExtension: Equatable {
    var name: String
    var bundleID: String
    var teamID: String
    /// 「[activated enabled]」
    var state: String
    /// 是否启用（表格第一列是 `*`）。
    var enabled: Bool
}

/// 崩溃报告统计。
struct DgCrashProfile: Equatable {
    /// 当前用户目录下的报告数。
    var userReportCount: Int
    /// 系统目录下的报告数。
    var systemReportCount: Int
    /// 内核崩溃（panic）报告数。
    var panicCount: Int
    /// 最近一份报告的文件名。
    var newestReportName: String?
    /// 最近一份报告的时间。
    var newestReportDate: Date?
}

/// inode 使用情况。
struct DgInodeProfile: Equatable {
    var usedPercent: Double
    var used: Int
    var free: Int
}

/// 扩展检查项用到的全部事实。
struct DgExtraFacts {
    var hardware: DiagnosticFact<DgHardwareProfile> = .unavailable(reason: "未采集")
    var graphics: DiagnosticFact<DgGraphicsProfile> = .unavailable(reason: "未采集")
    var storage: DiagnosticFact<[DgStorageDrive]> = .unavailable(reason: "未采集")
    var software: DiagnosticFact<DgSoftwareProfile> = .unavailable(reason: "未采集")
    /// SMC 控制器是否在位。
    var smcPresent: DiagnosticFact<Bool> = .unavailable(reason: "未采集")
    var power: DiagnosticFact<DgPowerProfile> = .unavailable(reason: "未采集")
    /// 正在阻止自动睡眠 / 显示器休眠的进程。
    var sleepBlockers: DiagnosticFact<[String]> = .unavailable(reason: "未采集")
    /// 定时唤醒计划。
    var scheduledWake: DiagnosticFact<[String]> = .unavailable(reason: "未采集")
    var topCPU: DiagnosticFact<[DgCPUProcess]> = .unavailable(reason: "未采集")
    var systemExtensions: DiagnosticFact<[DgSystemExtension]> = .unavailable(reason: "未采集")
    var crash: DiagnosticFact<DgCrashProfile> = .unavailable(reason: "未采集")
    var timezone: DiagnosticFact<String> = .unavailable(reason: "未采集")
    /// 网络时间同步状态。读不到时说明原因（多数机器需要管理员权限）。
    var timeSync: DiagnosticFact<String> = .unavailable(reason: "未采集")
    var groups: DiagnosticFact<[String]> = .unavailable(reason: "未采集")
    var inode: DiagnosticFact<DgInodeProfile> = .unavailable(reason: "未采集")
    /// hosts 里真正生效的条目。
    var hostsEntries: DiagnosticFact<[String]> = .unavailable(reason: "未采集")
    /// 第三方开机项（名称 + 路径）。
    var thirdPartyLaunchItems: DiagnosticFact<[String]> = .unavailable(reason: "未采集")
}

// MARK: - 解析与判定

/// 扩展检查项的解析与判定。
enum DgExtra {

    // MARK: 解析

    /// 「键: 值」取值。键要完全相等 —— 「Model Name」不能命中「Model Identifier」。
    static func value(_ key: String, in text: String) -> String? {
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard name == key else { continue }
            let result = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !result.isEmpty else { continue }
            return result
        }
        return nil
    }

    /// 硬件概览。
    static func parseHardwareProfile(_ text: String) -> DgHardwareProfile? {
        let model = value("Model Name", in: text)
        let chip = value("Chip", in: text)
        let firmware = value("System Firmware Version", in: text)
        let activation = value("Activation Lock Status", in: text)
        let memory = value("Memory", in: text)
        let slotsText = value("Slots", in: text)
        let cores = parseCoreProfile(value("Total Number of Cores", in: text))
        guard model != nil || chip != nil || firmware != nil || memory != nil || cores != nil else {
            return nil
        }
        return DgHardwareProfile(modelName: model,
                                chipName: chip,
                                cores: cores,
                                memoryText: memory,
                                firmwareVersion: firmware,
                                activationLock: activation,
                                memorySlots: slotsText.flatMap(Int.init))
    }

    /// 「Total Number of Cores: 8 (4 Performance and 4 Efficiency)」
    static func parseCoreProfile(_ text: String?) -> DgCoreProfile? {
        guard let text else { return nil }
        let total = firstNumber(in: text)
        let performance = number(in: text, pattern: "(\\d+)\\s+Performance")
        let efficiency = number(in: text, pattern: "(\\d+)\\s+Efficiency")
        guard total != nil || performance != nil || efficiency != nil else { return nil }
        return DgCoreProfile(total: total, performance: performance, efficiency: efficiency)
    }

    /// 显卡。
    static func parseGraphicsProfile(_ text: String) -> DgGraphicsProfile? {
        let chipset = value("Chipset Model", in: text)
        let cores = firstNumber(in: value("Total Number of Cores", in: text) ?? "")
        let vram = value("VRAM", in: text) ?? value("Video Memory", in: text)
        guard chipset != nil || cores != nil || vram != nil else { return nil }
        return DgGraphicsProfile(chipsetModel: chipset, coreCount: cores, videoMemory: vram)
    }

    /// 磁盘。SPStorageDataType 里每块盘有一段「Physical Drive:」，逐段解析。
    ///
    /// 两点要处理：
    ///   - 同一块物理盘会被多个卷重复列出来，按「盘名 + 介质类型」去重；
    ///   - 挂载的磁盘镜像（Disk Image）不是真盘，没有 SMART 状态，直接跳过。
    static func parseStorageDrives(_ text: String) -> [DgStorageDrive] {
        var drives: [DgStorageDrive] = []
        var seen = Set<String>()
        var blocks: [[String]] = [[]]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "Physical Drive:" {
                blocks.append([])
                continue
            }
            blocks[blocks.count - 1].append(line)
        }
        for block in blocks {
            let joined = block.joined(separator: "\n")
            let name = value("Device Name", in: joined)
            let medium = value("Medium Type", in: joined)
            let smart = value("S.M.A.R.T. Status", in: joined)
            guard name != nil || medium != nil || smart != nil else { continue }
            let deviceName = name ?? "未命名磁盘"
            if deviceName.contains("Disk Image") { continue }
            guard seen.insert("\(deviceName)|\(medium ?? "")").inserted else { continue }
            drives.append(DgStorageDrive(deviceName: name,
                                        mediumType: medium,
                                        smartStatus: smart))
        }
        return drives
    }

    /// 软件与启动状态。
    static func parseSoftwareProfile(_ text: String) -> DgSoftwareProfile? {
        let bootMode = value("Boot Mode", in: text)
        let secure = value("Secure Virtual Memory", in: text)
        let volume = value("Boot Volume", in: text)
        guard bootMode != nil || secure != nil || volume != nil else { return nil }
        return DgSoftwareProfile(bootMode: bootMode,
                                 secureVirtualMemory: secure,
                                 bootVolume: volume)
    }

    /// 电源来源与电量。pmset -g batt 的输出形如：
    ///   Now drawing from 'AC Power'
    ///    -InternalBattery-0 (id=9109603)  80%; AC attached; not charging present: true
    static func parsePowerProfile(_ text: String) -> DgPowerProfile? {
        var source: String?
        if let range = text.range(of: "Now drawing from '([^']+)'", options: .regularExpression) {
            let raw = text[range].dropFirst("Now drawing from '".count).dropLast()
            switch raw {
            case "AC Power":      source = "交流电"
            case "Battery Power": source = "电池"
            default:              source = String(raw)
            }
        }
        // 电量：取带 % 的那一行 —— 上面那行的 (id=...) 里也有数字，不能拿错。
        var percent: Int?
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: "(\\d+)%", options: .regularExpression) else { continue }
            percent = Int(line[range].dropLast())
            break
        }
        guard source != nil || percent != nil else { return nil }
        return DgPowerProfile(source: source, percent: percent)
    }

    /// 阻止自动睡眠 / 显示器休眠的进程。
    /// pmset -g 的输出形如：
    ///   sleep                1 (sleep prevented by UURemote, coreaudiod, powerd)
    ///   displaysleep         0 (display sleep prevented by 哔哩哔哩)
    static func parseSleepBlockers(_ text: String) -> [String] {
        var names: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let open = line.range(of: "sleep prevented by "),
                  let close = line.range(of: ")", range: open.upperBound..<line.endIndex) else {
                continue
            }
            let list = line[open.upperBound..<close.lowerBound]
            for name in list.split(separator: ",") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if !names.contains(trimmed) { names.append(trimmed) }
            }
        }
        return names
    }

    /// 定时唤醒计划。pmset -g sched 没有输出就是「没有计划」。
    static func parseScheduledWake(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// CPU 占用 Top N。
    ///
    /// top 的输出里「PID COMMAND %CPU」这个表头会出现多次（每采样一次一个），
    /// 第一次采样还没有历史值，所以取**最后一段**表头后面的数据。
    static func parseTopCPU(_ text: String, limit: Int = 5) -> [DgCPUProcess] {
        let lines = text.split(separator: "\n").map(String.init)
        var headerIndex: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("PID") && trimmed.contains("%CPU") {
                headerIndex = index
            }
        }
        guard let headerIndex else { return [] }

        var result: [DgCPUProcess] = []
        for line in lines[(headerIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 3,
                  let pid = Int(parts[0]),
                  let cpu = Double(parts[parts.count - 1]) else { continue }
            let name = parts[1..<(parts.count - 1)].joined(separator: " ")
            result.append(DgCPUProcess(pid: pid, name: name, cpuPercent: cpu))
            if result.count >= limit { break }
        }
        return result
    }

    /// 第三方系统扩展。
    ///
    /// systemextensionsctl list 是**制表符**分隔的：
    ///   enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    static func parseSystemExtensions(_ text: String) -> [DgSystemExtension] {
        var result: [DgSystemExtension] = []
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            guard line.contains("\t") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6 else { continue }
            // 表头那一行（enabled / active / teamID / …）不是扩展，跳过。
            guard fields[0].trimmingCharacters(in: .whitespaces) != "enabled" else { continue }
            let enabled = fields[0].trimmingCharacters(in: .whitespaces) == "*"
            let teamID = fields[2].trimmingCharacters(in: .whitespaces)
            let bundleField = fields[3].trimmingCharacters(in: .whitespaces)
            let name = fields[4].trimmingCharacters(in: .whitespaces)
            let state = fields[5].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            // 版本号跟在 bundle id 后面的括号里，去掉更好读。
            let bundleID = bundleField.split(separator: " ").first.map(String.init) ?? bundleField
            // Apple 自家的不算「第三方」。
            guard !bundleID.hasPrefix("com.apple.") else { continue }
            result.append(DgSystemExtension(name: name,
                                            bundleID: bundleID,
                                            teamID: teamID,
                                            state: state,
                                            enabled: enabled))
        }
        return result
    }

    /// hosts 里真正生效的条目（去掉空行与注释）。
    static func parseHostsEntries(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// inode 使用。df -i 的输出形如：
    ///   Filesystem 512-blocks Used Available Capacity iused ifree %iused Mounted on
    ///   /dev/disk3s1  965595304 27308888 340795272  8%  486810 1703976360  0%  /
    ///
    /// 表头里也有「%iused」这一列，所以先找到表头，再取它下面的第一行数据 ——
    /// 直接按列号取会把表头当成数据。
    static func parseInodeProfile(_ text: String) -> DgInodeProfile? {
        let lines = text.split(separator: "\n").map(String.init)
        guard let headerIndex = lines.firstIndex(where: { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" }).contains("%iused")
        }) else { return nil }
        for line in lines[(headerIndex + 1)...] {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 8,
                  let used = Int(parts[5]),
                  let free = Int(parts[6]),
                  let percent = Double(parts[7].replacingOccurrences(of: "%", with: "")) else { continue }
            return DgInodeProfile(usedPercent: percent, used: used, free: free)
        }
        return nil
    }

    /// 权限组。id -Gn 的输出是一行空格分隔的组名。
    static func parseGroups(_ text: String) -> [String] {
        text.split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 一直会出现在「sleep prevented by」里的系统组件。
    ///
    /// 它们是系统的正常行为（音频守护进程、电源守护进程本来就常驻），
    /// 只有第三方程序才值得提醒用户。
    static let systemSleepBlockers: Set<String> = [
        "powerd", "coreaudiod", "coreaudiodd", "kernel_task",
        "UserEventAgent", "WindowServer", "loginwindow", "bluetoothd"
    ]

    // MARK: 小工具

    private static func firstNumber(in text: String) -> Int? {
        number(in: text, pattern: "(\\d+)")
    }

    private static func number(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        let ns = text as NSString
        return Int(ns.substring(with: match.range(at: 1)))
    }

    // MARK: 分组

    /// 把扩展事实变成报告分组。
    static func sections(from facts: DgExtraFacts) -> [DiagnosticSection] {
        [hardwareSection(facts),
         energySection(facts),
         systemSection(facts),
         hardeningSection(facts)]
        .filter { !$0.items.isEmpty }
    }

    private static func hardwareSection(_ f: DgExtraFacts) -> DiagnosticSection {
        var items: [DiagnosticItem] = []

        // 固件版本
        if let hardware = f.hardware.value, let firmware = hardware.firmwareVersion {
            items.append(DiagnosticItem(
                id: "dg.firmware",
                title: "系统固件版本",
                value: firmware,
                severity: .info,
                detail: "System Firmware Version（Apple Silicon 机型由它决定可安装的系统版本）"))
        } else {
            items.append(unavailableItem("dg.firmware", "系统固件版本",
                                         f.hardware.reason ?? "system_profiler 没有返回固件版本"))
        }

        // CPU 核心构成
        if let cores = f.hardware.value?.cores {
            items.append(DiagnosticItem(
                id: "dg.cpu_cores",
                title: "CPU 核心构成",
                value: cores.summary,
                severity: .info,
                detail: cores.performance != nil
                    ? "性能核负责重活，能效核负责后台，省电模式主要靠能效核。"
                    : nil))
        } else {
            items.append(unavailableItem("dg.cpu_cores", "CPU 核心构成",
                                         f.hardware.reason ?? "没有读到核心构成"))
        }

        // 内存与插槽
        if let hardware = f.hardware.value, let memory = hardware.memoryText {
            var value = memory
            if let slots = hardware.memorySlots {
                value += " · \(slots) 个插槽"
            } else {
                value += " · 统一内存（无独立插槽）"
            }
            items.append(DiagnosticItem(
                id: "dg.memory",
                title: "内存构成",
                value: value,
                severity: .info))
        } else {
            items.append(unavailableItem("dg.memory", "内存构成",
                                         f.hardware.reason ?? "没有读到内存信息"))
        }

        // GPU
        switch f.graphics {
        case .unavailable(let reason):
            items.append(unavailableItem("dg.gpu", "显卡", reason))
        case .value(let graphics):
            var parts: [String] = []
            if let chipset = graphics.chipsetModel { parts.append(chipset) }
            if let cores = graphics.coreCount { parts.append("\(cores) 核 GPU") }
            if let vram = graphics.videoMemory { parts.append("显存 \(vram)") }
            items.append(DiagnosticItem(
                id: "dg.gpu",
                title: "显卡",
                value: parts.isEmpty ? "读到了显卡信息，但没有可用数值" : parts.joined(separator: " · "),
                severity: .info))
        }

        // 存储 SMART
        switch f.storage {
        case .unavailable(let reason):
            items.append(unavailableItem("dg.smart", "磁盘 SMART 状态", reason))
        case .value(let drives):
            if drives.isEmpty {
                items.append(unavailableItem("dg.smart", "磁盘 SMART 状态", "没有读到物理磁盘信息"))
            } else {
                let failed = drives.filter(\.smartFailed)
                let detail = drives.map { drive -> String in
                    let name = drive.deviceName ?? "未命名磁盘"
                    let medium = drive.mediumType.map { "（\($0)）" } ?? ""
                    return "\(name)\(medium)：\(drive.smartStatus ?? "没有 SMART 状态")"
                }.joined(separator: "\n")
                if failed.isEmpty {
                    let verified = drives.filter(\.smartVerified).count
                    items.append(DiagnosticItem(
                        id: "dg.smart",
                        title: "磁盘 SMART 状态",
                        value: "\(drives.count) 块盘 · 已验证 \(verified) 块",
                        severity: .info,
                        detail: detail))
                } else {
                    items.append(DiagnosticItem(
                        id: "dg.smart",
                        title: "磁盘 SMART 状态",
                        value: "\(failed.count) 块盘未通过自检",
                        severity: .warning,
                        suggestion: "SMART 自检没通过通常意味着这块盘快要坏了。立刻备份重要数据，并到「磁盘工具」里跑一次「急救」；仍不通过就要换盘了。",
                        detail: detail))
                }
            }
        }

        // SMC 温度传感器
        switch f.smcPresent {
        case .unavailable(let reason):
            items.append(unavailableItem("dg.smc", "SMC 温度传感器", reason))
        case .value(let present):
            items.append(DiagnosticItem(
                id: "dg.smc",
                title: "SMC 温度传感器",
                value: present ? "已检测到 SMC 控制器" : "本机没有 SMC 控制器",
                severity: .info,
                detail: present
                    ? "SMC 的温度读数要靠特权助手拿（见「硬件」组里的「最高传感器温度」）。"
                    : "Apple Silicon 机型没有 SMC 温度传感器，温度读数来自系统自带的热压传感器。"))
        }

        return DiagnosticSection(id: "hardware-extra", title: "硬件与固件", icon: "memorychip", items: items)
    }

    private static func energySection(_ f: DgExtraFacts) -> DiagnosticSection {
        var items: [DiagnosticItem] = []

        // 电源来源与电量
        switch f.power {
        case .unavailable(let reason):
            items.append(unavailableItem("dg.power_source", "电源来源与电量", reason))
        case .value(let power):
            var parts: [String] = []
            if let source = power.source { parts.append(source) }
            if let percent = power.percent { parts.append("电量 \(percent)%") }
            items.append(DiagnosticItem(
                id: "dg.power_source",
                title: "电源来源与电量",
                value: parts.isEmpty ? "读到了电源状态，但没有可用数值" : parts.joined(separator: " · "),
                severity: .info))
        }

        // 阻止睡眠的进程
        switch f.sleepBlockers {
        case .unavailable(let reason):
            items.append(unavailableItem("dg.sleep_blockers", "阻止自动睡眠的进程", reason))
        case .value(let blockers):
            if blockers.isEmpty {
                items.append(DiagnosticItem(
                    id: "dg.sleep_blockers",
                    title: "阻止自动睡眠的进程",
                    value: "没有程序阻止自动睡眠",
                    severity: .info))
            } else {
                // 系统自带组件（powerd、coreaudiod 之类）常驻在这儿，属于常态；
                // 只有第三方程序才值得提醒。
                let thirdParty = blockers.filter { !systemSleepBlockers.contains($0) }
                let detail = blockers.joined(separator: "、")
                let severity: DiagnosticSeverity = thirdParty.isEmpty ? .info : .warning
                var suggestion: String?
                if !thirdParty.isEmpty {
                    suggestion = "这些第三方程序正在阻止系统自动睡眠，笔记本会一直醒着，电量掉得很快：\(thirdParty.joined(separator: "、"))。确认它们是不是需要一直挂着；不需要的话退出对应的应用即可。"
                }
                items.append(DiagnosticItem(
                    id: "dg.sleep_blockers",
                    title: "阻止自动睡眠的进程",
                    value: thirdParty.isEmpty
                        ? "\(blockers.count) 个系统组件（属正常）"
                        : "\(thirdParty.count) 个第三方程序正在阻止睡眠",
                    severity: severity,
                    suggestion: suggestion,
                    detail: detail))
            }
        }

        // 定时唤醒计划
        switch f.scheduledWake {
        case .unavailable(let reason):
            items.append(unavailableItem("dg.scheduled_wake", "定时唤醒计划", reason))
        case .value(let plan):
            items.append(DiagnosticItem(
                id: "dg.scheduled_wake",
                title: "定时唤醒计划",
                value: plan.isEmpty ? "没有定时唤醒计划" : "\(plan.count) 条计划",
                severity: .info,
                detail: plan.isEmpty ? nil : plan.joined(separator: "\n")))
        }

        // CPU 占用 Top 5
        switch f.topCPU {
        case .unavailable(let reason):
            items.append(unavailableItem("dg.top_cpu", "CPU 占用 Top 5", reason))
        case .value(let processes):
            if processes.isEmpty {
                items.append(unavailableItem("dg.top_cpu", "CPU 占用 Top 5", "没有读到进程列表"))
            } else {
                let detail = processes.enumerated().map { index, process in
                    "\(index + 1). \(process.name) · \(String(format: "%.1f", process.cpuPercent))%（PID \(process.pid)）"
                }.joined(separator: "\n")
                let top = processes[0]
                let severity: DiagnosticSeverity = top.cpuPercent >= 100 ? .warning : .info
                var suggestion: String?
                if top.cpuPercent >= 100 {
                    suggestion = "\(top.name) 正占满至少一个核心。确认它是不是该一直跑；不需要的话退出它，机器才能回到低功耗状态。"
                }
                items.append(DiagnosticItem(
                    id: "dg.top_cpu",
                    title: "CPU 占用 Top 5",
                    value: "\(processes.count) 个进程",
                    severity: severity,
                    suggestion: suggestion,
                    detail: detail))
            }
        }

        return DiagnosticSection(id: "energy", title: "能耗与电源", icon: "bolt.horizontal", items: items)
    }

    private static func systemSection(_ f: DgExtraFacts) -> DiagnosticSection {
        var items: [DiagnosticItem] = []

        // 时区
        if let timezone = f.timezone.value {
            items.append(DiagnosticItem(
                id: "dg.timezone",
                title: "时区",
                value: timezone,
                severity: .info))
        } else {
            items.append(unavailableItem("dg.timezone", "时区", f.timezone.reason ?? "未采集"))
        }

        // 网络时间同步
        if let sync = f.timeSync.value {
            items.append(DiagnosticItem(
                id: "dg.time_sync",
                title: "网络时间同步",
                value: sync,
                severity: .info))
        } else {
            items.append(unavailableItem("dg.time_sync", "网络时间同步", f.timeSync.reason ?? "未采集"))
        }

        // 启动模式
        if let software = f.software.value, let mode = software.bootMode {
            let safeMode = software.isSafeMode
            var detail = "Boot Mode: \(mode)"
            if let volume = software.bootVolume {
                detail += " · 启动卷：\(volume)"
            }
            items.append(DiagnosticItem(
                id: "dg.boot_mode",
                title: "启动模式",
                value: safeMode ? "安全启动（Safe Mode）" : "正常启动",
                severity: safeMode ? .warning : .info,
                suggestion: safeMode
                    ? "现在是安全启动模式：第三方扩展与字体都被停用了，很多问题会「一重启就好」。查清是软件冲突还是磁盘问题后，正常重启一次。"
                    : nil,
                detail: detail))
        } else {
            items.append(unavailableItem("dg.boot_mode", "启动模式",
                                         f.software.reason ?? "没有读到启动模式"))
        }

        // 当前用户与权限组
        switch f.groups {
        case .unavailable(let reason):
            items.append(unavailableItem("dg.user_groups", "当前用户与权限组", reason))
        case .value(let groups):
            let isAdmin = groups.contains("admin")
            items.append(DiagnosticItem(
                id: "dg.user_groups",
                title: "当前用户与权限组",
                value: "\(groups.count) 个组\(isAdmin ? " · 含 admin" : "")",
                severity: .info,
                detail: groups.joined(separator: "、")))
        }

        // inode
        switch f.inode {
        case .unavailable(let reason):
            items.append(unavailableItem("dg.inode", "磁盘 inode 使用", reason))
        case .value(let inode):
            items.append(DiagnosticItem(
                id: "dg.inode",
                title: "磁盘 inode 使用",
                value: String(format: "%.0f%%", inode.usedPercent),
                severity: .info,
                detail: "已用 \(inode.used) / 共 \(inode.used + inode.free) 个文件节点"))
        }

        // 崩溃报告
        switch f.crash {
        case .unavailable(let reason):
            items.append(unavailableItem("dg.crash_reports", "崩溃与内核转储报告", reason))
        case .value(let crash):
            var value = "用户 \(crash.userReportCount) 份 · 系统 \(crash.systemReportCount) 份"
            if crash.panicCount > 0 {
                value += " · 内核崩溃 \(crash.panicCount) 份"
            }
            var suggestion: String?
            if crash.panicCount > 0 {
                suggestion = "检测到 \(crash.panicCount) 份内核崩溃报告，说明系统崩过。打开这些报告看崩溃时的调用栈，能定位到是哪个驱动或扩展引起的。"
            }
            var detail: String?
            if let name = crash.newestReportName {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                let time = crash.newestReportDate.map { "（\(formatter.string(from: $0))）" } ?? ""
                detail = "最近一份：\(name)\(time)"
            }
            items.append(DiagnosticItem(
                id: "dg.crash_reports",
                title: "崩溃与内核转储报告",
                value: value,
                severity: crash.panicCount > 0 ? .warning : .info,
                suggestion: suggestion,
                detail: detail))
        }

        return DiagnosticSection(id: "system-extra", title: "系统状态与日志", icon: "doc.text", items: items)
    }

    private static func hardeningSection(_ f: DgExtraFacts) -> DiagnosticSection {
        var items: [DiagnosticItem] = []

        // 第三方系统扩展
        switch f.systemExtensions {
        case .unavailable(let reason):
            items.append(unavailableItem("dg.system_extensions", "第三方系统扩展", reason))
        case .value(let extensions):
            if extensions.isEmpty {
                items.append(DiagnosticItem(
                    id: "dg.system_extensions",
                    title: "第三方系统扩展",
                    value: "没有第三方系统扩展",
                    severity: .info))
            } else {
                let enabled = extensions.filter(\.enabled)
                let detail = extensions.map { item -> String in
                    let mark = item.enabled ? "已启用" : "未启用"
                    return "\(item.name)（\(item.bundleID)）· \(mark) · \(item.state)"
                }.joined(separator: "\n")
                items.append(DiagnosticItem(
                    id: "dg.system_extensions",
                    title: "第三方系统扩展",
                    value: "\(extensions.count) 个 · 已启用 \(enabled.count) 个",
                    severity: .info,
                    detail: detail))
            }
        }

        // 安全虚拟内存
        if let software = f.software.value, let secure = software.secureVirtualMemory {
            let enabled = secure.lowercased().contains("enabled")
            items.append(DiagnosticItem(
                id: "dg.secure_memory",
                title: "安全虚拟内存",
                value: enabled ? "已启用" : "已关闭",
                severity: enabled ? .info : .warning,
                suggestion: enabled
                    ? nil
                    : "安全虚拟内存（交换空间加密）没开，睡眠时内存里的内容会以明文落在硬盘上。打开「系统设置 → 隐私与安全性 → 文件保险箱」旁边的安全虚拟内存开关。"))
        } else {
            items.append(unavailableItem("dg.secure_memory", "安全虚拟内存",
                                         f.software.reason ?? "没有读到安全虚拟内存状态"))
        }

        // 激活锁
        if let hardware = f.hardware.value, let lock = hardware.activationLock {
            let enabled = lock.lowercased().contains("enabled")
            items.append(DiagnosticItem(
                id: "dg.activation_lock",
                title: "激活锁",
                value: enabled ? "已启用" : "已关闭",
                severity: enabled ? .info : .warning,
                suggestion: enabled
                    ? nil
                    : "这台机器没绑定 Apple ID。机器转手时对方可以用自己的账号激活锁住它，你的账号反而登不进去。"))
        } else {
            items.append(unavailableItem("dg.activation_lock", "激活锁",
                                         f.hardware.reason ?? "没有读到激活锁状态"))
        }

        // hosts
        switch f.hostsEntries {
        case .unavailable(let reason):
            items.append(unavailableItem("dg.hosts", "hosts 生效条目", reason))
        case .value(let entries):
            items.append(DiagnosticItem(
                id: "dg.hosts",
                title: "hosts 生效条目",
                value: "\(entries.count) 条",
                severity: .info,
                detail: entries.prefix(10).joined(separator: "\n")
                    + (entries.count > 10 ? "\n（另有 \(entries.count - 10) 条）" : "")))
        }

        // 第三方开机项
        switch f.thirdPartyLaunchItems {
        case .unavailable(let reason):
            items.append(unavailableItem("dg.launch_items", "第三方开机项", reason))
        case .value(let items2):
            items.append(DiagnosticItem(
                id: "dg.launch_items",
                title: "第三方开机项",
                value: "\(items2.count) 个",
                severity: .info,
                detail: items2.isEmpty ? "没有第三方开机项" : items2.joined(separator: "\n")))
        }

        return DiagnosticSection(id: "hardening", title: "扩展与加固", icon: "puzzlepiece.extension", items: items)
    }

    /// 造一条「读不到」的项。跟判定层一个写法：值里带上原因。
    private static func unavailableItem(_ id: String, _ title: String, _ reason: String) -> DiagnosticItem {
        DiagnosticItem(id: id,
                       title: title,
                       value: "无法读取（\(reason)）",
                       severity: .info)
    }
}
