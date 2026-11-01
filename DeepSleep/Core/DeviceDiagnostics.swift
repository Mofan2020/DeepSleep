//
//  DeviceDiagnostics.swift
//  Deep Sleep
//
//  设备诊断的采集层：跑命令、调系统 API，把**真实值**取回来。
//
//  边界（很重要）：
//    - **只读**。不请求管理员权限，不用 sudo，不改任何系统设置。
//    - 命令跑不到（工具不存在 / 权限不足 / 超时）就如实记「无法读取（原因）」，
//      绝不编数字。判定在 Shared/DiagnosticModel.swift，这里只管取数。
//    - 每条外部命令单条 10 秒上限，超时杀掉，不留僵尸进程。
//      扩展检查项的命令另用 3~5 秒的更紧上限，免得一个慢命令把整轮拖长。
//    - 全部在后台队列上跑，不卡主线程。
//
//  为什么特权数据（温度 / 进程统计）走协议注入：
//    这两个都要特权助手。抽象成协议后，本文件不硬依赖助手链路 ——
//    判定层与采集层都能单独编译、单独跑，测试也能塞假数据。
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - 特权数据源

/// 需要特权助手才能拿到的数据。
protocol DiagnosticsPrivilegedSource {

    /// 最高传感器温度（°C）与是否触到 90°C 兜底线。
    func hottestTemperature() async -> DiagnosticFact<Double>

    /// 内存占用最高的若干进程。
    func topMemoryProcesses(limit: Int) async -> DiagnosticFact<[DiagnosticProcessFact]>
}

/// 生产环境的数据源：复用 ThermalMonitor 与 ProcessStatsProvider。
///
/// 温度走 ThermalMonitor 而不是另起一路 IOHID：风扇兜底与这里必须是**同一份
/// 数据源**，两处各算一遍迟早会算出两个不一样的结论。
final class LiveDiagnosticsPrivilegedSource: DiagnosticsPrivilegedSource {

    static let shared = LiveDiagnosticsPrivilegedSource()

    func hottestTemperature() async -> DiagnosticFact<Double> {
        // refresh 走助手，会在 MainActor 上等一次 socket 往返。
        await ThermalMonitor.shared.refresh()
        let value = await MainActor.run { ThermalMonitor.shared.hottestCelsius }
        guard let value else {
            return .unavailable(reason: "特权助手未运行或不支持温度快照，拿不到传感器读数")
        }
        return .value(value)
    }

    func topMemoryProcesses(limit: Int) async -> DiagnosticFact<[DiagnosticProcessFact]> {
        do {
            let stats = try await ProcessStatsProvider.shared.fetchStats()
            let records = stats.records
                .sorted { $0.rssBytes > $1.rssBytes }
                .prefix(limit)
                .map {
                    DiagnosticProcessFact(pid: Int($0.pid),
                                          name: $0.name,
                                          rssBytes: $0.rssBytes)
                }
            return .value(Array(records))
        } catch {
            return .unavailable(reason: "读取进程快照失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 采集器

/// 设备诊断采集器。
enum DeviceDiagnostics {

    // MARK: 命令执行结果

    struct ShellResult {
        let status: Int32
        let stdout: String
        let stderr: String
        /// 超时被杀掉。
        let timedOut: Bool
        /// 进程根本起不来（工具不存在等）。
        let launchFailure: String?

        var succeeded: Bool { launchFailure == nil && !timedOut && status == 0 }

        /// 合并输出。失败原因优先看 stderr。
        var combined: String {
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !err.isEmpty { return err }
            return out
        }
    }

    /// 单条命令的超时上限。
    ///
    /// 10 秒：上面这些命令本机实测都在 0.1–1 秒内返回（memory_pressure 最慢，
    /// 约 0.5 秒），10 秒足够跑完，又不至于某个命令卡死把界面永远挂在「检测中」。
    static let commandTimeout: TimeInterval = 10

    /// 跑一条外部命令。整个过程在后台队列上做 —— waitUntilExit 是阻塞调用，
    /// 占着主线程界面会僵住。
    static func runShell(_ executable: String,
                         _ arguments: [String] = [],
                         timeout: TimeInterval = commandTimeout) async -> ShellResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ShellResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runShellBlocking(executable, arguments, timeout: timeout))
            }
        }
    }

    private static func runShellBlocking(_ executable: String,
                                         _ arguments: [String],
                                         timeout: TimeInterval) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // 不继承 stdin：有的命令（如 spctl）会等输入，继承终端就会永远挂着。
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ShellResult(status: -1,
                               stdout: "",
                               stderr: "",
                               timedOut: false,
                               launchFailure: "无法启动 \(executable)：\(error.localizedDescription)")
        }

        // 两个管道各自在后台线程读。输出能有几百 KB，不并发读的话管道缓冲区
        // 写满，命令卡在 write 上，两边一起走不下去。
        let group = DispatchGroup()
        let outBox = DataBox()
        let errBox = DataBox()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            let hardDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < hardDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            group.wait()
            closePipes(outPipe, errPipe)
            return ShellResult(status: -1, stdout: "", stderr: "",
                               timedOut: true, launchFailure: nil)
        }

        process.waitUntilExit()
        group.wait()
        closePipes(outPipe, errPipe)

        return ShellResult(status: process.terminationStatus,
                           stdout: String(decoding: outBox.value, as: UTF8.self),
                           stderr: String(decoding: errBox.value, as: UTF8.self),
                           timedOut: false,
                           launchFailure: nil)
    }

    /// 读完就关管道，别把文件描述符漏着。
    private static func closePipes(_ outPipe: Pipe, _ errPipe: Pipe) {
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
    }

    /// 带锁的数据盒：管道读取线程写、等待线程读。
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func set(_ data: Data) {
            lock.lock()
            storage = data
            lock.unlock()
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - 采集入口

    /// 跑一次完整采集，产出事实。
    ///
    /// 互不依赖的几组采集并行跑，整体耗时取决于最慢的那一条命令。
    static func collectFacts(privileged: DiagnosticsPrivilegedSource = LiveDiagnosticsPrivilegedSource.shared) async -> DiagnosticFacts {
        async let hw = collectHardware(privileged: privileged)
        async let storage = collectStorage()
        async let software = collectSoftware()
        async let security = collectSecurity()
        async let process = collectProcesses(privileged: privileged)

        var facts = DiagnosticFacts()
        let hardwareFacts = await hw
        let storageFacts = await storage
        let softwareFacts = await software
        let securityFacts = await security
        let processFacts = await process

        facts.modelName = hardwareFacts.modelName
        facts.chipName = hardwareFacts.chipName
        facts.cpuCores = hardwareFacts.cpuCores
        facts.memoryBytes = hardwareFacts.memoryBytes
        facts.hottestTemperatureCelsius = hardwareFacts.hottestTemperatureCelsius
        facts.memoryUsedPercent = hardwareFacts.memoryUsedPercent
        facts.memoryPressureFreePercent = hardwareFacts.memoryPressureFreePercent
        facts.swapUsedPercent = hardwareFacts.swapUsedPercent

        facts.volumes = storageFacts.volumes
        facts.battery = storageFacts.battery

        facts.osVersion = softwareFacts.osVersion
        facts.osBuild = softwareFacts.osBuild
        facts.kernelVersion = softwareFacts.kernelVersion
        facts.uptimeSeconds = softwareFacts.uptimeSeconds
        facts.consoleUser = softwareFacts.consoleUser
        facts.currentUser = softwareFacts.currentUser
        facts.hostName = softwareFacts.hostName

        facts.sipEnabled = securityFacts.sipEnabled
        facts.gatekeeperEnabled = securityFacts.gatekeeperEnabled
        facts.fileVaultEnabled = securityFacts.fileVaultEnabled
        facts.firewallEnabled = securityFacts.firewallEnabled
        facts.proxyEnabled = securityFacts.proxyEnabled
        facts.proxyDetail = securityFacts.proxyDetail
        facts.powerAssertions = securityFacts.powerAssertions
        facts.energySettings = securityFacts.energySettings
        facts.launchAgentsCount = securityFacts.launchAgentsCount
        facts.launchDaemonsCount = securityFacts.launchDaemonsCount
        facts.quarantinedFileCount = securityFacts.quarantinedFileCount

        facts.loadAverage = processFacts.loadAverage
        facts.topMemoryProcesses = processFacts.topMemoryProcesses

        return facts
    }

    /// 跑一次完整采集，直接出报告。
    static func collectReport(privileged: DiagnosticsPrivilegedSource = LiveDiagnosticsPrivilegedSource.shared) async -> DiagnosticReport {
        // 扩展检查项与主采集并发跑 —— 两边互不依赖，整体耗时取决于最慢的那一条命令。
        async let extras = collectExtraFacts()
        async let extras2 = collectExtraFacts2()

        let facts = await collectFacts(privileged: privileged)
        var report = DiagnosticEvaluator.evaluate(facts)
        report.sections.append(contentsOf: DgExtra.sections(from: await extras))
        report.sections.append(contentsOf: Dg2Extra.sections(from: await extras2))
        // 总结句按最终分组重算 —— 扩展项里也可能有需要注意的地方。
        report.summary = DiagnosticReport.summaryText(for: report.sections)
        return report
    }

    // MARK: 硬件

    private static func collectHardware(privileged: DiagnosticsPrivilegedSource) async -> DiagnosticFacts {
        var facts = DiagnosticFacts()

        async let modelResult = runShell("/usr/sbin/sysctl", ["-n", "hw.model"])
        async let chipResult = runShell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
        async let coresResult = runShell("/usr/sbin/sysctl", ["-n", "hw.ncpu"])
        async let memoryResult = runShell("/usr/sbin/sysctl", ["-n", "hw.memsize"])
        async let swapResult = runShell("/usr/sbin/sysctl", ["-n", "vm.swapusage"])
        async let pressureResult = runShell("/usr/bin/memory_pressure")
        async let temperature = privileged.hottestTemperature()

        facts.modelName = await stringFact(modelResult, name: "hw.model")
        facts.chipName = await stringFact(chipResult, name: "machdep.cpu.brand_string")
        facts.cpuCores = await intFact(coresResult, name: "hw.ncpu")
        facts.memoryBytes = await uint64Fact(memoryResult, name: "hw.memsize")
        facts.swapUsedPercent = await swapPercent(swapResult)
        facts.hottestTemperatureCelsius = await temperature

        // 内存压力：host_statistics64 给出精确的页统计，memory_pressure 工具
        // 给出系统自己算的「可用内存百分比」，两个都记下（后者做交叉验证）。
        let vm = await readVMStatistics()
        facts.memoryUsedPercent = memoryUsedPercent(vm)
        facts.memoryPressureFreePercent = await memoryPressureFreePercent(pressureResult)

        return facts
    }

    /// 页统计。
    struct VMStatistics {
        var pageSize: Int
        var free: UInt64
        var active: UInt64
        var inactive: UInt64
        var wired: UInt64
        var compressor: UInt64
        var speculative: UInt64
        /// 物理内存总页数（由 hw.memsize 推算，更准）。
        var totalPages: UInt64
    }

    /// 读 host_statistics64 的 HOST_VM_INFO64。
    static func readVMStatistics() async -> VMStatistics? {
        await withCheckedContinuation { (continuation: CheckedContinuation<VMStatistics?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var stats = vm_statistics64_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                                   / MemoryLayout<integer_t>.size)
                let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                        host_statistics64(mach_host_self(), HOST_VM_INFO64, raw, &count)
                    }
                }
                guard result == KERN_SUCCESS else {
                    continuation.resume(returning: nil)
                    return
                }
                var pageSize: vm_size_t = 0
                host_page_size(mach_host_self(), &pageSize)
                let size = Int(pageSize)
                let totalPages = totalPhysicalPages(pageSize: size)
                continuation.resume(returning: VMStatistics(
                    pageSize: size,
                    free: UInt64(stats.free_count),
                    active: UInt64(stats.active_count),
                    inactive: UInt64(stats.inactive_count),
                    wired: UInt64(stats.wire_count),
                    compressor: UInt64(stats.compressor_page_count),
                    speculative: UInt64(stats.speculative_count),
                    totalPages: totalPages))
            }
        }
    }

    /// 物理内存总页数。拿不到 hw.memsize 时用页统计之和兜底。
    private static func totalPhysicalPages(pageSize: Int) -> UInt64 {
        let bytes = readPhysicalMemoryBytes()
        if let bytes, pageSize > 0 {
            return UInt64(bytes) / UInt64(pageSize)
        }
        return 0
    }

    private static func readPhysicalMemoryBytes() -> UInt64? {
        // 同步读一次 sysctl 即可：这里已经在后台队列上。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", "hw.memsize"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return UInt64(text)
    }

    /// 内存已用百分比。
    ///
    /// 口径 = （活跃页 + 内核联动页 + 压缩页）/ 物理内存页数。
    /// 不把 inactive（可回收的文件缓存）算成「已用」—— 那是缓存，系统随时能收回来，
    /// 算进去会让数字看起来比实际更糟。
    private static func memoryUsedPercent(_ vm: VMStatistics?) -> DiagnosticFact<Double> {
        guard let vm, vm.totalPages > 0 else {
            return .unavailable(reason: "host_statistics64 读取失败")
        }
        let used = vm.active + vm.wired + vm.compressor
        return .value(Double(used) / Double(vm.totalPages) * 100)
    }

    /// 内存压力工具报告的「系统可用内存百分比」。
    ///
    /// 与 host_statistics64 算出的已用百分比互为交叉验证 —— 两者口径不同
    /// （一个含可回收缓存，一个不含），差得多说明系统正在换页。
    private static func memoryPressureFreePercent(_ result: ShellResult) async -> DiagnosticFact<Double> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "memory_pressure 超时")
        }
        let text = result.stdout + result.stderr
        guard let range = text.range(of: "memory free percentage:\\s*(\\d+)%",
                                     options: .regularExpression) else {
            return .unavailable(reason: "memory_pressure 没有返回可用内存百分比")
        }
        let slice = text[range]
        guard let number = slice.split(separator: "%").first,
              let value = Double(number.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") else {
            return .unavailable(reason: "memory_pressure 的可用内存百分比无法解析")
        }
        return .value(value)
    }

    /// 交换空间使用率（%）。
    private static func swapPercent(_ result: ShellResult) async -> DiagnosticFact<Double> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "sysctl vm.swapusage 超时")
        }
        let text = result.stdout
        // 形如：vm.swapusage: total = 8192.00M  used = 7283.50M  free = 908.50M
        func megabytes(_ key: String) -> Double? {
            guard let range = text.range(of: "\(key) = ") else { return nil }
            let rest = text[range.upperBound...]
            let token = rest.prefix { $0.isNumber || $0 == "." }
            guard var value = Double(token), !token.isEmpty else { return nil }
            let remainder = rest.dropFirst(token.count)
            if remainder.hasPrefix("G") { value *= 1024 }
            else if remainder.hasPrefix("K") { value /= 1024 }
            return value
        }
        guard let total = megabytes("total"), let used = megabytes("used"), total > 0 else {
            return .unavailable(reason: "sysctl vm.swapusage 没有返回可解析的数值")
        }
        return .value(used / total * 100)
    }

    // MARK: 存储与电池

    private static func collectStorage() async -> DiagnosticFacts {
        var facts = DiagnosticFacts()
        facts.volumes = .value(readVolumes())
        facts.battery = await readBattery()
        return facts
    }

    /// 已挂载卷的容量。
    ///
    /// 用 FileManager.mountedVolumeURLs 而不是 `df`：
    ///   - df 会因为某个 cryptexd 挂载点没权限就往 stderr 喷错误并返回非 0，
    ///     还得逐行猜哪些是伪文件系统；
    ///   - mountedVolumeURLs 给的是结构化的 URL + 容量，省掉整套文本解析。
    static func readVolumes() -> [DiagnosticVolumeFact] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey,
                                        .volumeAvailableCapacityKey,
                                        .volumeNameKey]
        guard let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                              options: []) else {
            return []
        }
        var result: [DiagnosticVolumeFact] = []
        var seen = Set<String>()
        for url in urls {
            let path = url.path
            // 系统辅助卷（Preboot / VM / Update / xarts / Data/home 等）与恢复卷
            // 不是用户会关心的「盘」，报告里只留真正能放东西的卷。
            if path.hasPrefix("/System/Volumes/") { continue }
            if path.hasPrefix("/private/var/run/") { continue }
            if path.hasSuffix("/Library/Developer/CoreDevice/DeviceFS") { continue }
            if path == "/Volumes/Recovery" { continue }

            guard let values = try? url.resourceValues(forKeys: keys),
                  let total = values.volumeTotalCapacity,
                  total > 0,
                  let available = values.volumeAvailableCapacity else { continue }

            let name = values.volumeName ?? (path as NSString).lastPathComponent
            // 同一块盘可能被挂载多次（macFUSE 那种），完全重复的只留一条。
            let signature = "\(name)|\(total)|\(available)"
            guard seen.insert(signature).inserted else { continue }

            result.append(DiagnosticVolumeFact(name: volumeDisplayName(path: path, rawName: name),
                                                mountPoint: path,
                                                totalBytes: UInt64(total),
                                                freeBytes: UInt64(available)))
        }
        return result
    }

    private static func volumeDisplayName(path: String, rawName: String) -> String {
        if path == "/" { return "系统卷（Macintosh HD）" }
        if path == "/System/Volumes/Data" { return "系统数据卷" }
        return rawName
    }

    /// 电池信息。
    ///
    /// 用 `ioreg -rc AppleSmartBattery`：它给得出 IOPS 给不出的循环次数与温度，
    /// 而且不需要额外框架依赖。数值取自 AppleSmartBattery 的属性字典。
    static func readBattery() async -> DiagnosticFact<DiagnosticBatteryFact> {
        let result = await runShell("/usr/sbin/ioreg", ["-rc", "AppleSmartBattery", "-l"])
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "ioreg 读取电池信息超时")
        }
        let text = result.stdout + "\n" + result.stderr
        guard text.contains("AppleSmartBattery") else {
            return .unavailable(reason: "未检测到电池（本机为台式机）")
        }

        func intValue(_ key: String) -> Int? {
            guard let range = text.range(of: "\"\(key)\"\\s*=\\s*\\d+",
                                         options: .regularExpression) else { return nil }
            let slice = text[range]
            guard let number = slice.split(separator: "=").last else { return nil }
            return Int(number.trimmingCharacters(in: .whitespaces))
        }
        func doubleValue(_ key: String) -> Double? {
            guard let range = text.range(of: "\"\(key)\"\\s*=\\s*\\d+(\\.\\d+)?",
                                         options: .regularExpression) else { return nil }
            let slice = text[range]
            guard let number = slice.split(separator: "=").last else { return nil }
            return Double(number.trimmingCharacters(in: .whitespaces))
        }

        // 「Temperature」的单位是 0.01°C（LifetimeData 里的历史最高温是 0.1°C）。
        let rawTemperature = doubleValue("Temperature")
        let temperature = rawTemperature.map { $0 / 100.0 }

        let cycleCount = intValue("CycleCount")
        let currentCapacity = doubleValue("CurrentCapacity")
        let maxCapacity = doubleValue("MaxCapacity")
        let designCapacity = intValue("DesignCapacity")
        let fullCharge = intValue("FullChargeCapacity") ?? intValue("AppleRawMaxCapacity")

        guard cycleCount != nil || currentCapacity != nil || designCapacity != nil else {
            return .unavailable(reason: "电池属性字典里没有可解析的数值")
        }

        return .value(DiagnosticBatteryFact(
            cycleCount: cycleCount,
            currentCapacityPercent: currentCapacity,
            maxCapacityPercent: maxCapacity,
            fullChargeCapacity: fullCharge,
            designCapacity: designCapacity,
            temperatureCelsius: temperature))
    }

    // MARK: 软件

    private static func collectSoftware() async -> DiagnosticFacts {
        var facts = DiagnosticFacts()

        async let swVers = runShell("/usr/bin/sw_vers")
        async let kernel = runShell("/usr/bin/uname", ["-r"])
        async let bootTime = runShell("/usr/sbin/sysctl", ["-n", "kern.boottime"])
        async let consoleUser = runShell("/usr/bin/stat", ["-f%Su", "/dev/console"])
        async let currentUser = runShell("/usr/bin/whoami")
        async let computerName = runShell("/usr/sbin/scutil", ["--get", "ComputerName"])

        let vers = await swVers
        facts.osVersion = swVersValue(vers, key: "ProductVersion")
        facts.osBuild = swVersValue(vers, key: "BuildVersion")

        let kernelResult = await kernel
        facts.kernelVersion = await stringFact(kernelResult, name: "uname -r")

        let bootResult = await bootTime
        facts.uptimeSeconds = uptimeSeconds(bootResult)

        let consoleResult = await consoleUser
        facts.consoleUser = await stringFact(consoleResult, name: "/dev/console 的登录用户")

        let currentResult = await currentUser
        facts.currentUser = await stringFact(currentResult, name: "当前用户")

        let nameResult = await computerName
        let hostName = await stringFact(nameResult, name: "计算机名")
        facts.hostName = hostName
        if case .unavailable = hostName {
            // scutil 拿不到时退回到 hostname。
            let fallback = await runShell("/bin/hostname")
            facts.hostName = await stringFact(fallback, name: "hostname")
        }

        return facts
    }

    private static func swVersValue(_ result: ShellResult, key: String) -> DiagnosticFact<String> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "sw_vers 超时")
        }
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard name == key else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            return .value(value)
        }
        return .unavailable(reason: "sw_vers 没有返回 \(key)")
    }

    /// 连续运行时间（秒）。由 kern.boottime 减当前时间得到。
    private static func uptimeSeconds(_ result: ShellResult) -> DiagnosticFact<Double> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "sysctl kern.boottime 超时")
        }
        // 形如：{ sec = 1792853605, usec = 608489 } Sat Oct 24 22:53:25 2026
        guard let range = result.stdout.range(of: "sec\\s*=\\s*(\\d+)",
                                             options: .regularExpression) else {
            return .unavailable(reason: "kern.boottime 没有返回可解析的时间")
        }
        let slice = result.stdout[range]
        guard let number = slice.split(separator: "=").last,
              let seconds = Double(number.trimmingCharacters(in: .whitespaces)) else {
            return .unavailable(reason: "kern.boottime 里的秒数无法解析")
        }
        let uptime = Date().timeIntervalSince1970 - seconds
        guard uptime > 0 else {
            return .unavailable(reason: "kern.boottime 解析出的开机时间在未来")
        }
        return .value(uptime)
    }

    // MARK: 配置与安全

    private static func collectSecurity() async -> DiagnosticFacts {
        var facts = DiagnosticFacts()

        async let sip = runShell("/usr/bin/csrutil", ["status"])
        async let gatekeeper = runShell("/usr/sbin/spctl", ["--status"])
        async let fileVault = runShell("/usr/bin/fdesetup", ["status"])
        async let firewall = runShell("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        async let proxy = runShell("/usr/sbin/scutil", ["--proxy"])
        async let assertions = runShell("/usr/bin/pmset", ["-g", "assertions"])
        async let energy = runShell("/usr/bin/pmset", ["-g", "custom"])

        facts.sipEnabled = await enabledFact(sip, on: "enabled", off: "disabled", item: "SIP 状态")
        facts.gatekeeperEnabled = await enabledFact(gatekeeper,
                                                    on: "assessments enabled",
                                                    off: "assessments disabled",
                                                    item: "Gatekeeper 状态")
        facts.fileVaultEnabled = await enabledFact(fileVault, on: "is On", off: "is Off", item: "FileVault 状态")
        facts.firewallEnabled = await enabledFact(firewall,
                                                  on: "is enabled",
                                                  off: "is disabled",
                                                  item: "防火墙状态")

        let proxyResult = await proxy
        let proxyInfo = parseProxy(proxyResult)
        facts.proxyEnabled = proxyInfo.enabled
        facts.proxyDetail = proxyInfo.detail

        let assertionResult = await assertions
        facts.powerAssertions = parsePowerAssertions(assertionResult)

        let energyResult = await energy
        facts.energySettings = parseEnergySettings(energyResult)

        facts.launchAgentsCount = countLaunchItems()
        facts.launchDaemonsCount = countLaunchDaemons()
        facts.quarantinedFileCount = await countQuarantinedFiles()

        return facts
    }

    /// 从命令输出里判断「开 / 关」。
    ///
    /// **先判 off 再判 on**：「disabled」里含有「enabled」这个子串，
    /// 反过来判会把「已关闭」读成「已开启」。这是这类字符串判断最容易踩的坑。
    ///
    /// 标记一律转成小写再比 —— `fdesetup` 的输出是「FileVault is On.」，
    /// 带大写 O，直接比小写标记会永远匹配不上。
    private static func enabledFact(_ result: ShellResult,
                                    on onText: String,
                                    off offText: String,
                                    item: String) async -> DiagnosticFact<Bool> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "\(item) 读取超时")
        }
        let text = result.combined.lowercased()
        if text.contains(offText.lowercased()) { return .value(false) }
        if text.contains(onText.lowercased()) { return .value(true) }
        return .unavailable(reason: "\(item) 的输出无法判断：\(result.combined.isEmpty ? "（无输出）" : result.combined)")
    }

    /// 代理设置。
    private static func parseProxy(_ result: ShellResult) -> (enabled: DiagnosticFact<Bool>, detail: DiagnosticFact<String>) {
        if let failure = result.launchFailure {
            return (.unavailable(reason: failure), .unavailable(reason: failure))
        }
        if result.timedOut {
            return (.unavailable(reason: "scutil --proxy 超时"), .unavailable(reason: "scutil --proxy 超时"))
        }
        let text = result.stdout
        func flag(_ key: String) -> Bool? {
            guard let range = text.range(of: "\(key)\\s*:\\s*(\\d)",
                                         options: .regularExpression) else { return nil }
            let slice = text[range]
            guard let number = slice.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else { return nil }
            return number == "1"
        }
        let http = flag("HTTPEnable")
        let https = flag("HTTPSEnable")
        let socks = flag("SOCKSEnable")
        guard http != nil || https != nil || socks != nil else {
            return (.unavailable(reason: "scutil --proxy 没有返回代理开关状态"),
                    .unavailable(reason: "scutil --proxy 没有返回代理开关状态"))
        }
        let enabled = (http == true) || (https == true) || (socks == true)
        var parts: [String] = []
        if http == true { parts.append("HTTP") }
        if https == true { parts.append("HTTPS") }
        if socks == true { parts.append("SOCKS") }
        let detail = enabled
            ? "已开启（\(parts.joined(separator: " / "))）"
            : "未开启"
        return (.value(enabled), .value(detail))
    }

    /// 当前生效的电源断言。
    ///
    /// `pmset -g assertions` 分两段：上半段是「哪些断言类型当前为 1」，
    /// 下半段是「谁持有」。两段都要 —— 只看类型不知道是谁占着。
    private static func parsePowerAssertions(_ result: ShellResult) -> DiagnosticFact<[String]> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "pmset -g assertions 超时")
        }
        let text = result.stdout
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(reason: "pmset -g assertions 没有输出")
        }

        var activeTypes: [String] = []
        var inSystemWide = true
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Listed by owning process") {
                inSystemWide = false
                continue
            }
            guard inSystemWide else { continue }
            let parts = line.split(separator: " ").filter { !$0.isEmpty }
            guard parts.count >= 2, parts.last == "1" else { continue }
            activeTypes.append(String(parts[0]))
        }

        // pid 139(powerd): [0x...] 00:17:14 PreventUserIdleSystemSleep named: "..."
        var holders: [String] = []
        // 括号用字符类 [(] / [)] 而不是 \\( / \\)：后者在源码里会写成
        // 「反斜杠 + 左括号」，肉眼与工具都容易误认成 Swift 的字符串插值。
        let pattern = "pid\\s+(\\d+)[(]([^)]*)[)]:\\s*\\[[^\\]]*\\]\\s+\\S+\\s+([A-Za-z]+)"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = text as NSString
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match else { return }
                let pid = ns.substring(with: match.range(at: 1))
                let process = ns.substring(with: match.range(at: 2))
                let type = ns.substring(with: match.range(at: 3))
                holders.append("\(type) · \(process)（pid \(pid)）")
            }
        }

        var lines: [String] = []
        if !activeTypes.isEmpty {
            lines.append("生效的断言类型：\(activeTypes.joined(separator: "、"))")
        }
        if !holders.isEmpty {
            lines.append(contentsOf: holders)
        }
        if lines.isEmpty {
            return .unavailable(reason: "pmset -g assertions 里没有正在生效的断言")
        }
        return .value(lines)
    }

    /// 节能设置摘要（电池 / 接电两套）。
    private static func parseEnergySettings(_ result: ShellResult) -> DiagnosticFact<String> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "pmset -g custom 超时")
        }
        let text = result.stdout
        guard text.contains("Power:") else {
            return .unavailable(reason: "pmset -g custom 没有返回电源配置")
        }

        var sections: [(title: String, settings: [String: String])] = []
        var currentTitle: String?
        var currentSettings: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("Power:") {
                if let title = currentTitle {
                    sections.append((title, currentSettings))
                }
                // 去掉结尾的 "Power:" 后要 trim —— 否则标题会带上尾随空格
                // （"Battery Power:" → "Battery "）。
                currentTitle = String(line.dropLast("Power:".count))
                    .trimmingCharacters(in: .whitespaces)
                currentSettings = [:]
                continue
            }
            guard currentTitle != nil else { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            // pmset 的输出是**列对齐**的，值前面有一堆空格（"lowpowermode         0"）。
            // 不 trim 的话报告里会显示成「低电量模式 关」带着一串空格。
            currentSettings[parts[0]] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        if let title = currentTitle {
            sections.append((title, currentSettings))
        }

        let interesting = ["sleep", "displaysleep", "disksleep", "standby", "lowpowermode", "powernap", "hibernatemode"]
        let labels: [String: String] = [
            "sleep": "系统睡眠",
            "displaysleep": "显示器",
            "disksleep": "磁盘",
            "standby": "待机",
            "lowpowermode": "低电量模式",
            "powernap": "Power Nap",
            "hibernatemode": "休眠"
        ]
        var parts: [String] = []
        for section in sections {
            let items = interesting.compactMap { key -> String? in
                guard let value = section.settings[key] else { return nil }
                let label = labels[key] ?? key
                if key == "sleep" || key == "displaysleep" || key == "disksleep" {
                    return "\(label) \(value) 分钟"
                }
                if key == "lowpowermode" {
                    return "\(label) \(value == "1" ? "开" : "关")"
                }
                return "\(label) \(value)"
            }
            guard !items.isEmpty else { continue }
            parts.append("\(section.title)：\(items.joined(separator: " · "))")
        }
        guard !parts.isEmpty else {
            return .unavailable(reason: "pmset -g custom 里没有可展示的节能项")
        }
        return .value(parts.joined(separator: "；"))
    }

    /// 第三方 LaunchAgents 数量（用户级 + /Library）。
    static func countLaunchItems() -> DiagnosticFact<Int> {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var count = 0
        for dir in ["\(home)/Library/LaunchAgents", "/Library/LaunchAgents"] {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            count += entries.filter { $0.hasSuffix(".plist") }.count
        }
        return .value(count)
    }

    /// 第三方 LaunchDaemons 数量（用户级 + /Library）。
    static func countLaunchDaemons() -> DiagnosticFact<Int> {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var count = 0
        for dir in ["\(home)/Library/LaunchDaemons", "/Library/LaunchDaemons"] {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            count += entries.filter { $0.hasSuffix(".plist") }.count
        }
        return .value(count)
    }

    /// 下载目录里带 quarantine 属性的文件数。
    ///
    /// 复用 QuarantineService —— xattr 的读法（listxattr + getxattr）它已经封好了，
    /// 这里不该再写一份。
    static func countQuarantinedFiles() async -> DiagnosticFact<Int> {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return .unavailable(reason: "没有「下载」目录")
        }
        let count = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let entries = (try? QuarantineService.shared.scan(root: root.path,
                                                                 recursive: true,
                                                                 includeHidden: false)) ?? []
                continuation.resume(returning: entries.count)
            }
        }
        return .value(count)
    }

    // MARK: 进程与负载

    private static func collectProcesses(privileged: DiagnosticsPrivilegedSource) async -> DiagnosticFacts {
        var facts = DiagnosticFacts()

        async let load = runShell("/usr/sbin/sysctl", ["-n", "vm.loadavg"])
        async let top = privileged.topMemoryProcesses(limit: 10)

        facts.loadAverage = await loadAverageFact(load)
        facts.topMemoryProcesses = await top
        return facts
    }

    /// 负载均值。sysctl vm.loadavg 输出形如 `{ 15.88 15.44 8.64 }`。
    private static func loadAverageFact(_ result: ShellResult) async -> DiagnosticFact<[Double]> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "sysctl vm.loadavg 超时")
        }
        let text = result.stdout
        guard let range = text.range(of: "\\{([^}]*)\\}", options: .regularExpression) else {
            return .unavailable(reason: "vm.loadavg 没有返回可解析的负载值")
        }
        let inner = text[range]
        let values = inner.split(separator: " ").compactMap { Double($0) }
        guard !values.isEmpty else {
            return .unavailable(reason: "vm.loadavg 里的数值无法解析")
        }
        return .value(values)
    }

    // MARK: 扩展检查项

    /// 采集扩展检查项的事实。
    ///
    /// 全部命令互不依赖，一起并发跑；每条命令的超时都收到 3~5 秒，
    /// 免得某一个慢命令把整轮诊断拖长。命令跑不动就记「读不到 + 原因」，
    /// 不当成故障。
    private static func collectExtraFacts() async -> DgExtraFacts {
        var facts = DgExtraFacts()

        async let hardware = runShell("/usr/sbin/system_profiler", ["SPHardwareDataType"], timeout: 5)
        async let displays = runShell("/usr/sbin/system_profiler", ["SPDisplaysDataType"], timeout: 5)
        async let storage = runShell("/usr/sbin/system_profiler", ["SPStorageDataType"], timeout: 5)
        async let software = runShell("/usr/sbin/system_profiler", ["SPSoftwareDataType"], timeout: 5)
        async let battery = runShell("/usr/bin/pmset", ["-g", "batt"], timeout: 4)
        async let power = runShell("/usr/bin/pmset", ["-g"], timeout: 4)
        async let schedule = runShell("/usr/bin/pmset", ["-g", "sched"], timeout: 4)
        async let top = runShell("/usr/bin/top",
                                 ["-l", "2", "-o", "cpu", "-n", "6", "-stats", "pid,command,cpu"],
                                 timeout: 5)
        async let extensions = runShell("/usr/bin/systemextensionsctl", ["list"], timeout: 4)
        async let smc = runShell("/usr/sbin/ioreg", ["-c", "AppleSMC"], timeout: 4)
        async let timeSync = runShell("/usr/sbin/systemsetup", ["-getusingnetworktime"], timeout: 4)
        async let groups = runShell("/usr/bin/id", ["-Gn"], timeout: 3)
        async let inode = runShell("/bin/df", ["-i", "/"], timeout: 4)

        facts.hardware = parsedFact(await hardware, name: "system_profiler SPHardwareDataType") {
            DgExtra.parseHardwareProfile($0)
        }
        facts.graphics = parsedFact(await displays, name: "system_profiler SPDisplaysDataType") {
            DgExtra.parseGraphicsProfile($0)
        }
        facts.storage = parsedFact(await storage, name: "system_profiler SPStorageDataType") {
            let drives = DgExtra.parseStorageDrives($0)
            return drives.isEmpty ? nil : drives
        }
        facts.software = parsedFact(await software, name: "system_profiler SPSoftwareDataType") {
            DgExtra.parseSoftwareProfile($0)
        }
        facts.power = parsedFact(await battery, name: "pmset -g batt") {
            DgExtra.parsePowerProfile($0)
        }
        facts.sleepBlockers = parsedFact(await power, name: "pmset -g") {
            let blockers = DgExtra.parseSleepBlockers($0)
            return blockers.isEmpty ? nil : blockers
        }
        facts.scheduledWake = listFact(await schedule, name: "pmset -g sched") {
            DgExtra.parseScheduledWake($0)
        }
        facts.topCPU = parsedFact(await top, name: "top") {
            let processes = DgExtra.parseTopCPU($0, limit: 5)
            return processes.isEmpty ? nil : processes
        }
        facts.systemExtensions = parsedFact(await extensions, name: "systemextensionsctl list") {
            let list = DgExtra.parseSystemExtensions($0)
            return list.isEmpty ? nil : list
        }
        facts.smcPresent = smcFact(await smc)
        facts.timeSync = timeSyncFact(await timeSync)
        facts.groups = parsedFact(await groups, name: "id -Gn") {
            let list = DgExtra.parseGroups($0)
            return list.isEmpty ? nil : list
        }
        facts.inode = parsedFact(await inode, name: "df -i") {
            DgExtra.parseInodeProfile($0)
        }

        facts.timezone = readTimezone()
        facts.hostsEntries = readHostsEntries()
        facts.crash = await readCrashProfile()
        facts.thirdPartyLaunchItems = readThirdPartyLaunchItems()

        return facts
    }

    // MARK: - 第二批扩展检查项（系统隐藏配置 + 已安装软件）

    /// 采集第二批扩展检查项的事实。
    ///
    /// 规矩与 collectExtraFacts 一致：全部只读、绝不请求提权、不改任何系统状态；
    /// 命令跑不动就记「读不到 + 原因」，不当成故障。
    ///
    /// 需要读文件系统的部分（应用清单、受保护目录、shell 配置、工具路径）
    /// 单独在一个后台队列上做，不占住命令行的并发额度。
    private static func collectExtraFacts2() async -> Dg2ExtraFacts {
        var facts = Dg2ExtraFacts()

        async let kernel = runShell("/usr/sbin/sysctl",
                                    ["kern.maxproc", "kern.maxfiles", "kern.maxfilesperproc",
                                     "kern.ipc.maxsockbuf",
                                     "net.inet.tcp.sendspace", "net.inet.tcp.recvspace",
                                     "net.inet.tcp.autosndbufmax", "net.inet.tcp.autorcvbufmax",
                                     "hw.physicalcpu", "hw.logicalcpu"],
                                    timeout: 5)
        async let swap = runShell("/usr/sbin/sysctl", ["-n", "vm.swapusage"], timeout: 4)
        async let launchLimits = runShell("/bin/launchctl", ["limit"], timeout: 4)
        async let launchList = runShell("/bin/launchctl", ["list"], timeout: 8)
        async let snapshots = runShell("/usr/sbin/diskutil", ["apfs", "listSnapshots", "/"], timeout: 8)
        async let tmDestination = runShell("/usr/bin/tmutil", ["destinationinfo"], timeout: 6)
        async let tmBackups = runShell("/usr/bin/tmutil", ["listbackups"], timeout: 8)
        async let spotlight = runShell("/usr/bin/mdutil", ["-s", "-a"], timeout: 6)
        async let dns = runShell("/usr/sbin/scutil", ["--dns"], timeout: 6)
        async let network = runShell("/usr/sbin/system_profiler", ["SPNetworkDataType"], timeout: 8)
        async let services = runShell("/usr/sbin/networksetup", ["-listallnetworkservices"], timeout: 6)
        async let vpn = runShell("/usr/sbin/scutil", ["--nc", "list"], timeout: 6)
        async let extensions = runShell("/usr/bin/systemextensionsctl", ["list"], timeout: 6)
        async let xprotect = runShell("/usr/bin/defaults",
                                      ["read", "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info"],
                                      timeout: 6)
        async let profiles = runShell("/usr/bin/profiles", ["show", "-type", "configuration"], timeout: 10)
        async let processes = runShell("/bin/ps", ["-Ao", "comm="], timeout: 6)
        async let inputSources = runShell("/usr/bin/defaults",
                                          ["read", "com.apple.HIToolbox", "AppleEnabledInputSources"],
                                          timeout: 6)
        async let audio = runShell("/usr/sbin/system_profiler", ["SPAudioDataType"], timeout: 8)
        async let printers = runShell("/usr/sbin/system_profiler", ["SPPrintersDataType"], timeout: 8)
        async let thunderbolt = runShell("/usr/sbin/system_profiler", ["SPThunderboltDataType"], timeout: 8)
        async let usb = runShell("/usr/sbin/system_profiler", ["SPUSBDataType"], timeout: 8)
        async let fonts = runShell("/usr/sbin/system_profiler", ["SPFontsDataType"], timeout: 15)
        async let battery = runShell("/usr/sbin/ioreg", ["-r", "-c", "AppleSmartBattery"], timeout: 6)
        async let brewFormula = runTool("brew", ["list", "--formula"], timeout: 12)
        async let brewCask = runTool("brew", ["list", "--cask"], timeout: 12)
        async let npm = runTool("npm", ["ls", "-g", "--depth=0"], timeout: 20)
        async let conda = runTool("conda", ["env", "list"], timeout: 12)
        async let dockerVersion = runTool("docker", ["--version"], timeout: 8)
        async let podmanVersion = runTool("podman", ["--version"], timeout: 8)
        async let colimaVersion = runTool("colima", ["--version"], timeout: 8)
        async let loginItems = runShell("/usr/bin/osascript",
                                        ["-e", "tell application \"System Events\" to get the name of every login item"],
                                        timeout: 10)
        async let backgroundItems = runShell("/usr/bin/sfltool", ["dumpbtm"], timeout: 10)
        async let fileFacts = collectExtraFacts2Files()

        // 内核参数（只看 stdout：sysctl 读不到的键会把提示写进 stderr）
        let kernelResult = await kernel
        facts.kernelLimits = dg2Fact(kernelResult, name: "sysctl 内核参数", includeStderr: false) { text in
            let values = Dg2Extra.parseKeyValues(text)
            return values.values.isEmpty ? nil : values
        }
        facts.tcpBuffers = dg2Fact(kernelResult, name: "sysctl TCP 参数", includeStderr: false) { text in
            let values = Dg2Extra.parseKeyValues(text)
            let keys = ["net.inet.tcp.sendspace", "net.inet.tcp.recvspace",
                        "net.inet.tcp.autosndbufmax", "net.inet.tcp.autorcvbufmax"]
            guard keys.contains(where: { values.string($0) != nil }) else { return nil }
            return values
        }
        facts.cpuTopology = dg2Fact(kernelResult, name: "sysctl CPU 参数", includeStderr: false) { text in
            Dg2Extra.parseCPUTopology(text)
        }

        facts.swapCapacity = dg2Fact(await swap, name: "sysctl vm.swapusage", includeStderr: false) {
            Dg2Extra.parseSwapCapacity($0)
        }
        facts.launchLimits = dg2Fact(await launchLimits, name: "launchctl limit") {
            let limits = Dg2Extra.parseLaunchLimits($0)
            return (limits.maxFilesSoft == nil && limits.maxProcSoft == nil) ? nil : limits
        }

        // launchctl list：第三方自启项 + 没跑起来的那些
        let launchResult = await launchList
        if let failure = launchResult.launchFailure {
            facts.launchFailures = .unavailable(reason: failure)
        } else if launchResult.timedOut {
            facts.launchFailures = .unavailable(reason: "launchctl list 超时")
        } else {
            let parsed = Dg2Extra.parseLaunchList(launchResult.stdout)
            facts.launchFailures = .value(parsed.failures)
            facts.launchThirdPartyCount = .value(parsed.thirdPartyCount)
        }

        facts.snapshots = dg2Fact(await snapshots, name: "diskutil apfs listSnapshots") {
            let parsed = Dg2Extra.parseSnapshots($0)
            return parsed.count == 0 ? nil : parsed
        }

        let tmDestinationResult = await tmDestination
        let tmBackupsResult = await tmBackups
        if let failure = tmDestinationResult.launchFailure {
            facts.timeMachine = .unavailable(reason: failure)
        } else {
            facts.timeMachine = .value(Dg2Extra.parseTimeMachine(destination: tmDestinationResult.stdout,
                                                               backups: tmBackupsResult.stdout))
        }

        facts.spotlight = dg2Fact(await spotlight, name: "mdutil -s -a") {
            let states = Dg2Extra.parseSpotlight($0)
            return states.isEmpty ? nil : states
        }
        facts.dns = dg2Fact(await dns, name: "scutil --dns") {
            Dg2Extra.parseDNS($0)
        }

        // 网络服务：接口代理来自 SPNetworkDataType，服务清单来自 networksetup。
        let networkResult = await network
        let servicesResult = await services
        if let failure = networkResult.launchFailure {
            facts.networkServices = .unavailable(reason: failure)
        } else if networkResult.timedOut {
            facts.networkServices = .unavailable(reason: "system_profiler SPNetworkDataType 超时")
        } else {
            var parsed = Dg2Extra.parseNetworkInterfaces(networkResult.stdout)
            let list = Dg2Extra.parseNetworkServiceList(servicesResult.stdout)
            parsed.services = list.services
            parsed.disabledServices = list.disabled
            facts.networkServices = .value(parsed)
        }

        facts.vpn = dg2Fact(await vpn, name: "scutil --nc list") {
            Dg2Extra.parseVPNList($0)
        }
        facts.networkExtensions = dg2Fact(await extensions, name: "systemextensionsctl list") {
            let list = Dg2Extra.parseNetworkExtensions($0)
            return list.isEmpty ? nil : list
        }
        facts.xprotectVersion = dg2Fact(await xprotect, name: "defaults read XProtect Info") {
            Dg2Extra.parseXProtectVersion($0)
        }
        facts.profiles = dg2Fact(await profiles, name: "profiles show -type configuration") {
            let list = Dg2Extra.parseProfiles($0)
            return list.isEmpty ? nil : list
        }

        // 文件系统那部分
        let files = await fileFacts

        // 安全客户端：进程名 + 已安装应用名一起找。
        let processResult = await processes
        facts.securityAgents = .value(Dg2Extra.parseSecurityAgents(processText: processResult.stdout,
                                                                   appNames: files.apps.entries.map(\.name)))

        facts.protectedDirs = .value(files.protectedDirs)
        facts.shellConfig = .value(files.shellConfig)
        facts.devPaths = .value(files.devPaths)
        facts.apps = .value(files.apps)

        facts.inputSources = dg2Fact(await inputSources, name: "defaults read AppleEnabledInputSources") {
            Dg2Extra.parseInputSources($0)
        }
        facts.audio = dg2Fact(await audio, name: "system_profiler SPAudioDataType") {
            Dg2Extra.parseAudio($0)
        }
        facts.printers = dg2Fact(await printers, name: "system_profiler SPPrintersDataType") {
            let list = Dg2Extra.parsePrinters($0)
            return list.isEmpty ? nil : list
        }

        // 雷雳接口 + SPUSBDataType 是否有输出
        let thunderboltResult = await thunderbolt
        let usbResult = await usb
        if let failure = thunderboltResult.launchFailure {
            facts.usb = .unavailable(reason: failure)
        } else if thunderboltResult.timedOut {
            facts.usb = .unavailable(reason: "system_profiler SPThunderboltDataType 超时")
        } else {
            var usb = Dg2Extra.parseThunderbolt(thunderboltResult.stdout)
            usb.usbListEmpty = usbResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            facts.usb = .value(usb)
        }

        facts.fonts = dg2Fact(await fonts, name: "system_profiler SPFontsDataType") {
            let parsed = Dg2Extra.parseFonts($0)
            return parsed.total == 0 ? nil : parsed
        }
        facts.battery = dg2Fact(await battery, name: "ioreg AppleSmartBattery") {
            Dg2Extra.parseBattery($0)
        }

        // 包管理器与容器运行时
        let brewFormulaResult = await brewFormula
        let brewCaskResult = await brewCask
        if let failure = brewFormulaResult.launchFailure {
            facts.brew = .unavailable(reason: failure)
        } else {
            facts.brew = .value(Dg2Extra.parseBrew(formulas: brewFormulaResult.stdout,
                                                    casks: brewCaskResult.stdout))
        }
        facts.npm = dg2Fact(await npm, name: "npm ls -g") {
            Dg2Extra.parseNpm($0)
        }
        facts.pythonEnvs = dg2Fact(await conda, name: "conda env list") {
            Dg2Extra.parseCondaEnvs($0)
        }

        // 容器运行时：装了哪些应用 + 命令行版本
        var runtimes: [Dg2ContainerRuntime] = files.containerApps.map { Dg2ContainerRuntime(name: $0, version: nil) }
        func appendRuntime(_ result: ShellResult, name: String) {
            guard result.launchFailure == nil, !result.timedOut else { return }
            let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !version.isEmpty else { return }
            if let index = runtimes.firstIndex(where: { $0.name == name }) {
                runtimes[index] = Dg2ContainerRuntime(name: name, version: version)
            } else {
                runtimes.append(Dg2ContainerRuntime(name: name, version: version))
            }
        }
        appendRuntime(await dockerVersion, name: "Docker")
        appendRuntime(await podmanVersion, name: "Podman")
        appendRuntime(await colimaVersion, name: "Colima")
        facts.containers = .value(runtimes)

        facts.receipts = dg2Fact(await runShell("/usr/sbin/pkgutil", ["--pkgs"], timeout: 8),
                                 name: "pkgutil --pkgs") {
            let parsed = Dg2Extra.parseReceipts($0)
            return parsed.total == 0 ? nil : parsed
        }
        facts.kexts = dg2Fact(await runShell("/usr/bin/kmutil", ["showloaded"], timeout: 8),
                              name: "kmutil showloaded") {
            let list = Dg2Extra.parseKexts($0)
            return list.isEmpty ? nil : list
        }

        // 登录项与后台项
        let loginResult = await loginItems
        if let failure = loginResult.launchFailure {
            facts.loginItems = .unavailable(reason: failure)
        } else if loginResult.timedOut {
            facts.loginItems = .unavailable(reason: "osascript 读取登录项超时")
        } else {
            // osascript 读 System Events 需要「自动化」权限，被拒时它会报错。
            let text = (loginResult.stdout + loginResult.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("not allowed assistive access") || text.contains("Not authorized")
                || text.contains("不允许") {
                facts.loginItems = .unavailable(reason: "系统没给自动化权限，读不到登录项")
            } else {
                facts.loginItems = .value(Dg2Extra.parseLoginItems(loginResult.stdout))
            }
        }
        facts.backgroundItems = dg2Fact(await backgroundItems, name: "sfltool dumpbtm") {
            let parsed = Dg2Extra.parseBackgroundItems($0)
            return parsed.names.isEmpty ? nil : parsed
        }

        return facts
    }

    /// 第二批检查项里需要读文件系统的部分。
    private struct Dg2FileFacts {
        var apps: Dg2Apps = Dg2Apps(entries: [])
        var protectedDirs: [Dg2ProtectedDir] = []
        var shellConfig: Dg2ShellConfig = Dg2ShellConfig(pathEntryCount: 0,
                                                        duplicatePathEntries: [],
                                                        insecureSettings: [],
                                                        file: nil)
        var devPaths: [Dg2ToolPath] = []
        var containerApps: [String] = []
    }

    /// 文件系统那部分在后台队列上做。
    private static func collectExtraFacts2Files() async -> Dg2FileFacts {
        await withCheckedContinuation { (continuation: CheckedContinuation<Dg2FileFacts, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readExtraFacts2Files())
            }
        }
    }

    private static func readExtraFacts2Files() -> Dg2FileFacts {
        var facts = Dg2FileFacts()
        facts.apps = readInstalledApps()
        facts.protectedDirs = readProtectedDirectories()
        facts.shellConfig = readShellConfig()
        facts.devPaths = readToolPaths()
        facts.containerApps = readContainerApps()
        return facts
    }

    /// 已安装的应用（/Applications 与 ~/Applications）。
    ///
    /// 顺手判断「疑似损坏」：缺 Info.plist，或主程序是 0 字节。
    private static func readInstalledApps() -> Dg2Apps {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var entries: [Dg2AppEntry] = []
        for directory in ["/Applications", "\(home)/Applications"] {
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for name in names.sorted() where name.hasSuffix(".app") {
                let path = "\(directory)/\(name)"
                let infoPath = "\(path)/Contents/Info.plist"
                guard fm.fileExists(atPath: infoPath) else {
                    entries.append(Dg2AppEntry(name: name, path: path, bundleID: nil,
                                               brokenReason: "缺少 Contents/Info.plist"))
                    continue
                }
                var bundleID: String?
                var brokenReason: String?
                if let data = fm.contents(atPath: infoPath),
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                   let dict = plist as? [String: Any] {
                    bundleID = dict["CFBundleIdentifier"] as? String
                    if let executable = dict["CFBundleExecutable"] as? String {
                        let binary = "\(path)/Contents/MacOS/\(executable)"
                        if fm.fileExists(atPath: binary),
                           let attributes = try? fm.attributesOfItem(atPath: binary),
                           let size = (attributes[.size] as? NSNumber)?.intValue,
                           size == 0 {
                            brokenReason = "主程序是 0 字节"
                        }
                    }
                }
                entries.append(Dg2AppEntry(name: name, path: path, bundleID: bundleID,
                                           brokenReason: brokenReason))
            }
        }
        return Dg2Apps(entries: entries)
    }

    /// 受保护目录的访问概览。
    ///
    /// 只做「能不能列目录」的判断，不读里面的内容 —— 也不去碰受限的 TCC.db 本体。
    private static func readProtectedDirectories() -> [Dg2ProtectedDir] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let targets: [(String, String)] = [
            ("照片", "\(home)/Library/Photos"),
            ("通讯录", "\(home)/Library/Contacts"),
            ("日历", "\(home)/Library/Calendars"),
            ("邮件", "\(home)/Library/Mail"),
            ("信息", "\(home)/Library/Messages"),
            ("提醒事项", "\(home)/Library/Reminders"),
            ("Safari", "\(home)/Library/Safari"),
            ("钥匙串", "\(home)/Library/Keychains"),
            ("移动文稿", "\(home)/Library/Mobile Documents"),
            ("TCC 授权数据库", "\(home)/Library/Application Support/com.apple.TCC/TCC.db")
        ]
        var result: [Dg2ProtectedDir] = []
        for (name, path) in targets {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if let items = try? fm.contentsOfDirectory(atPath: path) {
                    result.append(Dg2ProtectedDir(name: name, path: path, accessible: true,
                                                  itemCount: items.count, note: nil))
                } else {
                    result.append(Dg2ProtectedDir(name: name, path: path, accessible: false,
                                                  itemCount: 0,
                                                  note: "系统不允许读取（多半是没给完全磁盘访问权限）"))
                }
            } else {
                let readable = fm.isReadableFile(atPath: path)
                result.append(Dg2ProtectedDir(name: name, path: path, accessible: readable,
                                              itemCount: 0,
                                              note: readable ? nil : "系统不允许读取"))
            }
        }
        return result
    }

    /// shell 配置文件（.zshrc / .bash_profile 之类）拼成一段文本。
    ///
    /// 每个文件前面加一行「# --- 路径 ---」标记，解析层据此知道问题出在哪个文件。
    private static func readShellConfig() -> Dg2ShellConfig {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let files = ["\(home)/.zshrc", "\(home)/.zshenv", "\(home)/.zprofile",
                     "\(home)/.bash_profile", "\(home)/.bashrc", "\(home)/.profile"]
        var combined = ""
        for file in files {
            guard let text = try? String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8) else { continue }
            combined += "# --- \(file) ---\n"
            combined += text
            combined += "\n"
        }
        return Dg2Extra.parseShellConfig(combined)
    }

    /// 常见开发工具在磁盘上的所有副本。
    ///
    /// 不靠 PATH —— App 启动时的 PATH 很短，靠 PATH 找会漏掉用户自己装的那些。
    static func toolPaths(named name: String) -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                           "/opt/homebrew/sbin", "/usr/local/sbin",
                           "/opt/anaconda3/bin", "/usr/local/anaconda3/bin",
                           "\(home)/anaconda3/bin", "\(home)/miniconda3/bin",
                           "\(home)/.local/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        var result: [String] = []
        for directory in directories {
            let candidate = "\(directory)/\(name)"
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            if result.contains(candidate) { continue }
            result.append(candidate)
        }
        return result
    }

    /// 开发工具路径概览。
    private static func readToolPaths() -> [Dg2ToolPath] {
        let tools = ["python3", "node", "npm", "git", "ruby"]
        var result: [Dg2ToolPath] = []
        for tool in tools {
            let paths = toolPaths(named: tool)
            guard !paths.isEmpty else { continue }
            result.append(Dg2ToolPath(tool: tool, paths: paths))
        }
        return result
    }

    /// 装了哪些容器运行时的图形应用。
    private static func readContainerApps() -> [String] {
        let fm = FileManager.default
        let candidates: [(String, String)] = [
            ("/Applications/Docker.app", "Docker Desktop"),
            ("/Applications/OrbStack.app", "OrbStack"),
            ("/Applications/Podman Desktop.app", "Podman Desktop"),
            ("/Applications/Rancher Desktop.app", "Rancher Desktop")
        ]
        return candidates.filter { fm.fileExists(atPath: $0.0) }.map(\.1)
    }

    /// 命令输出 → 事实。解析不出内容就是「读不到 + 原因」，不是故障。
    private static func dg2Fact<T>(_ result: ShellResult,
                                   name: String,
                                   includeStderr: Bool = true,
                                   parse: (String) -> T?) -> DiagnosticFact<T> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "\(name) 超时")
        }
        let text = includeStderr && !result.stderr.isEmpty
            ? result.stdout + "\n" + result.stderr
            : result.stdout
        guard let value = parse(text) else {
            return .unavailable(reason: "\(name) 没有返回可解析的内容")
        }
        return .value(value)
    }

    /// 跑一个「不一定存在」的命令。
    ///
    /// 包管理器、容器运行时这些不是系统自带的，不能像 sysctl 那样写死路径 ——
    /// 先在常见安装位置里找，找到才跑；找不到就记「本机没有安装」。
    private static func runTool(_ tool: String,
                                _ arguments: [String],
                                timeout: TimeInterval = commandTimeout) async -> ShellResult {
        guard let path = toolPaths(named: tool).first else {
            return ShellResult(status: -1, stdout: "", stderr: "", timedOut: false,
                               launchFailure: "本机没有安装 \(tool)")
        }
        return await runShell(path, arguments, timeout: timeout)
    }

    /// 命令输出 → 事实。解析不出来就是「读不到 + 原因」，不是故障。
    private static func parsedFact<T>(_ result: ShellResult,
                                       name: String,
                                       parse: (String) -> T?) -> DiagnosticFact<T> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "\(name) 超时")
        }
        let text = result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
        guard let value = parse(text) else {
            return .unavailable(reason: "\(name) 没有返回可解析的内容")
        }
        return .value(value)
    }

    /// 命令输出 → 列表事实。
    ///
    /// 与 parsedFact 的区别：**空列表是有效结果**（比如 pmset -g sched 没有输出
    /// 就是「没有定时唤醒计划」，不是「读不到」）。
    private static func listFact<T>(_ result: ShellResult,
                                     name: String,
                                     parse: (String) -> [T]) -> DiagnosticFact<[T]> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "\(name) 超时")
        }
        return .value(parse(result.stdout))
    }

    /// SMC 控制器是否在位。
    private static func smcFact(_ result: ShellResult) -> DiagnosticFact<Bool> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "ioreg 读取 SMC 超时")
        }
        return .value(result.stdout.contains("AppleSMC"))
    }

    /// 网络时间同步状态。
    ///
    /// systemsetup 只有管理员能跑，普通用户拿到的是一句「You need administrator
    /// access」。这不是故障，是权限限制 —— 说清楚就好，诊断不请求提权。
    private static func timeSyncFact(_ result: ShellResult) -> DiagnosticFact<String> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "systemsetup 超时")
        }
        let text = (result.stdout + result.stderr).lowercased()
        if text.contains("administrator access") {
            return .unavailable(reason: "systemsetup 需要管理员权限，诊断不请求提权")
        }
        if text.contains("network time: on") {
            return .value("已开启（与网络时间同步）")
        }
        if text.contains("network time: off") {
            return .value("已关闭（时间由本机时钟维护）")
        }
        return .unavailable(reason: "systemsetup 没有返回时间同步状态")
    }

    /// 时区。从 /etc/localtime 指向的 zoneinfo 路径里读，不需要任何权限。
    private static func readTimezone() -> DiagnosticFact<String> {
        let resolved = URL(fileURLWithPath: "/etc/localtime").resolvingSymlinksInPath().path
        let marker = "/zoneinfo/"
        guard let range = resolved.range(of: marker) else {
            return .unavailable(reason: "/etc/localtime 不是指向 zoneinfo 的软链接")
        }
        let zone = String(resolved[range.upperBound...])
        guard !zone.isEmpty else {
            return .unavailable(reason: "读不到时区")
        }
        return .value(zone)
    }

    /// hosts 里生效的条目。
    private static func readHostsEntries() -> DiagnosticFact<[String]> {
        guard let text = try? String(contentsOf: URL(fileURLWithPath: "/etc/hosts"), encoding: .utf8) else {
            return .unavailable(reason: "读不到 /etc/hosts")
        }
        return .value(DgExtra.parseHostsEntries(text))
    }

    /// 崩溃报告统计。
    ///
    /// 目录直接读，不用命令：用户目录与系统目录的报告文件名就带类型
    /// （.panic 是内核崩溃，.ips 是应用崩溃）。
    private static func readCrashProfile() async -> DiagnosticFact<DgCrashProfile> {
        await withCheckedContinuation { (continuation: CheckedContinuation<DiagnosticFact<DgCrashProfile>, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readCrashProfileBlocking())
            }
        }
    }

    private static func readCrashProfileBlocking() -> DiagnosticFact<DgCrashProfile> {
        let fm = FileManager.default
        let directories = [
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)
        ]
        var userCount = 0
        var systemCount = 0
        var panicCount = 0
        var newestName: String?
        var newestDate: Date?

        for (index, directory) in directories.enumerated() {
            guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            var count = 0
            for name in entries {
                let url = directory.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { continue }
                count += 1
                if name.hasSuffix(".panic") { panicCount += 1 }
                if let attributes = try? fm.attributesOfItem(atPath: url.path),
                   let date = attributes[.modificationDate] as? Date {
                    if let current = newestDate {
                        if date > current {
                            newestDate = date
                            newestName = name
                        }
                    } else {
                        newestDate = date
                        newestName = name
                    }
                }
            }
            if index == 0 { userCount = count } else { systemCount = count }
        }

        guard userCount > 0 || systemCount > 0 else {
            return .unavailable(reason: "没有找到崩溃报告目录")
        }
        return .value(DgCrashProfile(userReportCount: userCount,
                                     systemReportCount: systemCount,
                                     panicCount: panicCount,
                                     newestReportName: newestName,
                                     newestReportDate: newestDate))
    }

    /// 第三方开机项（用户级与系统级的 LaunchAgents / LaunchDaemons）。
    ///
    /// Apple 自带的 com.apple.* 不列出来 —— 用户关心的是「谁在我开机时自己启动」。
    private static func readThirdPartyLaunchItems() -> DiagnosticFact<[String]> {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let directories = [
            "\(home)/Library/LaunchAgents",
            "/Library/LaunchAgents",
            "\(home)/Library/LaunchDaemons",
            "/Library/LaunchDaemons"
        ]
        var items: [String] = []
        for directory in directories {
            guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for name in entries.sorted() where name.hasSuffix(".plist") && !name.hasPrefix("com.apple.") {
                items.append("\(directory)/\(name)")
            }
        }
        return .value(items)
    }

    // MARK: - 小工具

    private static func stringFact(_ result: ShellResult, name: String) async -> DiagnosticFact<String> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "\(name) 读取超时")
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return .unavailable(reason: "\(name) 没有输出")
        }
        return .value(value)
    }

    private static func intFact(_ result: ShellResult, name: String) async -> DiagnosticFact<Int> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "\(name) 读取超时")
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(value), parsed > 0 else {
            return .unavailable(reason: "\(name) 没有返回可解析的数值")
        }
        return .value(parsed)
    }

    private static func uint64Fact(_ result: ShellResult, name: String) async -> DiagnosticFact<UInt64> {
        if let failure = result.launchFailure {
            return .unavailable(reason: failure)
        }
        if result.timedOut {
            return .unavailable(reason: "\(name) 读取超时")
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = UInt64(value), parsed > 0 else {
            return .unavailable(reason: "\(name) 没有返回可解析的数值")
        }
        return .value(parsed)
    }
}
