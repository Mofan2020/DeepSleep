//
//  test-wol-packet.swift
//  DeepSleep
//
//  WakeOnLAN 的纯逻辑自测：MAC 解析、魔术包构造、ARP 输出解析、网段推断。
//  测的是真实源码 DeepSleep/Core/WakeOnLANService.swift。
//
//  为什么这层要单独测：魔术包少一个字节、MAC 字节序反了，发包那边一样
//  返回「发出去了 102 字节」，用户看到的是「发送成功」而设备纹丝不动 ——
//  这种错在界面上完全看不出来，只能在这里挡住。
//
//  运行：
//    swiftc -parse-as-library DeepSleep/Core/WakeOnLANService.swift \
//        scripts/test-wol-packet.swift -o /tmp/t_wol && /tmp/t_wol
//

import Foundation

@main
struct WakeOnLANPacketTests {

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

        // 一个字节一个字节比，失败时能看出是哪一位错了。
        func checkBytes(_ name: String, _ lhs: [UInt8], _ rhs: [UInt8]) {
            if lhs == rhs {
                print("  [通过] \(name)")
            } else {
                let shown = lhs.map { String(format: "%02X", $0) }.joined(separator: " ")
                print("  [失败] \(name)：期望 \(rhs.count) 字节，实际 \(lhs.count) 字节 —— \(shown)")
                failures += 1
            }
        }

        // MARK: - 三种 MAC 写法

        print("\n== MAC 解析：三种写法 ==")

        let colon = WakeOnLAN.parseMAC("AA:BB:CC:DD:EE:FF")
        let dash = WakeOnLAN.parseMAC("AA-BB-CC-DD-EE-FF")
        let plain = WakeOnLAN.parseMAC("aabbccddeeff")
        let expected: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]

        check("冒号写法解析成功", colon != nil)
        check("减号写法解析成功", dash != nil)
        check("无分隔符写法解析成功", plain != nil)
        checkBytes("冒号写法解析成 6 字节", colon ?? [], expected)
        checkBytes("减号写法解析成 6 字节", dash ?? [], expected)
        checkBytes("无分隔符写法解析成 6 字节", plain ?? [], expected)
        check("三种写法解析结果完全一致", colon == dash && dash == plain)

        // MARK: - 大小写与空白

        print("\n== MAC 解析：大小写与空白 ==")

        checkBytes("小写输入解析后字节相同", WakeOnLAN.parseMAC("aa:bb:cc:dd:ee:ff") ?? [], expected)
        checkBytes("大小写混写解析成功", WakeOnLAN.parseMAC("Aa:bB:cc:DD:ee:Ff") ?? [], expected)
        checkBytes("两边空格被忽略", WakeOnLAN.parseMAC("  AA:BB:CC:DD:EE:FF  ") ?? [], expected)
        checkEqual("小写输入归一化成大写",
                   WakeOnLAN.normalizedMAC("aa:bb:cc:dd:ee:ff") ?? "nil",
                   "AA:BB:CC:DD:EE:FF")
        checkEqual("无分隔符输入归一化成带冒号大写",
                   WakeOnLAN.normalizedMAC("aabbccddeeff") ?? "nil",
                   "AA:BB:CC:DD:EE:FF")
        checkEqual("减号输入归一化成带冒号大写",
                   WakeOnLAN.normalizedMAC("aa-bb-cc-dd-ee-ff") ?? "nil",
                   "AA:BB:CC:DD:EE:FF")

        // MARK: - 非法 MAC

        print("\n== MAC 解析：非法输入返回 nil ==")

        let invalidInputs: [(String, String)] = [
            ("空字符串", ""),
            ("只有空白", "   "),
            ("5 组", "AA:BB:CC:DD:EE"),
            ("7 组", "AA:BB:CC:DD:EE:FF:00"),
            ("非十六进制字符", "GG:BB:CC:DD:EE:FF"),
            ("一组只有一位", "A:BB:CC:DD:EE:FF"),
            ("一组三位", "AAA:BB:CC:DD:EE:FF"),
            ("11 位无分隔符", "aabbccddeef"),
            ("13 位无分隔符", "aabbccddeeff0"),
            ("含 0x 前缀", "0xaabbccddeeff"),
            ("冒号减号混用", "AA:BB-CC:DD-EE:FF"),
            ("带点号", "aa.bb.cc.dd.ee.ff"),
            ("末尾多一个冒号", "AA:BB:CC:DD:EE:FF:")
        ]
        for (name, input) in invalidInputs {
            check("非法输入被拒：\(name)", WakeOnLAN.parseMAC(input) == nil,
                  WakeOnLAN.parseMAC(input).map { "解析成了 \($0)" } ?? "")
        }

        // MARK: - 魔术包

        print("\n== 魔术包构造 ==")

        guard let packet = WakeOnLAN.magicPacket(macAddress: "AA:BB:CC:DD:EE:FF") else {
            check("魔术包构造成功", false, "magicPacket 返回 nil")
            report(failures)
            return
        }

        checkEqual("魔术包长度是 102 字节", packet.count, 102)
        checkEqual("常量 packetLength 也是 102", WakeOnLAN.packetLength, 102)

        let bytes = [UInt8](packet)
        checkEqual("前 6 字节全是 0xFF",
                   Array(bytes[0..<6]),
                   [UInt8](repeating: 0xFF, count: 6))

        // 后 96 字节必须是 MAC 重复 16 次，每次 6 字节、顺序不变。
        var repeatedCorrectly = true
        for round in 0..<16 {
            let start = 6 + round * 6
            if Array(bytes[start..<(start + 6)]) != expected {
                repeatedCorrectly = false
                break
            }
        }
        check("后 96 字节是 MAC 重复 16 次", repeatedCorrectly,
              Array(bytes[6..<12]).map { String(format: "%02X", $0) }.joined(separator: ":"))

        checkEqual("MAC 第 1 字节位置正确（不受字节序影响）", bytes[6], 0xAA)
        checkEqual("MAC 第 2 字节位置正确", bytes[7], 0xBB)
        checkEqual("MAC 第 6 字节位置正确", bytes[11], 0xFF)
        checkEqual("最后一次重复的最后一个字节", bytes[101], 0xFF)
        checkEqual("0xFF 前缀之后第一个字节是 MAC 首字节", bytes[6], 0xAA)

        // 小写输入必须产出同一份包 —— 界面上传的是扫描结果，格式由不得用户。
        let lowerPacket = WakeOnLAN.magicPacket(macAddress: "aa:bb:cc:dd:ee:ff")
        check("小写 MAC 产出同一份魔术包", lowerPacket == packet)

        check("非法 MAC 构造魔术包返回 nil",
              WakeOnLAN.magicPacket(macAddress: "not-a-mac") == nil)

        // 换一个 MAC，确认重复的是新 MAC 而不是缓存了上一个。
        if let second = WakeOnLAN.magicPacket(macAddress: "00:11:22:33:44:55") {
            checkEqual("第二个 MAC 的第 1 次重复", Array([UInt8](second)[6..<12]), [0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
            checkEqual("第二个 MAC 的第 16 次重复",
                       Array([UInt8](second)[96..<102]), [0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
        } else {
            check("第二个 MAC 魔术包构造成功", false)
        }

        // MARK: - 错误文案

        print("\n== 错误文案 ==")

        let errors: [WakeOnLANError] = [
            .invalidMAC("zz:zz"),
            .invalidBroadcastAddress("999.1.1.1"),
            .socketFailed("boom"),
            .optionFailed("boom"),
            .sendFailed("boom")
        ]
        for error in errors {
            let localized = error.localizedDescription
            check("文案不是系统默认那句：\(error)",
                  !localized.contains("couldn’t be completed") && !localized.contains("couldn't be completed"),
                  localized)
            check("文案有实际内容：\(error)", !localized.isEmpty, localized)
        }

        // MARK: - 厂商表

        print("\n== 厂商匹配 ==")

        checkEqual("Apple OUI 命中", WakeOnLAN.vendor(forMAC: "A4:83:E7:11:22:33"), "Apple")
        checkEqual("树莓派 OUI 命中", WakeOnLAN.vendor(forMAC: "b8:27:eb:11:22:33"), "Raspberry Pi")
        checkEqual("VMware OUI 命中", WakeOnLAN.vendor(forMAC: "00:0c:29:aa:bb:cc"), "VMware")
        checkEqual("表里没有的 OUI 显示未知厂商",
                   WakeOnLAN.vendor(forMAC: "02:00:00:00:00:01"), WakeOnLAN.unknownVendor)
        checkEqual("非法 MAC 显示未知厂商", WakeOnLAN.vendor(forMAC: "junk"), WakeOnLAN.unknownVendor)

        // MARK: - ARP 输出解析

        print("\n== 经典 arp -a 解析 ==")

        // macOS 的真实格式：`? (ip) at mac on iface ifscope [ethernet]`。
        let classicSample = """
        ? (192.168.1.1) at 3c:22:fb:aa:bb:cc on en0 ifscope [ethernet]
        router.lan (192.168.1.2) at a4:83:e7:11:22:33 on en0 ifscope [ethernet]
        ? (192.168.1.9) at (incomplete) on en0 ifscope [ethernet]

        """
        let classic = NetworkScanner.parseClassicARP(classicSample)
        checkEqual("解析出 2 条（incomplete 被跳过）", classic.count, 2)
        if classic.count == 2 {
            checkEqual("第 1 条 IP", classic[0].ip, "192.168.1.1")
            checkEqual("第 1 条 MAC 归一化成大写", classic[0].mac, "3C:22:FB:AA:BB:CC")
            checkEqual("主机名是 ? 时留空", classic[0].name, "")
            checkEqual("第 2 条 IP", classic[1].ip, "192.168.1.2")
            checkEqual("第 2 条带主机名", classic[1].name, "router.lan")
            checkEqual("第 2 条 MAC", classic[1].mac, "A4:83:E7:11:22:33")
        }
        checkEqual("空输出解析出 0 条", NetworkScanner.parseClassicARP("").count, 0)

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

        // MARK: - 网段推断

        print("\n== 网段推断 ==")

        checkEqual("掩码 255.255.255.0 → /24",
                   LocalIPv4Network.prefixLength(fromNetmask: 0xFFFF_FF00), 24)
        checkEqual("掩码 255.255.0.0 → /16",
                   LocalIPv4Network.prefixLength(fromNetmask: 0xFFFF_0000), 16)
        checkEqual("掩码 255.255.255.192 → /26",
                   LocalIPv4Network.prefixLength(fromNetmask: 0xFFFF_FFC0), 26)

        let network24 = LocalIPv4Network(interfaceName: "en0", address: "192.168.1.64",
                                         prefixLength: 24, broadcastAddress: "192.168.1.255")
        let hosts24 = network24.scanHosts()
        // 254 个可用地址里要扣掉本机自己，所以是 253。
        checkEqual("/24 扫 253 个地址（254 减去本机）", hosts24.count, 253)
        check("自己的地址不在扫描列表里", !hosts24.contains("192.168.1.64"))
        checkEqual("第一个是本网段 .1", hosts24.first ?? "", "192.168.1.1")
        checkEqual("最后一个是 .254", hosts24.last ?? "", "192.168.1.254")

        // /16 也要收窄到 /24，否则一轮要 ping 六万个地址。
        let network16 = LocalIPv4Network(interfaceName: "en0", address: "10.1.2.3",
                                         prefixLength: 16, broadcastAddress: "10.1.255.255")
        let hosts16 = network16.scanHosts()
        checkEqual("/16 被收窄成 /24，只扫 253 个", hosts16.count, 253)
        check("收窄用的是本机所在的 /24", hosts16.contains("10.1.2.1") && hosts16.contains("10.1.2.254"))

        // /26 只能扫 62 个，不能越界扫到隔壁子网。
        let network26 = LocalIPv4Network(interfaceName: "en0", address: "192.168.1.70",
                                         prefixLength: 26, broadcastAddress: "192.168.1.127")
        let hosts26 = network26.scanHosts()
        checkEqual("/26 扫 61 个地址（62 减去本机）", hosts26.count, 61)
        check("/26 不越界到 .128", !hosts26.contains("192.168.1.128"))
        check("/26 起点是 .65", hosts26.first == "192.168.1.65", hosts26.first ?? "nil")

        // MARK: - IP 数值转换

        print("\n== IP 与数值互转（排序用） ==")

        checkEqual("192.168.1.1 的数值", LocalIPv4Network.value(of: "192.168.1.1"), 0xC0A8_0101)
        checkEqual("数值转回 IP", LocalIPv4Network.string(from: 0xC0A8_0101), "192.168.1.1")
        check("非法 IP 数值为 0", LocalIPv4Network.value(of: "999.1.1.1") == 0)
        check("isIPv4 认合法地址", NetworkScanner.isIPv4("192.168.1.1"))
        check("isIPv4 拒非法地址", !NetworkScanner.isIPv4("192.168.1.999"))
        check("isIPv4 拒主机名", !NetworkScanner.isIPv4("router.lan"))

        // MARK: - 设备 id 与合并

        print("\n== 设备 id ==")

        let withMAC = WakeOnLANDevice(ipAddress: "192.168.1.10", macAddress: "AA:BB:CC:DD:EE:FF",
                                      deviceName: "nas.lan", vendor: "Apple")
        checkEqual("有 MAC 时 id 就是 MAC", withMAC.id, "AA:BB:CC:DD:EE:FF")
        check("有 MAC 的设备可唤醒", withMAC.canWake)
        checkEqual("显示名优先用主机名", withMAC.displayName, "nas.lan")

        let withoutMAC = WakeOnLANDevice(ipAddress: "192.168.1.11", macAddress: "",
                                         deviceName: "", vendor: WakeOnLAN.unknownVendor)
        checkEqual("没 MAC 时 id 用 IP 前缀兜底", withoutMAC.id, "ip:192.168.1.11")
        check("没 MAC 的设备不可唤醒", !withoutMAC.canWake)
        checkEqual("没主机名时显示 IP", withoutMAC.displayName, "192.168.1.11")

        // 同一台设备换 IP 还是同一个 id：列表不会因为 DHCP 换址闪一下。
        let moved = WakeOnLANDevice(ipAddress: "192.168.1.99", macAddress: "AA:BB:CC:DD:EE:FF",
                                    deviceName: "", vendor: "Apple")
        checkEqual("换 IP 后 id 不变", moved.id, withMAC.id)

        print("\n== 合并：ARP 与 ping 结果 ==")

        let table: [String: (mac: String, name: String)] = [
            "192.168.1.1": ("3C:22:FB:AA:BB:CC", ""),
            "192.168.1.7": ("A4:83:E7:11:22:33", "nas.lan"),
            "10.0.0.5": ("00:11:22:33:44:55", "")   // 别的网段，不该出现
        ]
        let merged = NetworkScanner.merge(table: table,
                                          alive: ["192.168.1.1", "192.168.1.5"],
                                          network: network24)
        checkEqual("合并后 3 台（.1 / .5 / .7）", merged.count, 3)
        check("本网段的 ARP 条目在列表里", merged.contains { $0.ipAddress == "192.168.1.7" })
        check("只有 ping 回应的设备也在列表里", merged.contains { $0.ipAddress == "192.168.1.5" })
        check("别的网段的 ARP 条目被丢掉", !merged.contains { $0.ipAddress == "10.0.0.5" })
        checkEqual("按 IP 数值排序", merged.map(\.ipAddress),
                   ["192.168.1.1", "192.168.1.5", "192.168.1.7"])
        checkEqual("ARP 带出来的设备按 OUI 对上厂商",
                   merged.first { $0.ipAddress == "192.168.1.7" }?.vendor ?? "", "Apple")
        check("只有 ping 的设备没有 MAC",
              merged.first { $0.ipAddress == "192.168.1.5" }?.macAddress == "")

        report(failures)
    }

    static func report(_ failures: Int) {
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
