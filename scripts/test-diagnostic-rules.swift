//
//  test-diagnostic-rules.swift
//  Deep Sleep
//
//  设备诊断**判定层**的自测。测的是真实源码 Shared/DiagnosticModel.swift。
//
//  这一层是纯逻辑（只依赖 Foundation），所以这里既不启应用、也不连特权助手、
//  更不碰真机状态 —— 全部靠构造「事实」来驱动。
//
//  运行： swiftc -parse-as-library Shared/DiagnosticModel.swift \
//                    DeepSleep/Core/DiagnosticsExtras.swift \
//                    scripts/test-diagnostic-rules.swift -o /tmp/t_diag && /tmp/t_diag
//

import Foundation

@main
struct DiagnosticRuleTests {

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

        func checkEqual<T: Equatable>(_ name: String, _ lhs: T, _ rhs: T) {
            if lhs == rhs {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)：期望 \(rhs)，实际 \(lhs)")
                failures += 1
            }
        }

        /// 浮点比较。直接用 == 比 Double 会在精度末位上随机失败。
        func checkClose(_ name: String, _ lhs: Double, _ rhs: Double, tolerance: Double = 0.001) {
            if abs(lhs - rhs) <= tolerance {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)：期望 \(rhs)（±\(tolerance)），实际 \(lhs)")
                failures += 1
            }
        }

        /// 按 id 找一项。
        func item(_ report: DiagnosticReport, _ id: String) -> DiagnosticItem? {
            for section in report.sections {
                if let found = section.items.first(where: { $0.id == id }) { return found }
            }
            return nil
        }

        /// 按 id 在一组分组里找一项。
        func item(_ sections: [DiagnosticSection], _ id: String) -> DiagnosticItem? {
            for section in sections {
                if let found = section.items.first(where: { $0.id == id }) { return found }
            }
            return nil
        }

        // MARK: - 严重度排序

        print("\n== 严重度排序 ==")

        check("info < warning", DiagnosticSeverity.info < DiagnosticSeverity.warning)
        check("warning < critical", DiagnosticSeverity.warning < DiagnosticSeverity.critical)
        check("info < critical", DiagnosticSeverity.info < DiagnosticSeverity.critical)
        checkEqual("critical 的原始值最大", DiagnosticSeverity.critical.rawValue, 2)

        // Comparable 是升序（info 最轻）。界面上的展示顺序由
        // DiagnosticSection.problems 单独按降序排 —— 这两件事别搞混。
        let sorted: [DiagnosticSeverity] = [.critical, .info, .warning].sorted()
        checkEqual("升序排序：info → warning → critical", sorted, [.info, .warning, .critical])
        let descending: [DiagnosticSeverity] = [.critical, .info, .warning].sorted(by: >)
        checkEqual("降序排序：critical 在前", descending, [.critical, .warning, .info])

        checkEqual("中文标签：正常", DiagnosticSeverity.info.label, "正常")
        checkEqual("中文标签：注意", DiagnosticSeverity.warning.label, "注意")
        checkEqual("中文标签：严重", DiagnosticSeverity.critical.label, "严重")

        // 分组内问题项按严重度排序，正常项在后。
        let mixed = DiagnosticSection(id: "s", title: "组", icon: "cpu", items: [
            DiagnosticItem(id: "a", title: "正常项", value: "v", severity: .info),
            DiagnosticItem(id: "b", title: "轻微", value: "v", severity: .warning),
            DiagnosticItem(id: "c", title: "严重", value: "v", severity: .critical)
        ])
        checkEqual("问题项里 critical 排最前", mixed.problems.map(\.id), ["c", "b"])
        checkEqual("正常项单独归类", mixed.normalItems.map(\.id), ["a"])
        checkEqual("展示顺序 = 问题在前正常在后", mixed.displayItems.map(\.id), ["c", "b", "a"])

        // MARK: - 坏事实产出问题项

        print("\n== 坏事实 → 问题项 ==")

        var bad = DiagnosticFacts()
        bad.swapUsedPercent = .value(92)
        bad.volumes = .value([
            DiagnosticVolumeFact(name: "系统卷（Macintosh HD）",
                                 mountPoint: "/",
                                 totalBytes: 500_000_000_000,
                                 freeBytes: 15_000_000_000)   // 剩 3%
        ])
        bad.sipEnabled = .value(false)
        bad.memoryUsedPercent = .value(95)
        bad.hottestTemperatureCelsius = .value(95)
        bad.loadAverage = .value([16.0, 15.0, 9.0])
        bad.cpuCores = .value(8)
        bad.gatekeeperEnabled = .value(false)
        bad.fileVaultEnabled = .value(false)
        bad.firewallEnabled = .value(false)
        bad.battery = .value(DiagnosticBatteryFact(cycleCount: 700,
                                                    currentCapacityPercent: 80,
                                                    fullChargeCapacity: 3500,
                                                    designCapacity: 5000,
                                                    temperatureCelsius: 30))
        bad.uptimeSeconds = .value(40 * 86400)
        bad.powerAssertions = .value([
            "生效的断言类型：PreventSystemSleep",
            "PreventSystemSleep · some.app（pid 1234）"
        ])

        let badReport = DiagnosticEvaluator.evaluate(bad, generatedAt: Date(timeIntervalSince1970: 0))

        checkEqual("交换空间 92% 是严重", item(badReport, "hw.swap")?.severity, .critical)
        check("交换空间 92% 带建议",
              !(item(badReport, "hw.swap")?.suggestion ?? "").isEmpty,
              item(badReport, "hw.swap")?.suggestion ?? "")
        checkEqual("根卷剩 3% 是严重", item(badReport, "storage.volume.0")?.severity, .critical)
        check("根卷剩 3% 的建议提到清理",
              (item(badReport, "storage.volume.0")?.suggestion ?? "").contains("清理"),
              item(badReport, "storage.volume.0")?.suggestion ?? "")
        checkEqual("SIP 关闭是严重", item(badReport, "sec.sip")?.severity, .critical)
        check("SIP 关闭的建议提到恢复模式",
              (item(badReport, "sec.sip")?.suggestion ?? "").contains("恢复"),
              item(badReport, "sec.sip")?.suggestion ?? "")
        checkEqual("内存 95% 是严重", item(badReport, "hw.memory_usage")?.severity, .critical)
        checkEqual("温度 95°C 是严重", item(badReport, "hw.temperature")?.severity, .critical)
        checkEqual("Gatekeeper 关闭是需要注意", item(badReport, "sec.gatekeeper")?.severity, .warning)
        checkEqual("FileVault 关闭是需要注意", item(badReport, "sec.filevault")?.severity, .warning)
        checkEqual("防火墙关闭是需要注意", item(badReport, "sec.firewall")?.severity, .warning)
        checkEqual("电池健康 70% 是需要注意", item(badReport, "storage.battery")?.severity, .warning)
        checkEqual("开机 40 天是需要注意", item(badReport, "sw.uptime")?.severity, .warning)
        checkEqual("负载 16 / 8 核是需要注意", item(badReport, "proc.load")?.severity, .warning)

        checkEqual("电源断言带 PreventSystemSleep 时是需要注意",
                   item(badReport, "sec.assertions")?.severity, .warning)

        check("所有问题项都有非空建议", badReport.allItems
            .filter { $0.severity != .info }
            .allSatisfy { !($0.suggestion ?? "").isEmpty })
        check("问题项数量 > 0", badReport.problemCount > 0, "实际 \(badReport.problemCount)")

        // MARK: - 正常事实不产问题项

        print("\n== 正常事实 → 无问题 ==")

        var good = DiagnosticFacts()
        good.modelName = .value("Mac14,7")
        good.chipName = .value("Apple M2")
        good.cpuCores = .value(8)
        good.memoryBytes = .value(8_589_934_592)
        good.hottestTemperatureCelsius = .value(45.5)
        good.memoryUsedPercent = .value(40)
        good.swapUsedPercent = .value(5)
        good.volumes = .value([
            DiagnosticVolumeFact(name: "系统卷（Macintosh HD）",
                                 mountPoint: "/",
                                 totalBytes: 500_000_000_000,
                                 freeBytes: 250_000_000_000)
        ])
        good.battery = .value(DiagnosticBatteryFact(cycleCount: 194,
                                                    currentCapacityPercent: 92,
                                                    fullChargeCapacity: 4313,
                                                    designCapacity: 5103,
                                                    temperatureCelsius: 31.9))
        good.osVersion = .value("27.2")
        good.osBuild = .value("26B118")
        good.kernelVersion = .value("27.2.0")
        good.uptimeSeconds = .value(3 * 86400)
        good.consoleUser = .value("mofan")
        good.currentUser = .value("mofan")
        good.hostName = .value("MacBook Pro")
        good.sipEnabled = .value(true)
        good.gatekeeperEnabled = .value(true)
        good.fileVaultEnabled = .value(true)
        good.firewallEnabled = .value(true)
        good.proxyEnabled = .value(false)
        good.powerAssertions = .value(["生效的断言类型：PreventUserIdleDisplaySleep"])
        good.energySettings = .value("电池：系统睡眠 1 分钟 · 显示器 2 分钟")
        good.launchAgentsCount = .value(12)
        good.launchDaemonsCount = .value(11)
        good.quarantinedFileCount = .value(3)
        good.loadAverage = .value([1.2, 1.0, 0.9])
        good.topMemoryProcesses = .value([
            DiagnosticProcessFact(pid: 100, name: "Safari", rssBytes: 400_000_000)
        ])

        let goodReport = DiagnosticEvaluator.evaluate(good, generatedAt: Date(timeIntervalSince1970: 0))

        checkEqual("正常事实不产问题项", goodReport.problemCount, 0)
        checkEqual("严重项数为 0", goodReport.criticalCount, 0)
        checkEqual("注意项数为 0", goodReport.warningCount, 0)
        check("总结里写明全部正常", goodReport.summary.contains("全部正常"), goodReport.summary)
        checkEqual("顶部结论是「未发现需要注意的问题」", goodReport.headline, "未发现需要注意的问题")
        check("正常项仍然全部列出来（不藏数据）",
              goodReport.allItems.count >= 20, "实际 \(goodReport.allItems.count)")
        check("正常项不带建议",
              goodReport.allItems.filter { $0.severity == .info }
                  .allSatisfy { $0.suggestion == nil })

        // 断言里含 Deep Sleep 自己的助手时，措辞要跟着变 ——
        // 不能叫用户去退出自己正在用的应用。
        var ownHelper = good
        ownHelper.powerAssertions = .value([
            "生效的断言类型：PreventSystemSleep",
            "PreventSystemSleep · com.skyc8266.deepsleep.helper（pid 42385）"
        ])
        let ownReport = DiagnosticEvaluator.evaluate(ownHelper, generatedAt: Date(timeIntervalSince1970: 0))
        check("含自身助手时仍然是需要注意",
              item(ownReport, "sec.assertions")?.severity == .warning)
        check("含自身助手时措辞提到「属正常行为」",
              (item(ownReport, "sec.assertions")?.suggestion ?? "").contains("属正常行为"),
              item(ownReport, "sec.assertions")?.suggestion ?? "")

        // MARK: - 读不到的事实

        print("\n== 读不到的事实 ==")

        var missing = DiagnosticFacts()
        missing.modelName = .unavailable(reason: "sysctl 不可用")
        missing.volumes = .unavailable(reason: "没有权限")
        missing.swapUsedPercent = .unavailable(reason: "超时")
        let missingReport = DiagnosticEvaluator.evaluate(missing, generatedAt: Date(timeIntervalSince1970: 0))

        check("读不到的事实不会变成问题项",
              missingReport.allItems.filter { $0.severity != .info }.isEmpty)
        check("读不到时值里写明原因",
              (item(missingReport, "hw.identity")?.value ?? "").contains("无法读取"),
              item(missingReport, "hw.identity")?.value ?? "")
        check("读不到的原因带上了",
              (item(missingReport, "storage.volumes")?.value ?? "").contains("没有权限"),
              item(missingReport, "storage.volumes")?.value ?? "")
        check("完全没采集时报告仍有内容", !missingReport.sections.isEmpty)
        check("完全没采集时总结仍是人话",
              !missingReport.summary.isEmpty, missingReport.summary)

        // MARK: - 扩展检查项的解析

        print("\n== 扩展检查项：解析 ==")

        let hardwareText = """
        Hardware:

            Hardware Overview:

              Model Name: MacBook Pro
              Model Identifier: Mac14,7
              Chip: Apple M2
              Total Number of Cores: 8 (4 Performance and 4 Efficiency)
              Memory: 8 GB
              System Firmware Version: 20457.41.3
              Activation Lock Status: Enabled
        """

        let hardware = DgExtra.parseHardwareProfile(hardwareText)
        checkEqual("硬件：机型", hardware?.modelName ?? "", "MacBook Pro")
        checkEqual("硬件：芯片", hardware?.chipName ?? "", "Apple M2")
        checkEqual("硬件：固件版本", hardware?.firmwareVersion ?? "", "20457.41.3")
        checkEqual("硬件：内存", hardware?.memoryText ?? "", "8 GB")
        checkEqual("硬件：激活锁", hardware?.activationLock ?? "", "Enabled")
        checkEqual("硬件：核心总数", hardware?.cores?.total ?? -1, 8)
        checkEqual("硬件：性能核", hardware?.cores?.performance ?? -1, 4)
        checkEqual("硬件：能效核", hardware?.cores?.efficiency ?? -1, 4)
        checkEqual("硬件：核心构成的说法", hardware?.cores?.summary ?? "", "8 核（4 性能 + 4 能效）")
        check("硬件：Apple Silicon 没有插槽数", hardware?.memorySlots == nil)
        check("硬件：空输出解析不出东西", DgExtra.parseHardwareProfile("") == nil)
        check("硬件：机型键不会误命中机型标识",
              DgExtra.parseHardwareProfile("  Model Identifier: Mac14,7")?.modelName == nil)

        let intelHardware = DgExtra.parseHardwareProfile("""
          Model Name: iMac
          Chip: Intel Core i9
          Memory: 32 GB
          Slots: 2
        """)
        checkEqual("硬件：Intel 机的插槽数", intelHardware?.memorySlots ?? -1, 2)
        check("硬件：没有核心构成时不编数字", intelHardware?.cores == nil)

        let graphics = DgExtra.parseGraphicsProfile("""
        Graphics/Displays:

            Apple M2:

              Chipset Model: Apple M2
              Type: GPU
              Total Number of Cores: 10
              Vendor: Apple (0x106b)
        """)
        checkEqual("显卡：型号", graphics?.chipsetModel ?? "", "Apple M2")
        checkEqual("显卡：核心数", graphics?.coreCount ?? -1, 10)
        check("显卡：Apple Silicon 没有显存字段", graphics?.videoMemory == nil)
        let intelGraphics = DgExtra.parseGraphicsProfile("""
          Chipset Model: AMD Radeon Pro 5500M
          Total Number of Cores: 8
          VRAM: 8192 MB
        """)
        checkEqual("显卡：Intel 独显的显存", intelGraphics?.videoMemory ?? "", "8192 MB")
        check("显卡：空输出解析不出东西", DgExtra.parseGraphicsProfile("") == nil)

        let drives = DgExtra.parseStorageDrives("""
        Storage:

            Macintosh HD:

              Capacity: 494.38 GB
              Physical Drive:
                  Device Name: APPLE SSD AP0512Z
                  Medium Type: SSD
                  S.M.A.R.T. Status: Verified

            Backup:

              Physical Drive:
                  Device Name: External Disk
                  Medium Type: HDD
                  S.M.A.R.T. Status: Failed
        """)
        checkEqual("磁盘：读出两块盘", drives.count, 2)
        checkEqual("磁盘：第一块盘名", drives.first?.deviceName ?? "", "APPLE SSD AP0512Z")
        check("磁盘：第一块盘 SMART 通过", drives.first?.smartVerified ?? false)
        check("磁盘：第二块盘 SMART 没通过", !(drives.last?.smartVerified ?? true))
        check("磁盘：没有 Physical Drive 时解析不出东西",
              DgExtra.parseStorageDrives("Storage:\n\n  Macintosh HD:\n").isEmpty)

        // 同一块物理盘会被多个卷重复列出来，磁盘镜像不是真盘。
        let duplicatedDrives = DgExtra.parseStorageDrives("""
        Storage:

            Macintosh HD:

              Physical Drive:
                  Device Name: APPLE SSD AP0512Z
                  Medium Type: SSD
                  S.M.A.R.T. Status: Verified

            Data:

              Physical Drive:
                  Device Name: APPLE SSD AP0512Z
                  Medium Type: SSD
                  S.M.A.R.T. Status: Verified

            Update:

              Physical Drive:
                  Device Name: Disk Image
                  Medium Type: SSD
        """)
        checkEqual("磁盘：重复列出的物理盘会去重", duplicatedDrives.count, 1)
        check("磁盘：磁盘镜像不算真盘", DgExtra.parseStorageDrives("""
              Physical Drive:
                  Device Name: Disk Image
                  Medium Type: SSD
        """).isEmpty)
        check("磁盘：没有 SMART 状态不算「没通过」",
              !(DgStorageDrive(deviceName: "x", mediumType: nil, smartStatus: nil).smartFailed))

        let software = DgExtra.parseSoftwareProfile("""
          System Version: macOS 27.2 (26B118)
          Boot Volume: Macintosh HD
          Boot Mode: Normal
          Secure Virtual Memory: Enabled
        """)
        checkEqual("软件：启动模式", software?.bootMode ?? "", "Normal")
        checkEqual("软件：安全虚拟内存", software?.secureVirtualMemory ?? "", "Enabled")
        check("软件：正常启动不是安全模式", !(software?.isSafeMode ?? true))
        let safeSoftware = DgExtra.parseSoftwareProfile("Boot Mode: Safe Mode")
        check("软件：安全启动模式能认出来", safeSoftware?.isSafeMode ?? false)

        let power = DgExtra.parsePowerProfile("""
        Now drawing from 'AC Power'
         -InternalBattery-0 (id:9109603)\t80%; AC attached; not charging present: true
        """)
        checkEqual("电源：来源", power?.source ?? "", "交流电")
        checkEqual("电源：电量", power?.percent ?? -1, 80)
        let batteryPower = DgExtra.parsePowerProfile("Now drawing from 'Battery Power'")
        checkEqual("电源：电池供电", batteryPower?.source ?? "", "电池")
        check("电源：读不到时解析不出东西", DgExtra.parsePowerProfile("") == nil)

        let blockers = DgExtra.parseSleepBlockers("""
        System-wide power settings:
         SleepDisabled\t\t0
        Currently in use:
         sleep                1 (sleep prevented by UURemote, 哔哩哔哩, powerd)
         displaysleep         0 (display sleep prevented by 哔哩哔哩)
        """)
        check("阻止睡眠：读出三个进程", blockers.contains("powerd"), "\(blockers)")
        check("阻止睡眠：显示器那条也算进来", blockers.contains("哔哩哔哩"), "\(blockers)")
        check("阻止睡眠：没有就是空列表", DgExtra.parseSleepBlockers("sleep 1").isEmpty)

        checkEqual("定时唤醒：读出计划条数",
                   DgExtra.parseScheduledWake("  r  o  p  f  c  SAT    08:00:00    wake").count, 1)
        check("定时唤醒：没有计划是空列表", DgExtra.parseScheduledWake("").isEmpty)

        let top = DgExtra.parseTopCPU("""
        PID    COMMAND          %CPU
        58389  swift-frontend   70.1
        196    WindowServer     33.3

        PID    COMMAND          %CPU
        58389  swift-frontend   75.5
        196    WindowServer     30.2
        """, limit: 2)
        checkEqual("CPU 排行：取最后一次采样", top.count, 2)
        checkClose("CPU 排行：第一个进程的占用", top.first?.cpuPercent ?? 0, 75.5)
        checkEqual("CPU 排行：进程名", top.first?.name ?? "", "swift-frontend")
        checkEqual("CPU 排行：PID", top.first?.pid ?? -1, 58389)
        check("CPU 排行：没有表头就是空列表", DgExtra.parseTopCPU("随便一段文字").isEmpty)

        let extensions = DgExtra.parseSystemExtensions("""
        5 extension(s)
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        \t*\t4D7YV49724\tio.privado.main.smartroute (2.1.3/11)\tSmartRoute\t[activated disabled]
        \t*\tTC3Q7MAJXF\tcom.adguard.mac.adguard.network-extension (2.20/2626)\tAdGuard\t[activated disabled]
        *\t*\tMLZF7K7B5R\tat.obdev.littlesnitch.networkextension (6.5/7303)\tLittle Snitch\t[activated enabled]
        """)
        checkEqual("系统扩展：Apple 自家的不计入", extensions.count, 3)
        checkEqual("系统扩展：名字", extensions.first?.name ?? "", "SmartRoute")
        checkEqual("系统扩展：bundle id 去掉版本号", extensions.first?.bundleID ?? "", "io.privado.main.smartroute")
        check("系统扩展：启用状态能读出来", extensions.last?.enabled ?? false)
        check("系统扩展：没有扩展就是空列表", DgExtra.parseSystemExtensions("0 extension(s)").isEmpty)

        let hosts = DgExtra.parseHostsEntries("""
        #
        # Host Database
        #
        127.0.0.1\tlocalhost
        255.255.255.255\tbroadcasthost

        ::1\tlocalhost
        """)
        checkEqual("hosts：去掉注释与空行", hosts.count, 3)
        check("hosts：生效条目留着",
              hosts.contains("127.0.0.1\tlocalhost"), "\(hosts)")

        let inode = DgExtra.parseInodeProfile("""
        Filesystem     512-blocks      Used Available Capacity iused      ifree %iused  Mounted on
        /dev/disk3s1  965595304  27308888 340795272     8%  486810 1703976360    0%   /
        """)
        checkClose("inode：使用率", inode?.usedPercent ?? -1, 0)
        checkEqual("inode：已用个数", inode?.used ?? -1, 486810)
        check("inode：空输出解析不出东西", DgExtra.parseInodeProfile("") == nil)

        checkEqual("权限组：读出组名", DgExtra.parseGroups("staff admin everyone\n").count, 3)
        check("权限组：空输出是空列表", DgExtra.parseGroups("").isEmpty)
        check("权限组：末尾换行不会混进组名里",
              DgExtra.parseGroups("staff admin\n").last == "admin",
              DgExtra.parseGroups("staff admin\n").last ?? "")

        // MARK: - 扩展检查项的判定

        print("\n== 扩展检查项：判定 ==")

        // 全都读不到时：不能报成故障，只能是「无法读取」。
        let emptyExtra = DgExtra.sections(from: DgExtraFacts())
        check("扩展项：读不到时也有分组", emptyExtra.count == 4, "实际 \(emptyExtra.count)")
        check("扩展项：读不到时不产生问题项",
              emptyExtra.flatMap(\.items).allSatisfy { $0.severity == .info })
        check("扩展项：读不到时写明「无法读取」",
              emptyExtra.flatMap(\.items).allSatisfy { $0.value.contains("无法读取") })
        check("扩展项：读不到时不给处理建议",
              emptyExtra.flatMap(\.items).allSatisfy { $0.suggestion == nil })

        var goodExtra = DgExtraFacts()
        goodExtra.hardware = .value(DgHardwareProfile(modelName: "MacBook Pro",
                                                     chipName: "Apple M2",
                                                     cores: DgCoreProfile(total: 8, performance: 4, efficiency: 4),
                                                     memoryText: "8 GB",
                                                     firmwareVersion: "20457.41.3",
                                                     activationLock: "Enabled",
                                                     memorySlots: nil))
        goodExtra.graphics = .value(DgGraphicsProfile(chipsetModel: "Apple M2",
                                                      coreCount: 10,
                                                      videoMemory: nil))
        goodExtra.storage = .value([DgStorageDrive(deviceName: "APPLE SSD AP0512Z",
                                                   mediumType: "SSD",
                                                   smartStatus: "Verified")])
        goodExtra.software = .value(DgSoftwareProfile(bootMode: "Normal",
                                                      secureVirtualMemory: "Enabled",
                                                      bootVolume: "Macintosh HD"))
        goodExtra.smcPresent = .value(true)
        goodExtra.power = .value(DgPowerProfile(source: "交流电", percent: 80))
        goodExtra.sleepBlockers = .value([])
        goodExtra.scheduledWake = .value([])
        goodExtra.topCPU = .value([DgCPUProcess(pid: 58389, name: "swift-frontend", cpuPercent: 12.5)])
        goodExtra.systemExtensions = .value([DgSystemExtension(name: "Little Snitch",
                                                              bundleID: "at.obdev.littlesnitch.networkextension",
                                                              teamID: "MLZF7K7B5R",
                                                              state: "[activated enabled]",
                                                              enabled: true)])
        goodExtra.crash = .value(DgCrashProfile(userReportCount: 29,
                                                systemReportCount: 32,
                                                panicCount: 0,
                                                newestReportName: "swift-frontend-2026-11-01.ips",
                                                newestReportDate: Date(timeIntervalSince1970: 0)))
        goodExtra.timezone = .value("Asia/Shanghai")
        goodExtra.timeSync = .value("已开启（与网络时间同步）")
        goodExtra.groups = .value(["staff", "admin", "everyone"])
        goodExtra.inode = .value(DgInodeProfile(usedPercent: 0, used: 486810, free: 1703976360))
        goodExtra.hostsEntries = .value(["127.0.0.1\tlocalhost"])
        goodExtra.thirdPartyLaunchItems = .value(["/Library/LaunchAgents/io.example.plist"])

        let goodExtraSections = DgExtra.sections(from: goodExtra)
        checkEqual("扩展项：正常事实分成四组", goodExtraSections.count, 4)
        check("扩展项：正常事实不产生问题项",
              goodExtraSections.flatMap(\.items).allSatisfy { $0.severity == .info })
        checkEqual("扩展项：固件版本", item(goodExtraSections, "dg.firmware")?.value ?? "", "20457.41.3")
        checkEqual("扩展项：CPU 核心构成",
                   item(goodExtraSections, "dg.cpu_cores")?.value ?? "", "8 核（4 性能 + 4 能效）")
        checkEqual("扩展项：电源来源", item(goodExtraSections, "dg.power_source")?.value ?? "", "交流电 · 电量 80%")
        checkEqual("扩展项：时区", item(goodExtraSections, "dg.timezone")?.value ?? "", "Asia/Shanghai")
        check("扩展项：没有阻止睡眠的程序时是正常",
              item(goodExtraSections, "dg.sleep_blockers")?.severity == .info)
        check("扩展项：没有定时唤醒计划时不是「无法读取」",
              item(goodExtraSections, "dg.scheduled_wake")?.value == "没有定时唤醒计划")
        check("扩展项：崩溃报告没有内核崩溃时是正常",
              item(goodExtraSections, "dg.crash_reports")?.severity == .info)
        check("扩展项：SMIC 在位时说明读数要看特权助手",
              (item(goodExtraSections, "dg.smc")?.detail ?? "").contains("特权助手"))

        // 系统组件常驻在「sleep prevented by」里，只有第三方程序才值得提醒。
        var systemOnlyBlockers = goodExtra
        systemOnlyBlockers.sleepBlockers = .value(["powerd", "coreaudiod"])
        let systemOnlySections = DgExtra.sections(from: systemOnlyBlockers)
        checkEqual("阻止睡眠：只有系统组件时是正常",
                   item(systemOnlySections, "dg.sleep_blockers")?.severity, .info)
        check("阻止睡眠：系统组件时说明属正常",
              (item(systemOnlySections, "dg.sleep_blockers")?.value ?? "").contains("正常"))

        // 坏事实：出现需要注意的地方。
        var badExtra = goodExtra
        badExtra.storage = .value([DgStorageDrive(deviceName: "External Disk",
                                                   mediumType: "HDD",
                                                   smartStatus: "Failed")])
        badExtra.software = .value(DgSoftwareProfile(bootMode: "Safe Mode",
                                                      secureVirtualMemory: "Disabled",
                                                      bootVolume: nil))
        badExtra.sleepBlockers = .value(["UURemote", "powerd"])
        badExtra.crash = .value(DgCrashProfile(userReportCount: 3,
                                                systemReportCount: 4,
                                                panicCount: 2,
                                                newestReportName: "kernel-2026-11-01.panic",
                                                newestReportDate: nil))
        badExtra.topCPU = .value([DgCPUProcess(pid: 42, name: "build", cpuPercent: 180)])
        badExtra.hardware = .value(DgHardwareProfile(modelName: "MacBook Pro",
                                                     chipName: "Apple M2",
                                                     cores: nil,
                                                     memoryText: "8 GB",
                                                     firmwareVersion: "20457.41.3",
                                                     activationLock: "Disabled",
                                                     memorySlots: nil))

        let badExtraSections = DgExtra.sections(from: badExtra)
        checkEqual("扩展项：SMART 没通过是需要注意",
                   item(badExtraSections, "dg.smart")?.severity, .warning)
        check("扩展项：SMART 没通过要给建议",
              !(item(badExtraSections, "dg.smart")?.suggestion ?? "").isEmpty)
        checkEqual("扩展项：安全启动是需要注意",
                   item(badExtraSections, "dg.boot_mode")?.severity, .warning)
        checkEqual("扩展项：安全虚拟内存关闭是需要注意",
                   item(badExtraSections, "dg.secure_memory")?.severity, .warning)
        checkEqual("扩展项：激活锁关闭是需要注意",
                   item(badExtraSections, "dg.activation_lock")?.severity, .warning)
        checkEqual("扩展项：有程序阻止睡眠是需要注意",
                   item(badExtraSections, "dg.sleep_blockers")?.severity, .warning)
        checkEqual("扩展项：有内核崩溃报告是需要注意",
                   item(badExtraSections, "dg.crash_reports")?.severity, .warning)
        checkEqual("扩展项：单进程占满一整核是需要注意",
                   item(badExtraSections, "dg.top_cpu")?.severity, .warning)
        check("扩展项：问题项都有处理建议",
              badExtraSections.flatMap(\.items)
                  .filter { $0.severity != .info }
                  .allSatisfy { !($0.suggestion ?? "").isEmpty })

        // MARK: - 汇总计数

        print("\n== 汇总计数 ==")

        checkEqual("问题总数 = 严重 + 注意",
                  badReport.problemCount,
                  badReport.criticalCount + badReport.warningCount)
        check("总结里含问题计数",
              badReport.summary.contains("\(badReport.problemCount)"),
              badReport.summary)
        check("总结里含严重项数",
              badReport.summary.contains("\(badReport.criticalCount)"),
              badReport.summary)
        checkEqual("全部条目数 = 各组之和",
                  badReport.allItems.count,
                  badReport.sections.reduce(0) { $0 + $1.items.count })
        check("顶部结论含问题数",
              badReport.headline.contains("\(badReport.problemCount)"),
              badReport.headline)

        // MARK: - 报告全文

        print("\n== 报告全文 ==")

        let text = badReport.plainText
        check("全文含标题", text.contains("Deep Sleep 设备诊断报告"))
        check("全文含生成时间", text.contains("生成时间"))
        check("全文含结论", text.contains("结论"))
        check("全文含分组名", text.contains("【硬件】"))
        check("全文含处理建议", text.contains("处理建议"))
        check("全文含严重度标签", text.contains("严重"))
        check("全文非空", text.count > 200, "长度 \(text.count)")

        // MARK: - 存档

        print("\n== 存档 ==")

        let archived = DiagnosticReportArchive.encode(badReport)
        check("报告能编码成存档", archived != nil)
        if let archived {
            let restored = DiagnosticReportArchive.decode(archived)
            check("存档能解码回来", restored != nil)
            checkEqual("解码后分组数一致", restored?.sections.count ?? -1, badReport.sections.count)
            checkEqual("解码后问题数一致", restored?.problemCount ?? -1, badReport.problemCount)
            checkEqual("解码后全文一致", restored?.plainText ?? "", badReport.plainText)
        }
        check("损坏的存档解不出来", DiagnosticReportArchive.decode(Data([0x00, 0x01, 0x02])) == nil)
        check("空存档解不出来", DiagnosticReportArchive.decode(Data()) == nil)
        check("非 JSON 的存档解不出来",
              DiagnosticReportArchive.decode("这不是 JSON".data(using: .utf8)!) == nil)

        // 缺字段的存档：解码要回落默认值，不能整个炸掉。
        let partial = """
        {"generatedAt": 1000, "sections": [{"id": "x", "title": "半截的组", "items": \
        [{"id": "y", "title": "半截的项"}]}], "summary": "半截"}
        """
        if let data = partial.data(using: .utf8),
           let decoded = DiagnosticReportArchive.decode(data) {
            checkEqual("缺字段时分组仍解出来", decoded.sections.count, 1)
            checkEqual("缺字段时条目仍解出来", decoded.sections.first?.items.count ?? -1, 1)
            checkEqual("缺字段时严重度回落成正常",
                       decoded.sections.first?.items.first?.severity ?? .critical, .info)
            checkEqual("缺字段时值回落成空串",
                       decoded.sections.first?.items.first?.value ?? "x", "")
            check("缺字段时建议回落成 nil",
                  decoded.sections.first?.items.first?.suggestion == nil,
                  decoded.sections.first?.items.first?.suggestion ?? "<nil>")
        } else {
            check("缺字段的存档能解码", false)
        }

        // MARK: - 工具函数

        print("\n== 工具函数 ==")

        checkEqual("字节格式化（1024 进制）", DiagnosticEvaluator.formatBytes(1_073_741_824), "1.0 GB")
        checkEqual("字节格式化（内存容量）", DiagnosticEvaluator.formatBytes(8_589_934_592), "8.0 GB")
        checkEqual("字节格式化（字节档不显示小数）", DiagnosticEvaluator.formatBytes(512), "512 B")
        checkEqual("时长格式化（天）", DiagnosticEvaluator.formatDuration(3 * 86400 + 3600 * 2 + 60 * 5),
                   "3 天 2 小时 5 分")
        checkEqual("时长格式化（小时）", DiagnosticEvaluator.formatDuration(3600 * 5 + 60 * 12),
                   "5 小时 12 分")
        checkEqual("时长格式化（分钟）", DiagnosticEvaluator.formatDuration(125), "2 分")
        checkClose("电池健康度算法", DiagnosticBatteryFact(cycleCount: 1, currentCapacityPercent: 50,
                                                            fullChargeCapacity: 4309, designCapacity: 5103,
                                                            temperatureCelsius: nil).healthPercent ?? 0,
                   4309.0 / 5103.0 * 100)
        check("电池缺设计容量时健康度为 nil",
              DiagnosticBatteryFact(cycleCount: 1, currentCapacityPercent: 50,
                                   fullChargeCapacity: 4309, designCapacity: nil,
                                   temperatureCelsius: nil).healthPercent == nil)
        checkClose("卷剩余空间百分比",
                   DiagnosticVolumeFact(name: "x", mountPoint: "/", totalBytes: 100, freeBytes: 25).freePercent ?? 0,
                   25.0)
        check("卷总量为 0 时百分比为 nil",
              DiagnosticVolumeFact(name: "x", mountPoint: "/", totalBytes: 0, freeBytes: 0).freePercent == nil)

        // MARK: - 事实类型

        print("\n== 事实类型 ==")

        check("值型事实有值", DiagnosticFact.value(42).value == 42)
        check("值型事实没有失败原因", DiagnosticFact.value(42).reason == nil)
        check("不可用事实没有值", DiagnosticFact<String>.unavailable(reason: "坏了").value == nil)
        checkEqual("不可用事实保留原因", DiagnosticFact<String>.unavailable(reason: "坏了").reason, "坏了")
        check("不可用事实不算可用", !DiagnosticFact<String>.unavailable(reason: "坏了").isAvailable)
        check("值型事实算可用", DiagnosticFact.value(42).isAvailable)

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
