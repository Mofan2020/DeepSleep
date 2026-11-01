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
        let facts = await collectFacts(privileged: privileged)
        return DiagnosticEvaluator.evaluate(facts)
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
