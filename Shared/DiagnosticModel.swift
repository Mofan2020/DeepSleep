//
//  DiagnosticModel.swift
//  Deep Sleep
//
//  设备诊断的「判定层」：纯逻辑，只依赖 Foundation。
//
//  为什么单独抽一个文件、而且不许 import 任何 UI 框架：
//    1. 诊断规则（阈值、严重度、建议文案）必须**可单测** ——
//       scripts/test-diagnostic-rules.swift 直接编译这一个文件跑规则，
//       不用启动 App、不用连特权助手、不用碰真机状态。
//    2. Shared/ 同时编译进主 App 与特权助手两个 target，
//       这里出现 AppKit / SwiftUI 会把助手 target 编译搞挂。
//    3. 采集层（跑命令、读系统状态）在 DeepSleep/Core/DeviceDiagnostics.swift，
//       那边只负责「把事实取回来」，**不判定好坏** —— 判定全在这层。
//

import Foundation

// MARK: - 严重度

/// 一条检查项的严重度。
///
/// rawValue 顺序即排序顺序：info < warning < critical。
/// 界面把问题项排前面、正常项排后面，直接按这个序排。
public enum DiagnosticSeverity: Int, Comparable, CaseIterable, Codable {
    case info = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 报告与界面里用的中文标签。
    public var label: String {
        switch self {
        case .info:     return "正常"
        case .warning:  return "注意"
        case .critical: return "严重"
        }
    }

    /// SF Symbol 名（界面用；模型层不 import SwiftUI，只放名字）。
    public var symbolName: String {
        switch self {
        case .info:     return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
}

// MARK: - 事实

/// 一个「取回来的事实」：要么有值，要么明确说明为什么读不到。
///
/// 为什么要专门一个类型而不是用 Optional：
/// 读不到的原因是**报告的一部分**（权限不足 / 工具不存在 / 超时），
/// 用 Optional 表达就只剩 nil，界面上只能显示「—」，用户不知道是系统没这项
/// 还是本工具读失败。两边必须分清。
public enum DiagnosticFact<Value> {
    case value(Value)
    case unavailable(reason: String)

    public var value: Value? {
        switch self {
        case .value(let v): return v
        case .unavailable:  return nil
        }
    }

    /// 读不到的原因。读得到时为 nil。
    public var reason: String? {
        switch self {
        case .value:            return nil
        case .unavailable(let r): return r
        }
    }

    public var isAvailable: Bool {
        if case .value = self { return true }
        return false
    }
}

extension DiagnosticFact: Equatable where Value: Equatable {}

/// 一个已挂载卷的容量事实。
public struct DiagnosticVolumeFact: Equatable {
    /// 给人看的名字（系统卷 / 数据卷 / 卷名）。
    public let name: String
    /// 挂载点。
    public let mountPoint: String
    public let totalBytes: UInt64
    public let freeBytes: UInt64

    public init(name: String, mountPoint: String, totalBytes: UInt64, freeBytes: UInt64) {
        self.name = name
        self.mountPoint = mountPoint
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }

    /// 剩余空间百分比。总量读不到时返回 nil。
    public var freePercent: Double? {
        guard totalBytes > 0 else { return nil }
        return Double(freeBytes) / Double(totalBytes) * 100
    }
}

/// 电池健康事实。桌面机没有电池时整块为 unavailable。
public struct DiagnosticBatteryFact: Equatable {
    /// 循环次数。
    public let cycleCount: Int?
    /// 当前电量百分比。
    public let currentCapacityPercent: Double?
    /// 最大容量百分比（AppleSmartBattery 的 MaxCapacity，设计容量的百分比）。
    public let maxCapacityPercent: Double?
    /// 满充容量（mAh）。
    public let fullChargeCapacity: Int?
    /// 设计容量（mAh）。
    public let designCapacity: Int?
    /// 电池温度（°C）。
    public let temperatureCelsius: Double?

    public init(cycleCount: Int?,
                currentCapacityPercent: Double?,
                maxCapacityPercent: Double? = nil,
                fullChargeCapacity: Int?,
                designCapacity: Int?,
                temperatureCelsius: Double?) {
        self.cycleCount = cycleCount
        self.currentCapacityPercent = currentCapacityPercent
        self.maxCapacityPercent = maxCapacityPercent
        self.fullChargeCapacity = fullChargeCapacity
        self.designCapacity = designCapacity
        self.temperatureCelsius = temperatureCelsius
    }

    /// 健康度 = 满充容量 / 设计容量。缺任一项时为 nil。
    public var healthPercent: Double? {
        guard let full = fullChargeCapacity, let design = designCapacity, design > 0 else { return nil }
        return Double(full) / Double(design) * 100
    }
}

/// 一条进程的内存占用事实。
public struct DiagnosticProcessFact: Equatable {
    public let pid: Int
    public let name: String
    public let rssBytes: UInt64

    public init(pid: Int, name: String, rssBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.rssBytes = rssBytes
    }
}

// MARK: - 事实集合

/// 一次诊断采集到的全部事实。
///
/// 每个字段默认「未采集」。判定层拿到这份结构就够出报告，
/// 不需要知道任何命令、系统 API 或特权助手。
public struct DiagnosticFacts {

    // 硬件
    public var modelName: DiagnosticFact<String>
    public var chipName: DiagnosticFact<String>
    public var cpuCores: DiagnosticFact<Int>
    public var memoryBytes: DiagnosticFact<UInt64>
    public var hottestTemperatureCelsius: DiagnosticFact<Double>
    public var memoryUsedPercent: DiagnosticFact<Double>
    /// memory_pressure 工具报告的「系统可用内存百分比」，与上面互为交叉验证。
    public var memoryPressureFreePercent: DiagnosticFact<Double>
    public var swapUsedPercent: DiagnosticFact<Double>

    // 存储与电池
    public var volumes: DiagnosticFact<[DiagnosticVolumeFact]>
    public var battery: DiagnosticFact<DiagnosticBatteryFact>

    // 软件
    public var osVersion: DiagnosticFact<String>
    public var osBuild: DiagnosticFact<String>
    public var kernelVersion: DiagnosticFact<String>
    public var uptimeSeconds: DiagnosticFact<Double>
    public var consoleUser: DiagnosticFact<String>
    public var currentUser: DiagnosticFact<String>
    public var hostName: DiagnosticFact<String>

    // 配置与安全
    public var sipEnabled: DiagnosticFact<Bool>
    public var gatekeeperEnabled: DiagnosticFact<Bool>
    public var fileVaultEnabled: DiagnosticFact<Bool>
    public var firewallEnabled: DiagnosticFact<Bool>
    public var proxyEnabled: DiagnosticFact<Bool>
    public var proxyDetail: DiagnosticFact<String>
    public var powerAssertions: DiagnosticFact<[String]>
    public var energySettings: DiagnosticFact<String>
    public var launchAgentsCount: DiagnosticFact<Int>
    public var launchDaemonsCount: DiagnosticFact<Int>
    public var quarantinedFileCount: DiagnosticFact<Int>

    // 进程与负载
    public var loadAverage: DiagnosticFact<[Double]>
    public var topMemoryProcesses: DiagnosticFact<[DiagnosticProcessFact]>

    public init(modelName: DiagnosticFact<String> = .unavailable(reason: "未采集"),
                chipName: DiagnosticFact<String> = .unavailable(reason: "未采集"),
                cpuCores: DiagnosticFact<Int> = .unavailable(reason: "未采集"),
                memoryBytes: DiagnosticFact<UInt64> = .unavailable(reason: "未采集"),
                hottestTemperatureCelsius: DiagnosticFact<Double> = .unavailable(reason: "未采集"),
                memoryUsedPercent: DiagnosticFact<Double> = .unavailable(reason: "未采集"),
                memoryPressureFreePercent: DiagnosticFact<Double> = .unavailable(reason: "未采集"),
                swapUsedPercent: DiagnosticFact<Double> = .unavailable(reason: "未采集"),
                volumes: DiagnosticFact<[DiagnosticVolumeFact]> = .unavailable(reason: "未采集"),
                battery: DiagnosticFact<DiagnosticBatteryFact> = .unavailable(reason: "未采集"),
                osVersion: DiagnosticFact<String> = .unavailable(reason: "未采集"),
                osBuild: DiagnosticFact<String> = .unavailable(reason: "未采集"),
                kernelVersion: DiagnosticFact<String> = .unavailable(reason: "未采集"),
                uptimeSeconds: DiagnosticFact<Double> = .unavailable(reason: "未采集"),
                consoleUser: DiagnosticFact<String> = .unavailable(reason: "未采集"),
                currentUser: DiagnosticFact<String> = .unavailable(reason: "未采集"),
                hostName: DiagnosticFact<String> = .unavailable(reason: "未采集"),
                sipEnabled: DiagnosticFact<Bool> = .unavailable(reason: "未采集"),
                gatekeeperEnabled: DiagnosticFact<Bool> = .unavailable(reason: "未采集"),
                fileVaultEnabled: DiagnosticFact<Bool> = .unavailable(reason: "未采集"),
                firewallEnabled: DiagnosticFact<Bool> = .unavailable(reason: "未采集"),
                proxyEnabled: DiagnosticFact<Bool> = .unavailable(reason: "未采集"),
                proxyDetail: DiagnosticFact<String> = .unavailable(reason: "未采集"),
                powerAssertions: DiagnosticFact<[String]> = .unavailable(reason: "未采集"),
                energySettings: DiagnosticFact<String> = .unavailable(reason: "未采集"),
                launchAgentsCount: DiagnosticFact<Int> = .unavailable(reason: "未采集"),
                launchDaemonsCount: DiagnosticFact<Int> = .unavailable(reason: "未采集"),
                quarantinedFileCount: DiagnosticFact<Int> = .unavailable(reason: "未采集"),
                loadAverage: DiagnosticFact<[Double]> = .unavailable(reason: "未采集"),
                topMemoryProcesses: DiagnosticFact<[DiagnosticProcessFact]> = .unavailable(reason: "未采集")) {
        self.modelName = modelName
        self.chipName = chipName
        self.cpuCores = cpuCores
        self.memoryBytes = memoryBytes
        self.hottestTemperatureCelsius = hottestTemperatureCelsius
        self.memoryUsedPercent = memoryUsedPercent
        self.memoryPressureFreePercent = memoryPressureFreePercent
        self.swapUsedPercent = swapUsedPercent
        self.volumes = volumes
        self.battery = battery
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.kernelVersion = kernelVersion
        self.uptimeSeconds = uptimeSeconds
        self.consoleUser = consoleUser
        self.currentUser = currentUser
        self.hostName = hostName
        self.sipEnabled = sipEnabled
        self.gatekeeperEnabled = gatekeeperEnabled
        self.fileVaultEnabled = fileVaultEnabled
        self.firewallEnabled = firewallEnabled
        self.proxyEnabled = proxyEnabled
        self.proxyDetail = proxyDetail
        self.powerAssertions = powerAssertions
        self.energySettings = energySettings
        self.launchAgentsCount = launchAgentsCount
        self.launchDaemonsCount = launchDaemonsCount
        self.quarantinedFileCount = quarantinedFileCount
        self.loadAverage = loadAverage
        self.topMemoryProcesses = topMemoryProcesses
    }
}

// MARK: - 阈值

/// 判定用的阈值常量。
///
/// 集中放一处：改阈值只改这里，测试也直接引用同一份常量，不会出现
/// 「代码里 80%、测试里 75%」这种漂移。
public enum DiagnosticThresholds {
    /// 卷剩余空间低于此百分比 → 需要注意。
    public static let diskFreeWarningPercent = 10.0
    /// 卷剩余空间低于此百分比 → 严重（再写一点就会开始丢缓存、写失败）。
    public static let diskFreeCriticalPercent = 3.0

    /// 交换空间使用率超过此百分比 → 需要注意。
    public static let swapUsageWarningPercent = 50.0
    /// 交换空间使用率超过此百分比 → 严重。
    public static let swapUsageCriticalPercent = 90.0

    /// 内存使用率超过此百分比 → 需要注意。
    public static let memoryUsageWarningPercent = 70.0
    /// 内存使用率超过此百分比 → 严重。
    public static let memoryUsageCriticalPercent = 90.0

    /// 最高温度达到此值 → 需要注意。
    public static let temperatureWarningCelsius = 80.0
    /// 最高温度达到此值 → 严重（与风扇兜底线同值，见 FanControl.emergencyTemperatureCelsius）。
    public static let emergencyTemperatureCelsius = 90.0

    /// 单核平均负载超过 1.0 即视为过载。
    public static let loadPerCoreWarning = 1.0

    /// 电池循环次数达到此值 → 需要注意。
    public static let batteryCycleWarning = 500
    /// 电池健康度低于此百分比 → 需要注意。
    public static let batteryHealthWarningPercent = 80.0

    /// 连续开机超过这么多天 → 需要注意（长期不重启容易积累驱动/索引问题）。
    public static let longUptimeWarningDays = 30
}

// MARK: - 报告结构

/// 一条检查结果。
public struct DiagnosticItem: Identifiable, Codable, Equatable {
    public let id: String
    public let title: String
    /// 当前值 / 现象。读不到时写成「无法读取（原因）」。
    public let value: String
    public let severity: DiagnosticSeverity
    /// 怎么办。问题项必须有；正常项可以为 nil。
    public let suggestion: String?
    /// 补充说明（原始输出片段、额外上下文）。
    public let detail: String?

    public init(id: String,
                title: String,
                value: String,
                severity: DiagnosticSeverity,
                suggestion: String? = nil,
                detail: String? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.severity = severity
        self.suggestion = suggestion
        self.detail = detail
    }

    /// 解码容错：缺字段时给默认值，不让一份旧的/残缺的存档整个读不出来。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        value = (try? c.decode(String.self, forKey: .value)) ?? ""
        severity = (try? c.decode(DiagnosticSeverity.self, forKey: .severity)) ?? .info
        suggestion = try? c.decodeIfPresent(String.self, forKey: .suggestion)
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
    }
}

/// 一个分组（如「硬件」「安全」）。
public struct DiagnosticSection: Identifiable, Codable, Equatable {
    public let id: String
    public let title: String
    /// SF Symbol 名。
    public let icon: String
    public var items: [DiagnosticItem]

    public init(id: String, title: String, icon: String, items: [DiagnosticItem]) {
        self.id = id
        self.title = title
        self.icon = icon
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        icon = (try? c.decode(String.self, forKey: .icon)) ?? "info.circle"
        items = (try? c.decode([DiagnosticItem].self, forKey: .items)) ?? []
    }

    /// 问题项（warning / critical），严重度高的在前。
    public var problems: [DiagnosticItem] {
        items.filter { $0.severity != .info }
            .sorted { $0.severity > $1.severity }
    }

    /// 正常项。
    public var normalItems: [DiagnosticItem] {
        items.filter { $0.severity == .info }
    }

    /// 界面展示顺序：问题项在前，正常项在后。
    public var displayItems: [DiagnosticItem] {
        problems + normalItems
    }
}

/// 一次诊断的完整报告。
public struct DiagnosticReport: Codable, Equatable {

    public let generatedAt: Date
    public var sections: [DiagnosticSection]
    /// 一句人话总结，含问题计数。
    public var summary: String

    public init(generatedAt: Date = Date(), sections: [DiagnosticSection] = [], summary: String = "") {
        self.generatedAt = generatedAt
        self.sections = sections
        self.summary = summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = (try? c.decode(Date.self, forKey: .generatedAt)) ?? Date(timeIntervalSince1970: 0)
        sections = (try? c.decode([DiagnosticSection].self, forKey: .sections)) ?? []
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
    }

    public var allItems: [DiagnosticItem] {
        sections.flatMap(\.items)
    }

    /// 需要处理的问题数（warning + critical）。
    public var problemCount: Int {
        allItems.filter { $0.severity != .info }.count
    }

    public var criticalCount: Int {
        allItems.filter { $0.severity == .critical }.count
    }

    public var warningCount: Int {
        allItems.filter { $0.severity == .warning }.count
    }

    /// 整体健康结论的措辞（界面顶部那一行）。
    public var headline: String {
        if problemCount == 0 {
            return "未发现需要注意的问题"
        }
        var parts: [String] = []
        if criticalCount > 0 { parts.append("\(criticalCount) 项严重") }
        if warningCount > 0 { parts.append("\(warningCount) 项需要注意") }
        return "发现 \(problemCount) 个需要注意的问题（\(parts.joined(separator: "、"))）"
    }

    /// 报告全文（纯文本）。界面「复制报告全文」直接用它。
    public var plainText: String {
        var lines: [String] = []
        lines.append("Deep Sleep 设备诊断报告")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        lines.append("生成时间：\(f.string(from: generatedAt))")
        lines.append("结论：\(summary)")
        lines.append("")
        for section in sections {
            lines.append("【\(section.title)】")
            for item in section.displayItems {
                lines.append("· \(item.severity.label)｜\(item.title)：\(item.value)")
                if let suggestion = item.suggestion, !suggestion.isEmpty {
                    lines.append("    处理建议：\(suggestion)")
                }
                if let detail = item.detail, !detail.isEmpty {
                    lines.append("    详情：\(detail)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// 生成总结句。
    public static func summaryText(for sections: [DiagnosticSection]) -> String {
        let items = sections.flatMap(\.items)
        let problems = items.filter { $0.severity != .info }
        let critical = problems.filter { $0.severity == .critical }.count
        let warning = problems.filter { $0.severity == .warning }.count
        if problems.isEmpty {
            return "共检查 \(items.count) 项，全部正常，没有发现需要处理的问题。"
        }
        var parts: [String] = []
        if critical > 0 { parts.append("\(critical) 项严重") }
        if warning > 0 { parts.append("\(warning) 项需要注意") }
        return "共检查 \(items.count) 项，发现 \(problems.count) 个需要处理的问题（\(parts.joined(separator: "、"))），"
            + "其余 \(items.count - problems.count) 项正常。"
    }
}

// MARK: - 存档

/// 报告的存档编解码。
///
/// 单独一个类型而不是直接用 JSONEncoder：报告要落盘（记住上次检测结果），
/// 而落盘的东西一定会遇到「版本升级后字段没了」「文件写坏了」两种情况。
/// 解码失败一律返回 nil，由调用方决定回落成什么 —— 绝不返回半份报告。
public enum DiagnosticReportArchive {

    public static func encode(_ report: DiagnosticReport) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(report)
    }

    /// 解码。数据损坏或格式不对时返回 nil。
    public static func decode(_ data: Data) -> DiagnosticReport? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DiagnosticReport.self, from: data)
    }
}

// MARK: - 判定

/// 判定层：事实 → 报告。
///
/// 规则全部写在这一个纯函数里，采集层不掺和判定。
/// 这样「给定一组坏事实 → 应产出哪些问题项」可以直接写成断言。
public enum DiagnosticEvaluator {

    /// 产出报告。
    public static func evaluate(_ facts: DiagnosticFacts, generatedAt: Date = Date()) -> DiagnosticReport {
        let sections = [
            hardwareSection(facts),
            storageSection(facts),
            softwareSection(facts),
            securitySection(facts),
            processSection(facts)
        ].filter { !$0.items.isEmpty }

        return DiagnosticReport(
            generatedAt: generatedAt,
            sections: sections,
            summary: DiagnosticReport.summaryText(for: sections)
        )
    }

    // MARK: 硬件

    private static func hardwareSection(_ f: DiagnosticFacts) -> DiagnosticSection {
        var items: [DiagnosticItem] = []

        // 机型 + 芯片 + 核心数：合在一项里看，缺哪个补哪个。
        var identityParts: [String] = []
        var identityMissing: [String] = []
        if let model = f.modelName.value { identityParts.append(model) } else { identityMissing.append("机型") }
        if let chip = f.chipName.value { identityParts.append(chip) } else { identityMissing.append("芯片") }
        if let cores = f.cpuCores.value { identityParts.append("\(cores) 核 CPU") } else { identityMissing.append("核心数") }
        if identityParts.isEmpty {
            items.append(unavailable("hw.identity", "机型与芯片",
                                     missingReason([f.modelName.reason, f.chipName.reason, f.cpuCores.reason])))
        } else {
            items.append(DiagnosticItem(
                id: "hw.identity",
                title: "机型与芯片",
                value: identityParts.joined(separator: " · "),
                severity: .info,
                detail: identityMissing.isEmpty ? nil : "未读到：\(identityMissing.joined(separator: "、"))"))
        }

        // 内存容量
        if let bytes = f.memoryBytes.value {
            items.append(DiagnosticItem(
                id: "hw.memory",
                title: "内存容量",
                value: formatBytes(bytes),
                severity: .info))
        } else {
            items.append(unavailable("hw.memory", "内存容量", f.memoryBytes.reason ?? "未采集"))
        }

        // 最高温度
        if let celsius = f.hottestTemperatureCelsius.value {
            let severity: DiagnosticSeverity
            var suggestion: String?
            if celsius >= DiagnosticThresholds.emergencyTemperatureCelsius {
                severity = .critical
                suggestion = "温度已达到风扇兜底线（\(Int(DiagnosticThresholds.emergencyTemperatureCelsius))°C）。先停掉正在跑的高负载任务，检查出风口是否被堵、机器是否放在软面或密闭空间，必要时重启后再看温度曲线。"
            } else if celsius >= DiagnosticThresholds.temperatureWarningCelsius {
                severity = .warning
                suggestion = "温度偏高。把机器移到通风处、清理出风口积灰，关掉后台持续占 CPU 的任务；长期高温会加速降频与电池老化。"
            } else {
                severity = .info
            }
            items.append(DiagnosticItem(
                id: "hw.temperature",
                title: "最高传感器温度",
                value: String(format: "%.1f°C", celsius),
                severity: severity,
                suggestion: suggestion))
        } else {
            items.append(unavailable("hw.temperature", "最高传感器温度", f.hottestTemperatureCelsius.reason ?? "未采集"))
        }

        // 内存使用率
        if let used = f.memoryUsedPercent.value {
            let severity: DiagnosticSeverity
            var suggestion: String?
            if used >= DiagnosticThresholds.memoryUsageCriticalPercent {
                severity = .critical
                suggestion = "内存已经用满，系统会频繁压缩内存甚至开始大量使用交换空间，表现为卡顿。关掉占用最大的应用（见「进程与负载」），或直接重启。"
            } else if used >= DiagnosticThresholds.memoryUsageWarningPercent {
                severity = .warning
                suggestion = "内存占用偏高。检查「进程与负载」里内存占用前几名的应用是不是还需要常驻，关掉不用的可以立刻腾出内存。"
            } else {
                severity = .info
            }
            items.append(DiagnosticItem(
                id: "hw.memory_usage",
                title: "内存使用率",
                value: String(format: "%.0f%%", used),
                severity: severity,
                suggestion: suggestion,
                detail: f.memoryPressureFreePercent.value.map {
                    String(format: "memory_pressure 报告系统可用内存 %.0f%%", $0)
                }))
        } else {
            items.append(unavailable("hw.memory_usage", "内存使用率", f.memoryUsedPercent.reason ?? "未采集"))
        }

        // 交换空间
        if let used = f.swapUsedPercent.value {
            let severity: DiagnosticSeverity
            var suggestion: String?
            if used >= DiagnosticThresholds.swapUsageCriticalPercent {
                severity = .critical
                suggestion = "交换空间几乎被用光，内存已经不够用，程序随时可能被系统杀掉。重启一次能立刻释放交换空间；长期这样要查是哪个程序在吃内存。"
            } else if used >= DiagnosticThresholds.swapUsageWarningPercent {
                severity = .warning
                suggestion = "交换空间用得比较多，内存已经不够用。重启一次能清空交换空间；顺带查一下「进程与负载」里内存占用最高的进程。"
            } else {
                severity = .info
            }
            items.append(DiagnosticItem(
                id: "hw.swap",
                title: "交换空间使用率",
                value: String(format: "%.0f%%", used),
                severity: severity,
                suggestion: suggestion))
        } else {
            items.append(unavailable("hw.swap", "交换空间使用率", f.swapUsedPercent.reason ?? "未采集"))
        }

        return DiagnosticSection(id: "hardware", title: "硬件", icon: "cpu", items: items)
    }

    // MARK: 存储与电池

    private static func storageSection(_ f: DiagnosticFacts) -> DiagnosticSection {
        var items: [DiagnosticItem] = []

        switch f.volumes {
        case .unavailable(let reason):
            items.append(unavailable("storage.volumes", "磁盘容量", reason))
        case .value(let volumes):
            if volumes.isEmpty {
                items.append(unavailable("storage.volumes", "磁盘容量", "没有读到任何已挂载卷"))
            }
            for (index, volume) in volumes.enumerated() {
                guard let freePercent = volume.freePercent else {
                    items.append(unavailable("storage.volume.\(index)", "容量 · \(volume.name)", "读不到该卷的总容量"))
                    continue
                }
                let severity: DiagnosticSeverity
                var suggestion: String?
                if freePercent <= DiagnosticThresholds.diskFreeCriticalPercent {
                    severity = .critical
                    suggestion = "\(volume.name) 只剩 \(String(format: "%.1f", freePercent))% 空间，低于 \(Int(DiagnosticThresholds.diskFreeCriticalPercent))%。清理「下载」目录与废纸篓，删掉不用的安装包和旧备份；空间写满时系统会开始写失败。"
                } else if freePercent <= DiagnosticThresholds.diskFreeWarningPercent {
                    severity = .warning
                    suggestion = "\(volume.name) 剩余空间不足 \(Int(DiagnosticThresholds.diskFreeWarningPercent))%，清理下载目录与废纸篓后重启一次应用，释放的缓存会自己退回去。"
                } else {
                    severity = .info
                }
                items.append(DiagnosticItem(
                    id: "storage.volume.\(index)",
                    title: "容量 · \(volume.name)",
                    value: String(format: "剩余 %.1f%%（%@ 可用 / %@）",
                                  freePercent,
                                  formatBytes(volume.freeBytes),
                                  formatBytes(volume.totalBytes)),
                    severity: severity,
                    suggestion: suggestion,
                    detail: volume.mountPoint))
            }
        }

        switch f.battery {
        case .unavailable(let reason):
            items.append(unavailable("storage.battery", "电池健康", reason))
        case .value(let battery):
            var valueParts: [String] = []
            if let cycles = battery.cycleCount { valueParts.append("循环 \(cycles) 次") }
            if let current = battery.currentCapacityPercent { valueParts.append("电量 \(Int(current))%") }
            if let maxCapacity = battery.maxCapacityPercent {
                valueParts.append(String(format: "最大容量 %.0f%%", maxCapacity))
            }
            if let full = battery.fullChargeCapacity, let design = battery.designCapacity {
                valueParts.append("满充 \(full)/\(design) mAh")
            }
            if let health = battery.healthPercent {
                valueParts.append(String(format: "健康度 %.0f%%", health))
            }
            if let temp = battery.temperatureCelsius {
                valueParts.append(String(format: "温度 %.1f°C", temp))
            }
            let severity: DiagnosticSeverity
            var suggestion: String?
            if let health = battery.healthPercent, health < DiagnosticThresholds.batteryHealthWarningPercent {
                severity = .warning
                suggestion = "电池健康度只剩 \(String(format: "%.0f", health))%，续航会明显变短。打开「系统设置 → 电池 → 电池健康」看是否提示需要维修，需要时换电池。"
            } else if let cycles = battery.cycleCount, cycles >= DiagnosticThresholds.batteryCycleWarning {
                severity = .warning
                suggestion = "电池已经循环 \(cycles) 次，超过 \(DiagnosticThresholds.batteryCycleWarning) 次后容量会明显衰减。留意续航变化，必要时更换电池。"
            } else {
                severity = .info
            }
            items.append(DiagnosticItem(
                id: "storage.battery",
                title: "电池健康",
                value: valueParts.isEmpty ? "读到了电池，但没有可用数值" : valueParts.joined(separator: " · "),
                severity: severity,
                suggestion: suggestion))
        }

        return DiagnosticSection(id: "storage", title: "存储与电池", icon: "internaldrive", items: items)
    }

    // MARK: 软件

    private static func softwareSection(_ f: DiagnosticFacts) -> DiagnosticSection {
        var items: [DiagnosticItem] = []

        if let version = f.osVersion.value {
            let build = f.osBuild.value.map { "（Build \($0)）" } ?? ""
            items.append(DiagnosticItem(
                id: "sw.os",
                title: "macOS 版本",
                value: "\(version)\(build)",
                severity: .info))
        } else {
            items.append(unavailable("sw.os", "macOS 版本", f.osVersion.reason ?? "未采集"))
        }

        if let kernel = f.kernelVersion.value {
            items.append(DiagnosticItem(
                id: "sw.kernel",
                title: "内核版本",
                value: kernel,
                severity: .info))
        } else {
            items.append(unavailable("sw.kernel", "内核版本", f.kernelVersion.reason ?? "未采集"))
        }

        if let uptime = f.uptimeSeconds.value {
            let days = uptime / 86400
            let severity: DiagnosticSeverity
            var suggestion: String?
            if days >= Double(DiagnosticThresholds.longUptimeWarningDays) {
                severity = .warning
                suggestion = "机器已经连续运行 \(Int(days)) 天没重启。长期不重启容易攒下各种驱动与索引问题，安排一次重启能解决掉大部分「莫名其妙变慢」。"
            } else {
                severity = .info
            }
            items.append(DiagnosticItem(
                id: "sw.uptime",
                title: "连续运行时间",
                value: formatDuration(uptime),
                severity: severity,
                suggestion: suggestion))
        } else {
            items.append(unavailable("sw.uptime", "连续运行时间", f.uptimeSeconds.reason ?? "未采集"))
        }

        if let user = f.consoleUser.value {
            let current = f.currentUser.value
            let value = (current != nil && current != user) ? "\(user)（当前会话：\(current!)）" : user
            items.append(DiagnosticItem(
                id: "sw.user",
                title: "登录用户",
                value: value,
                severity: .info))
        } else {
            items.append(unavailable("sw.user", "登录用户", f.consoleUser.reason ?? "未采集"))
        }

        if let host = f.hostName.value {
            items.append(DiagnosticItem(
                id: "sw.host",
                title: "主机名",
                value: host,
                severity: .info))
        } else {
            items.append(unavailable("sw.host", "主机名", f.hostName.reason ?? "未采集"))
        }

        return DiagnosticSection(id: "software", title: "软件与系统", icon: "gearshape.2", items: items)
    }

    // MARK: 配置与安全

    private static func securitySection(_ f: DiagnosticFacts) -> DiagnosticSection {
        var items: [DiagnosticItem] = []

        items.append(toggleItem(
            id: "sec.sip",
            title: "系统完整性保护（SIP）",
            fact: f.sipEnabled,
            enabledText: "已开启",
            disabledText: "已关闭",
            severityWhenDisabled: .critical,
            suggestionWhenDisabled: "SIP 关闭后任何程序都能改系统文件，系统不再保护关键目录。恢复方法：关机 → 长按电源键进入恢复模式 → 选「选项」进入系统设置 → 打开「启动安全性实用工具」→ 勾选「系统完整性保护」→ 重启。"))

        items.append(toggleItem(
            id: "sec.gatekeeper",
            title: "Gatekeeper 评估",
            fact: f.gatekeeperEnabled,
            enabledText: "已开启",
            disabledText: "已关闭",
            severityWhenDisabled: .warning,
            suggestionWhenDisabled: "Gatekeeper 评估已关闭，未签名、未公证的程序可以直接运行。建议执行 spctl --enable 恢复，或在「系统设置 → 隐私与安全性」里检查相关开关。"))

        items.append(toggleItem(
            id: "sec.filevault",
            title: "FileVault 磁盘加密",
            fact: f.fileVaultEnabled,
            enabledText: "已开启",
            disabledText: "已关闭",
            severityWhenDisabled: .warning,
            suggestionWhenDisabled: "FileVault 没开时，机器丢了硬盘上的数据可以直接被读走。在「系统设置 → 隐私与安全性 → FileVault」打开即可（会要求设置恢复密钥）。"))

        items.append(toggleItem(
            id: "sec.firewall",
            title: "应用防火墙",
            fact: f.firewallEnabled,
            enabledText: "已开启",
            disabledText: "已关闭",
            severityWhenDisabled: .warning,
            suggestionWhenDisabled: "应用防火墙是关闭的，机器上开放的端口不会被系统拦截。在「系统设置 → 网络 → 防火墙」打开即可。"))

        // 代理
        switch f.proxyEnabled {
        case .unavailable(let reason):
            items.append(unavailable("sec.proxy", "系统代理", reason))
        case .value(let enabled):
            if enabled {
                items.append(DiagnosticItem(
                    id: "sec.proxy",
                    title: "系统代理",
                    value: f.proxyDetail.value ?? "已开启",
                    severity: .warning,
                    suggestion: "系统代理处于开启状态。如果不是你有意配的（例如代理软件退出后没清理），检查「系统设置 → 网络 → 代理」里的 HTTP / HTTPS / SOCKS 开关。"))
            } else {
                items.append(DiagnosticItem(
                    id: "sec.proxy",
                    title: "系统代理",
                    value: "未开启",
                    severity: .info))
            }
        }

        // 电源断言
        switch f.powerAssertions {
        case .unavailable(let reason):
            items.append(unavailable("sec.assertions", "电源断言", reason))
        case .value(let assertions):
            let blockers = assertions.filter { $0.contains("PreventSystemSleep") }
            let severity: DiagnosticSeverity = blockers.isEmpty ? .info : .warning
            var suggestion: String?
            if !blockers.isEmpty {
                // 持有者里可能就有 Deep Sleep 自己（它持有 PreventSystemSleep 是设计如此）。
                // 所以这里不写「退出它」，只指出要确认 —— 让用户自己判断哪个该关。
                let hasOwnHelper = assertions.contains { $0.contains("deepsleep.helper") }
                suggestion = hasOwnHelper
                    ? "有程序持有 PreventSystemSleep 断言，系统不会自动睡眠，电量会掉得很快。详情里列出了持有者（Deep Sleep 自身的助手也在其中，属正常行为）——确认其它持有者是不是需要一直阻止睡眠。"
                    : "有程序持有 PreventSystemSleep 断言，系统不会自动睡眠，电量会掉得很快。详情里列出了持有者，确认这些程序是不是需要一直阻止睡眠。"
            }
            items.append(DiagnosticItem(
                id: "sec.assertions",
                title: "电源断言",
                value: assertions.isEmpty ? "当前没有断言" : "\(assertions.count) 项在生效",
                severity: severity,
                suggestion: suggestion,
                detail: assertions.isEmpty ? nil : assertions.joined(separator: "\n")))
        }

        // 节能设置
        if let settings = f.energySettings.value {
            items.append(DiagnosticItem(
                id: "sec.energy",
                title: "节能设置",
                value: settings,
                severity: .info))
        } else {
            items.append(unavailable("sec.energy", "节能设置", f.energySettings.reason ?? "未采集"))
        }

        // 启动项数量
        if let agents = f.launchAgentsCount.value {
            let daemons = f.launchDaemonsCount.value
            items.append(DiagnosticItem(
                id: "sec.launch",
                title: "开机自启项",
                value: "LaunchAgents \(agents) 个\(daemons.map { " · LaunchDaemons \($0) 个" } ?? "")",
                severity: .info))
        } else {
            items.append(unavailable("sec.launch", "开机自启项", f.launchAgentsCount.reason ?? "未采集"))
        }

        // quarantine 文件数
        if let count = f.quarantinedFileCount.value {
            items.append(DiagnosticItem(
                id: "sec.quarantine",
                title: "下载目录中被隔离的文件",
                value: "\(count) 个",
                severity: .info,
                // 提示放 detail 而不是 suggestion：suggestion 只在「需要处理」时出现，
                // 这是这份报告的约定 —— 界面上靠 suggestion 区分问题与正常。
                detail: count > 0
                    ? "这些文件带 macOS 的隔离标记，双击会提示「无法验证开发者」。确认来源安全后，用工具箱里的 Quarantine 清除隔离标记即可。"
                    : nil))
        } else {
            items.append(unavailable("sec.quarantine", "下载目录中被隔离的文件", f.quarantinedFileCount.reason ?? "未采集"))
        }

        return DiagnosticSection(id: "security", title: "配置与安全", icon: "lock.shield", items: items)
    }

    // MARK: 进程与负载

    private static func processSection(_ f: DiagnosticFacts) -> DiagnosticSection {
        var items: [DiagnosticItem] = []

        // 负载均值
        switch f.loadAverage {
        case .unavailable(let reason):
            items.append(unavailable("proc.load", "系统负载", reason))
        case .value(let averages):
            if averages.isEmpty {
                items.append(unavailable("proc.load", "系统负载", "没有读到负载值"))
            } else {
            let oneMinute = averages[0]
            let cores = f.cpuCores.value ?? 0
            let perCore = cores > 0 ? oneMinute / Double(cores) : 0
            let severity: DiagnosticSeverity
            var suggestion: String?
            if cores > 0 && perCore >= DiagnosticThresholds.loadPerCoreWarning {
                severity = .warning
                suggestion = "负载已经超过核心数（每核 \(String(format: "%.2f", perCore))），CPU 处于满负荷。看下面「内存占用 Top 10」和活动监视器里的 CPU 占用，找出并停掉不需要的任务。"
            } else {
                severity = .info
            }
            let formatted = averages.map { String(format: "%.2f", $0) }.joined(separator: " / ")
            items.append(DiagnosticItem(
                id: "proc.load",
                title: "系统负载（1 / 5 / 15 分钟）",
                value: formatted,
                severity: severity,
                suggestion: suggestion))
            }
        }

        // 内存占用 Top 10
        switch f.topMemoryProcesses {
        case .unavailable(let reason):
            items.append(unavailable("proc.top", "内存占用 Top 10", reason))
        case .value(let processes):
            if processes.isEmpty {
                items.append(unavailable("proc.top", "内存占用 Top 10", "没有读到进程列表"))
            } else {
                let top = processes.prefix(10)
                let detail = top.enumerated().map { index, p in
                    "\(index + 1). \(p.name)（PID \(p.pid)）· \(formatBytes(p.rssBytes))"
                }.joined(separator: "\n")
                let largest = top.first
                var severity: DiagnosticSeverity = .info
                var suggestion: String?
                if let largest, let total = f.memoryBytes.value, total > 0 {
                    let share = Double(largest.rssBytes) / Double(total) * 100
                    if share >= 50 {
                        severity = .warning
                        suggestion = "\(largest.name) 一个进程就占了 \(String(format: "%.0f", share))% 物理内存。确认它是不是该常驻；不该常驻就退出它。"
                    }
                }
                items.append(DiagnosticItem(
                    id: "proc.top",
                    title: "内存占用 Top 10",
                    value: "\(top.count) 个进程",
                    severity: severity,
                    suggestion: suggestion,
                    detail: detail))
            }
        }

        return DiagnosticSection(id: "process", title: "进程与负载", icon: "chart.bar.xaxis", items: items)
    }

    // MARK: - 内部工具

    /// 造一条「读不到」的项。value 里带上原因，界面上直接能看出是缺能力还是读失败。
    private static func unavailable(_ id: String, _ title: String, _ reason: String) -> DiagnosticItem {
        DiagnosticItem(
            id: id,
            title: title,
            value: "无法读取（\(reason)）",
            severity: .info)
    }

    /// 合并多个事实的失败原因，取第一条能说明问题的。
    private static func missingReason(_ reasons: [String?]) -> String {
        for reason in reasons {
            if let reason, !reason.isEmpty { return reason }
        }
        return "未采集"
    }

    /// 开关型检查项（开 / 关）。
    private static func toggleItem(id: String,
                                   title: String,
                                   fact: DiagnosticFact<Bool>,
                                          enabledText: String,
                                          disabledText: String,
                                          severityWhenDisabled: DiagnosticSeverity,
                                          suggestionWhenDisabled: String) -> DiagnosticItem {
        switch fact {
        case .unavailable(let reason):
            return unavailable(id, title, reason)
        case .value(let enabled):
            return DiagnosticItem(
                id: id,
                title: title,
                value: enabled ? enabledText : disabledText,
                severity: enabled ? .info : severityWhenDisabled,
                suggestion: enabled ? nil : suggestionWhenDisabled)
        }
    }

    /// 字节数 → 人类可读。
    ///
    /// 用 1024 进制（1 GB = 1024³ 字节），不用 ByteCountFormatter 的十进制：
    ///   - ByteCountFormatter 的 .file 风格是十进制，8 GiB 内存会显示成「8.59 GB」，
    ///     而「内存 8 GB」是用户心里的数；
    ///   - 1024 进制也与 `df -Pk` 的输出对得上，用户拿报告跟命令行一比不会觉得矛盾。
    public static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        // 整数档不显示小数（8 GB 而不是 8.00 GB），小数档保留一位。
        if index == 0 {
            return "\(Int(value)) \(units[index])"
        }
        return String(format: "%.1f %@", value, units[index])
    }

    /// 秒 → 「7 天 3 小时 12 分」。
    public static func formatDuration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时 \(minutes) 分" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分"
    }
}
