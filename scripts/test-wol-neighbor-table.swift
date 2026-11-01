//
//  test-wol-neighbor-table.swift
//  DeepSleep
//
//  WOL 邻居表解析与「特权助手兜底」的自测：
//    - 经典 `arp -a` 的三种行（含主机名、`(incomplete)`）；
//    - 新版邻居表 `arp -l -a` 的表头与数据行；
//    - `netstat -rn -f inet` 里的邻居条目（含 `link#21`、带斜杠的 `/32` 行）；
//    - 助手回传原文 → 解析 → 与本地表合并；
//    - 助手兜底的三种结果（没缺 MAC / 缺了但助手没帮上忙 / 缺了且助手补上了）。
//
//  为什么这层要单独测：读邻居表受 macOS 的「本地网络隐私」限制 ——
//  App 进程里 `arp -a` 可能返回 0 行、退出码 0、也不报错（见文件头注释）。
//  助手那条路能不能救回来，全靠这几个纯解析函数。格式一变（缩进、列顺序、
//  多了个 `/32` 后缀），解析就会静默失配 —— 界面上表现为「扫到设备但发不了」，
//  没有报错、没有崩溃，用户只会以为设备不在线。这种错只能靠回归测试挡住。
//
//  运行（不需要 root、不需要网络、不需要装助手）：
//    swiftc -parse-as-library Shared/HelperProtocol.swift Shared/UnixSocket.swift \
//        DeepSleep/Privileged/HelperClient.swift DeepSleep/Core/WakeOnLANService.swift \
//        scripts/test-wol-neighbor-table.swift -o /tmp/t_wolneighbor && /tmp/t_wolneighbor
//

import Foundation

@main
struct WakeOnLANNeighborTableTests {

    static func main() async {
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

        // MARK: - 经典 arp -a

        print("\n== 经典 arp -a 解析 ==")

        let classicSample = """
        ? (192.168.1.1) at ec:e7:c2:9f:49:a1 on en0 ifscope [ethernet]
        router.lan (192.168.1.2) at a4:83:e7:11:22:33 on en0 ifscope [ethernet]
        ? (192.168.1.9) at (incomplete) on en0 ifscope [ethernet]

        """
        let classic = NetworkScanner.parseClassicARP(classicSample)
        checkEqual("解析出 2 条（(incomplete) 被跳过）", classic.count, 2)
        if classic.count == 2 {
            checkEqual("第 1 条 IP", classic[0].ip, "192.168.1.1")
            checkEqual("第 1 条 MAC 归一化成大写", classic[0].mac, "EC:E7:C2:9F:49:A1")
            checkEqual("主机名是 ? 时留空", classic[0].name, "")
            checkEqual("第 2 条 IP", classic[1].ip, "192.168.1.2")
            checkEqual("第 2 条带主机名", classic[1].name, "router.lan")
            checkEqual("第 2 条 MAC", classic[1].mac, "A4:83:E7:11:22:33")
        }
        checkEqual("空输出解析出 0 条", NetworkScanner.parseClassicARP("").count, 0)
        checkEqual("只有空行解析出 0 条", NetworkScanner.parseClassicARP("\n\n   \n").count, 0)
        checkEqual("畸形行解析出 0 条", NetworkScanner.parseClassicARP("垃圾行没有括号\n").count, 0)

        // 大小写混写的 MAC 要归一化成一致格式。
        let mixedCase = NetworkScanner.parseClassicARP("? (192.168.1.5) at EC:E7:C2:9F:49:A1 on en0 ifscope [ethernet]")
        checkEqual("大小写混写的 MAC 被归一化", mixedCase.first?.mac ?? "", "EC:E7:C2:9F:49:A1")

        // MARK: - 新版邻居表 arp -l -a

        print("\n== 邻居表 arp -l -a 解析 ==")

        let neighborSample = """
        Neighbor                Linklayer Address Expire(O) Expire(I)          Netif Refs Prbs
        192.168.1.1             3c:22:fb:aa:bb:cc       1180       1180            en0    1
        192.168.1.7             a4:83:e7:11:22:33       1190       1190            en0    1
        skyc8266.local          (incomplete)               0          0            lo0    1

        """
        let neighbors = NetworkScanner.parseNeighborTable(neighborSample)
        checkEqual("邻居表解析出 2 条（表头与 incomplete 被跳过）", neighbors.count, 2)
        if neighbors.count == 2 {
            checkEqual("邻居表第 1 条 IP", neighbors[0].ip, "192.168.1.1")
            checkEqual("邻居表第 1 条 MAC", neighbors[0].mac, "3C:22:FB:AA:BB:CC")
            checkEqual("邻居表第 2 条 IP", neighbors[1].ip, "192.168.1.7")
        }
        checkEqual("空邻居表解析出 0 条", NetworkScanner.parseNeighborTable("").count, 0)
        checkEqual("只有表头解析出 0 条",
                   NetworkScanner.parseNeighborTable("Neighbor  Linklayer Address  Expire(O)\n").count, 0)

        // MARK: - netstat -rn -f inet

        print("\n== netstat -rn -f inet 邻居条目解析 ==")

        let netstatSample = """
        Routing tables

        Internet:
        Destination        Gateway            Flags        Netif Expire
        default            192.168.1.1        UGSc           en0
        127                localhost          UCS            lo0
        localhost          localhost          UH             lo0
        192.168.1          link#11            UCS            en0        !
        192.168.1/32       link#11            UCS            en0        !
        192.168.1.1        ec:e7:c2:9f:49:a1  UHLWIir        en0   1180
        192.168.1.2        link#21            UHLWIg     bridge100   !

        """
        let routeEntries = NetworkScanner.parseNetstatNeighbors(netstatSample)
        checkEqual("只解析出 1 条邻居（link# / /32 / 网段行都被跳过）", routeEntries.count, 1)
        if routeEntries.count == 1 {
            checkEqual("邻居 IP", routeEntries[0].ip, "192.168.1.1")
            checkEqual("邻居 MAC 归一化成大写", routeEntries[0].mac, "EC:E7:C2:9F:49:A1")
        }

        // 带斜杠的 /32 行不能被当成 IP。
        checkEqual("192.168.1.1/32 不是 IP",
                   NetworkScanner.parseNetstatNeighbors("192.168.1.1/32     ec:e7:c2:9f:49:a1  UHLWIir  en0  1180").count, 0)
        // 网段行（192.168.1）也不是 IP。
        checkEqual("网段行 192.168.1 不是 IP",
                   NetworkScanner.parseNetstatNeighbors("192.168.1          ec:e7:c2:9f:49:a1  UCS  en0  !").count, 0)
        // 第 2 列是 link# 的行没有 MAC。
        checkEqual("link#21 不是 MAC",
                   NetworkScanner.parseNetstatNeighbors("192.168.1.2        link#21            UHLWIg  bridge100  !").count, 0)
        // 第 2 列是网关 IP 的行也没有 MAC。
        checkEqual("网关 IP 不是 MAC",
                   NetworkScanner.parseNetstatNeighbors("default            192.168.1.1        UGSc  en0").count, 0)
        // default 行、主机名行都不算邻居。
        checkEqual("default 行被跳过",
                   NetworkScanner.parseNetstatNeighbors("default            ec:e7:c2:9f:49:a1  UGSc  en0").count, 0)
        checkEqual("主机名行被跳过",
                   NetworkScanner.parseNetstatNeighbors("localhost          ec:e7:c2:9f:49:a1  UH  lo0").count, 0)

        checkEqual("空输出解析出 0 条", NetworkScanner.parseNetstatNeighbors("").count, 0)
        checkEqual("只有表头解析出 0 条",
                   NetworkScanner.parseNetstatNeighbors("Destination        Gateway            Flags        Netif Expire\n").count, 0)
        checkEqual("畸形行解析出 0 条", NetworkScanner.parseNetstatNeighbors("???\n").count, 0)
        checkEqual("只有一列的行被跳过", NetworkScanner.parseNetstatNeighbors("192.168.1.1\n").count, 0)

        // MARK: - 助手回传的原文 → 邻居表

        print("\n== 助手回传原文的解析 ==")

        let payload = WoNeighborTablePayload(
            arp: classicSample,
            neighbor: neighborSample,
            routes: netstatSample
        )
        check("非空载荷不算空", !payload.isEmpty)
        check("空载荷算空", WoNeighborTablePayload(arp: "", neighbor: "", routes: "").isEmpty)
        check("只有空白的载荷也算空",
              WoNeighborTablePayload(arp: "\n\n", neighbor: "  ", routes: "").isEmpty)

        let parsed = NetworkScanner.parseNeighborTablePayload(payload)
        // 经典 arp（.1 / .2）+ 邻居表（.1 / .7）+ netstat（.1），按 IP 去重后是 3 条。
        checkEqual("助手原文解析出 3 条（按 IP 去重）", parsed.count, 3)
        checkEqual("助手原文里的 MAC 归一化成大写",
                   parsed["192.168.1.1"]?.mac ?? "", "EC:E7:C2:9F:49:A1")
        checkEqual("助手原文里的主机名被保留",
                   parsed["192.168.1.2"]?.name ?? "", "router.lan")
        checkEqual("邻居表里的条目也在",
                   parsed["192.168.1.7"]?.mac ?? "", "A4:83:E7:11:22:33")

        // MARK: - 两张表怎么合并

        print("\n== 本地表与助手表的合并 ==")

        let local: [String: (mac: String, name: String)] = [
            "192.168.1.1": ("EC:E7:C2:9F:49:A1", ""),
            "192.168.1.2": ("", "")
        ]
        let remote: [String: (mac: String, name: String)] = [
            "192.168.1.1": ("AA:BB:CC:DD:EE:FF", "别的名字"),
            "192.168.1.2": ("A4:83:E7:11:22:33", "router.lan"),
            "192.168.1.7": ("3C:22:FB:AA:BB:CC", "")
        ]
        let merged = NetworkScanner.mergeNeighborTables(local: local, remote: remote)
        checkEqual("合并后 3 条", merged.count, 3)
        checkEqual("本地已有的 MAC 不被助手覆盖",
                   merged["192.168.1.1"]?.mac ?? "", "EC:E7:C2:9F:49:A1")
        checkEqual("本地缺 MAC 的被补上",
                   merged["192.168.1.2"]?.mac ?? "", "A4:83:E7:11:22:33")
        checkEqual("补 MAC 时主机名也带过来",
                   merged["192.168.1.2"]?.name ?? "", "router.lan")
        checkEqual("只在助手表里的条目被加进来",
                   merged["192.168.1.7"]?.mac ?? "", "3C:22:FB:AA:BB:CC")
        checkEqual("本地没名字时用助手的名字",
                   merged["192.168.1.1"]?.name ?? "", "别的名字")

        // MARK: - 助手兜底的三种结果

        print("\n== 特权助手兜底 ==")

        // 1) 主路已经齐了：不去打扰助手。
        let complete = await NetworkScanner.applyHelperFallback(
            table: ["192.168.1.1": ("EC:E7:C2:9F:49:A1", "")],
            alive: ["192.168.1.1"]
        )
        check("主路没缺 MAC 时不尝试助手", !complete.attempted)
        checkEqual("主路没缺 MAC 时补到 0 条", complete.recoveredCount, 0)
        checkEqual("主路没缺 MAC 时表原样返回", complete.table.count, 1)

        // 2) 主路缺 MAC：会尝试助手。这台机器没装助手，助手那条路会失败 ——
        //    失败必须被吞掉，不能让整次扫描挂掉。
        let missing = await NetworkScanner.applyHelperFallback(
            table: [:],
            alive: ["192.168.1.1"]
        )
        check("缺 MAC 时尝试过助手", missing.attempted)
        checkEqual("助手帮不上忙时补到 0 条", missing.recoveredCount, 0)
        checkEqual("助手帮不上忙时表仍然是空的", missing.table.count, 0)

        // 3) 助手超时也要有上限，不能无限等。
        check("助手兜底有超时上限", NetworkScanner.helperNeighborTimeout > 0)

        // MARK: - 扫描结果摘要

        print("\n== 扫描结果摘要 ==")

        let wakeable = WakeOnLANDevice(ipAddress: "192.168.1.10", macAddress: "AA:BB:CC:DD:EE:FF",
                                       deviceName: "nas.lan", vendor: "Apple")
        let noMAC = WakeOnLANDevice(ipAddress: "192.168.1.11", macAddress: "",
                                    deviceName: "192.168.1.11", vendor: WakeOnLAN.unknownVendor)

        let emptySummary = WoScanSummary(devices: [])
        check("没扫到设备时是空的", emptySummary.isEmpty)
        checkEqual("没扫到设备时可唤醒数为 0", emptySummary.wakeableCount, 0)
        checkEqual("没扫到设备时缺 MAC 数为 0", emptySummary.missingMACCount, 0)
        check("没扫到设备时不是「只有 IP」", !emptySummary.isMissingMACOnly)
        check("默认没试过助手", !emptySummary.helperFallbackAttempted)
        checkEqual("默认助手补到 0 条", emptySummary.helperFallbackRecoveredCount, 0)

        let mixedSummary = WoScanSummary(devices: [wakeable, noMAC])
        check("扫到设备时不是空的", !mixedSummary.isEmpty)
        checkEqual("有 MAC 的设备数对得上", mixedSummary.wakeableCount, 1)
        checkEqual("没拿到 MAC 的设备数对得上", mixedSummary.missingMACCount, 1)
        check("既有可唤醒又有缺 MAC 时不算「只有 IP」", !mixedSummary.isMissingMACOnly)

        let onlyIPSummary = WoScanSummary(devices: [noMAC])
        check("扫到设备但都没有 MAC 时是「只有 IP」", onlyIPSummary.isMissingMACOnly)
        checkEqual("这种情况可唤醒数为 0", onlyIPSummary.wakeableCount, 0)
        checkEqual("这种情况缺 MAC 数等于设备数", onlyIPSummary.missingMACCount, 1)

        // 界面靠这两个字段区分「还没试过助手」和「试了、助手也没帮上忙」。
        let afterHelper = WoScanSummary(devices: [noMAC],
                                        helperFallbackAttempted: true,
                                        helperFallbackRecoveredCount: 0)
        check("试过助手且没补到时是「助手也没帮上忙」", afterHelper.isMissingMACAfterHelper)
        check("试过助手不等于补到东西", !afterHelper.didHelperRecover)

        let recovered = WoScanSummary(devices: [wakeable, noMAC],
                                     helperFallbackAttempted: true,
                                     helperFallbackRecoveredCount: 1)
        check("助手补到东西时不算「助手也没帮上忙」", !recovered.isMissingMACAfterHelper)
        check("助手补到东西时 didHelperRecover 为真", recovered.didHelperRecover)

        // MARK: - 合并行为不变

        print("\n== 合并：ARP 与 ping 结果回归 ==")

        let network24 = LocalIPv4Network(interfaceName: "en0", address: "192.168.1.64",
                                         prefixLength: 24, broadcastAddress: "192.168.1.255")
        let table: [String: (mac: String, name: String)] = [
            "192.168.1.1": ("3C:22:FB:AA:BB:CC", ""),
            "192.168.1.7": ("A4:83:E7:11:22:33", "nas.lan"),
            "10.0.0.5": ("00:11:22:33:44:55", "")   // 别的网段，不该出现
        ]
        let mergedDevices = NetworkScanner.merge(table: table,
                                                 alive: ["192.168.1.1", "192.168.1.5"],
                                                 network: network24)
        checkEqual("合并后 3 台（.1 / .5 / .7）", mergedDevices.count, 3)
        check("只有 ping 回应的设备也在列表里", mergedDevices.contains { $0.ipAddress == "192.168.1.5" })
        check("别的网段的 ARP 条目被丢掉", !mergedDevices.contains { $0.ipAddress == "10.0.0.5" })
        checkEqual("按 IP 数值排序", mergedDevices.map(\.ipAddress),
                   ["192.168.1.1", "192.168.1.5", "192.168.1.7"])
        check("只有 ping 的设备没有 MAC",
              mergedDevices.first { $0.ipAddress == "192.168.1.5" }?.macAddress == "")

        // 助手补进来的 MAC 与 ARP 表里的 MAC 走同一条合并路径。
        var filled = table
        filled["192.168.1.5"] = ("B8:27:EB:11:22:33", "")
        let mergedFilled = NetworkScanner.merge(table: filled,
                                                alive: ["192.168.1.1", "192.168.1.5"],
                                                network: network24)
        checkEqual("补上 MAC 后设备数不变", mergedFilled.count, 3)
        check("补上 MAC 的设备可以唤醒",
              mergedFilled.first { $0.ipAddress == "192.168.1.5" }?.canWake == true)
        checkEqual("补上 MAC 的设备按 OUI 对厂商",
                   mergedFilled.first { $0.ipAddress == "192.168.1.5" }?.vendor ?? "", "Raspberry Pi")

        report(failures)
    }

    static func report(_ failures: Int) {
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
