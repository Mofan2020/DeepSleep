//
//  WakeOnLANService.swift
//  Deep Sleep
//
//  「网络唤醒」工具的后端：扫局域网里的设备，给指定 MAC 发 WOL 魔术包。
//
//  为什么扫描要两路来源：
//    - ARP 表里是「已经和本机通过信的设备」，带 IP 和 MAC，但没通信过的设备不在里面；
//    - ping 扫段能发现新设备，可 ping 只回 ICMP，不带 MAC。
//    所以顺序是：先读一次 ARP，再并发 ping 整个网段，**扫完再读一次 ARP** ——
//    ping 会触发内核做 ARP 解析，新设备的 MAC 这时才会进表。
//
//  为什么只扫 /24：
//    netmask 可能是 /16 或更小，254 × 256 = 六万多台设备，一轮 ping 下去
//    界面要转几分钟，而且大多数网段根本不归本机管。扫本机所在的 /24 是
//    常见的家用 / 小型办公规模，剩下的交给用户自己换网段再扫。
//
//  为什么发广播可能没效果（这条必须让用户看到，不要藏）：
//    macOS 上从本机往 255.255.255.255 发 UDP 广播，可能被系统防火墙拦掉；
//    就算发出去了，目标设备醒不醒取决于它自己的「唤醒以供网络访问」设置
//    和网卡是否支持。所以这里只承诺「包发出去了」，不承诺「设备会醒」。
//
//  实现选择：
//    - 外部命令一律 Process + 参数数组，不过 shell，不留僵尸进程；
//    - 发魔术包走 BSD socket（SO_BROADCAST + SO_SNDTIMEO），没有第三方依赖；
//    - 构造魔术包是纯函数，可单独测（scripts/test-wol-packet.swift）。
//
//  MAC 从哪来（两路，缺一不可）：
//    - 主路：本进程自己读 `arp -a` / `arp -l -a` 读邻居缓存，一条命令拿全表，最快；
//    - 兜底：主路拿不到 MAC 时，请 root 的特权助手再取一次原文。
//
//  为什么需要兜底（本机实测，macOS 26）：
//  读邻居表能不能成功，取决于进程所处的**本地网络隐私上下文** ——
//  也就是「谁是这个进程的归属应用」。同一台机器上：
//    - 终端 shell / /usr/bin/python3 / /usr/bin/osascript 里跑 `arp -a` → 366 行；
//    - 第三方编译出的裸二进制里跑（哪怕经 bash / python3 中转、经 posix_spawn
//      直接起、经 launchd 上下文起）→ **0 行，退出码 0，不报错**。
//  所以 App 进程自己读邻居表可能读到一张空表 —— 扫到的设备全都只有 IP、
//  发不了魔术包，界面上表现为「扫得到设备但点不动」。
//
//  为什么兜底是「特权助手」而不是别的办法：
//    - 助手是 root 的 LaunchDaemon，不在 App 的本地网络隐私上下文里，能读到；
//    - 走的是已有的 UNIX socket 协议，不用引入新的通信方式；
//    - 助手那条命令**纯只读**（只读内核邻居缓存），不写文件、不改系统状态。
//  助手不认识这条命令时（旧版助手）应用侧优雅降级：本地读到多少算多少，
//  界面上说清楚「助手没帮上忙」还是「还没试过助手」。
//
//  为什么**不再**用 `route -n get <ip>` 取 lladdr（这条路已删）：
//  `route -n get` 在 macOS 26 上**根本不输出 `lladdr:` 那一行** —— 在
//  终端 shell 里跑也不输出，所以任何基于它的解析都是死路。留着只会让界面
//  多等一轮（最多 64 次进程启动、10 秒预算）还拿不到结果。
//  （内核其实知道这些设备的链路层地址：同一个二进制里 `route -n get` 的
//  `flags:` 里带着 `WASCLONED`；路由套接字返回的 sockaddr_dl 里 MAC 也是
//  `02:00:00:00:00:00` 占位符。拿不到真地址的是「让这个进程看见」。）
//

import Foundation
import Darwin

// MARK: - 设备

/// 扫描到的一台设备。
///
/// `id` 用规范化后的 MAC：同一台设备换个 IP 还是同一行，列表不会闪。
/// 拿不到 MAC 的设备（只有 IP 回应了 ping）用 IP 兜底做 id —— 它没法被唤醒，
/// 界面上会标出来，不假装能点。
public struct WakeOnLANDevice: Identifiable, Hashable, Sendable {

    /// 唯一标识。有 MAC 用 MAC，没有就用 `ip:` 前缀的 IP。
    public let id: String
    public var ipAddress: String
    /// 规范化成 `AA:BB:CC:DD:EE:FF`（大写）。没有就是空串。
    public var macAddress: String
    /// ARP 表里的主机名；没有就显示 IP。
    public var deviceName: String
    /// 按 OUI 匹配到的厂商；表里没有就是「未知厂商」。
    public var vendor: String

    public init(ipAddress: String, macAddress: String, deviceName: String, vendor: String) {
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.id = macAddress.isEmpty ? "ip:\(ipAddress)" : macAddress
        self.deviceName = deviceName
        self.vendor = vendor
    }

    /// 有没有 MAC。没有就发不了魔术包。
    public var canWake: Bool { !macAddress.isEmpty }

    /// 设备名兜底：ARP 表里只有 `?` 时显示 IP。
    public var displayName: String { deviceName.isEmpty ? ipAddress : deviceName }
}

// MARK: - 扫描结果摘要

/// 一次扫描的结果摘要。
///
/// 为什么要单独一个类型：「扫到设备但拿不到 MAC」和「什么都没扫到」
/// 是两回事 —— 前者这台 App 读不到本地网络的邻居记录（多半是没给
/// 本地网络权限），后者是真的没有设备在线。界面必须分开说，
/// 不然用户会以为网段里没人。
public struct WoScanSummary: Sendable, Equatable {

    /// 扫到的设备。
    public let devices: [WakeOnLANDevice]
    /// 有 MAC、能发魔术包的设备数。
    public let wakeableCount: Int
    /// 在线但没拿到 MAC 的设备数。
    public let missingMACCount: Int
    /// 这一轮扫描**是否尝试过**「特权助手兜底」。
    ///
    /// 为什么要单独标出来：「还没试过助手」和「试过了、助手也没帮上忙」
    /// 是两回事，界面上该说的话不一样。旧版助手不认识新命令时也算
    /// 「试过了」（试的结果是失败）。
    public let helperFallbackAttempted: Bool
    /// 特权助手兜底**补到了几条** MAC。
    public let helperFallbackRecoveredCount: Int

    /// 现有调用点零改动即可继续编译（后两个参数有默认值）。
    public init(devices: [WakeOnLANDevice],
                helperFallbackAttempted: Bool = false,
                helperFallbackRecoveredCount: Int = 0) {
        self.devices = devices
        self.wakeableCount = devices.filter { $0.canWake }.count
        self.missingMACCount = devices.filter { !$0.canWake }.count
        self.helperFallbackAttempted = helperFallbackAttempted
        self.helperFallbackRecoveredCount = helperFallbackRecoveredCount
    }

    /// 一台都没扫到。
    public var isEmpty: Bool { devices.isEmpty }
    /// 扫到了设备，但一台 MAC 都没拿到 —— 只有 IP，发不了魔术包。
    public var isMissingMACOnly: Bool { !isEmpty && wakeableCount == 0 }
    /// 助手兜底有没有真的补到东西。
    public var didHelperRecover: Bool { helperFallbackRecoveredCount > 0 }
    /// 「助手也试过了、还是没拿到 MAC」—— 界面该在这里说清楚没别的办法了。
    public var isMissingMACAfterHelper: Bool {
        missingMACCount > 0 && helperFallbackAttempted && !didHelperRecover
    }
}

// MARK: - 邻居表原始文本

/// 特权助手回传的邻居表原始文本。
///
/// 只是三段原文，**没有任何解析结果** —— 解析在 `NetworkScanner` 那几个
/// `parse*` 纯函数里做，好处是：
///   - 解析逻辑能被普通权限的单测直接覆盖（不需要 root、不需要网络）；
///   - 助手那边不碰任何格式判断，格式变了只改应用侧一处。
public struct WoNeighborTablePayload: Sendable, Equatable {
    /// `/usr/sbin/arp -a` 的输出。
    public let arp: String
    /// `/usr/sbin/arp -l -a` 的输出。
    public let neighbor: String
    /// `/usr/sbin/netstat -rn -f inet` 的输出。
    public let routes: String

    public init(arp: String, neighbor: String, routes: String) {
        self.arp = arp
        self.neighbor = neighbor
        self.routes = routes
    }

    /// 三段原文里有没有任何一行。
    public var isEmpty: Bool {
        arp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && neighbor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && routes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 一轮扫描的结果：设备列表 + 助手兜底的情况。
///
/// 单独一个类型是因为界面需要同时知道「拿到了几台设备的 MAC」和
/// 「没拿到的时候有没有试过特权助手兜底」—— 后者决定了界面该说
/// 「正在想办法」还是「助手也没帮上忙」。
public struct WoScanOutcome: Sendable {
    public let devices: [WakeOnLANDevice]
    /// 是否尝试过特权助手兜底。
    public let helperFallbackAttempted: Bool
    /// 助手兜底补到了几条 MAC。
    public let helperFallbackRecoveredCount: Int

    public init(devices: [WakeOnLANDevice],
                helperFallbackAttempted: Bool = false,
                helperFallbackRecoveredCount: Int = 0) {
        self.devices = devices
        self.helperFallbackAttempted = helperFallbackAttempted
        self.helperFallbackRecoveredCount = helperFallbackRecoveredCount
    }

    /// 转成给界面用的摘要。
    public func summary() -> WoScanSummary {
        WoScanSummary(devices: devices,
                      helperFallbackAttempted: helperFallbackAttempted,
                      helperFallbackRecoveredCount: helperFallbackRecoveredCount)
    }
}

// MARK: - 错误

public enum WakeOnLANError: Error, LocalizedError, CustomStringConvertible {

    /// MAC 写法不对。`raw` 是用户 / 扫描结果给的原样字符串。
    case invalidMAC(String)
    /// 广播地址不是合法的 IPv4 点分写法。
    case invalidBroadcastAddress(String)
    /// socket 创建失败。
    case socketFailed(String)
    /// setsockopt 失败（一般是没权限开广播）。
    case optionFailed(String)
    /// sendto 失败。
    case sendFailed(String)

    public var description: String {
        switch self {
        case .invalidMAC(let raw):
            let shown = raw.isEmpty ? "（空）" : raw
            return "MAC 地址格式不对：\(shown)。支持 AA:BB:CC:DD:EE:FF、AA-BB-CC-DD-EE-FF、AABBCCDDEEFF 三种写法。"
        case .invalidBroadcastAddress(let raw):
            return "广播地址不对：\(raw)。要填 IPv4 点分地址，比如 255.255.255.255。"
        case .socketFailed(let message):
            return "创建 UDP socket 失败：\(message)"
        case .optionFailed(let message):
            return "设置 socket 选项失败：\(message)"
        case .sendFailed(let message):
            return "魔术包没发出去：\(message)"
        }
    }

    /// 界面上用 `localizedDescription` 显示，必须实现 —— 否则用户只看到系统那句
    /// 「操作无法完成」，不知道到底哪里错了。
    public var errorDescription: String? { description }
}

// MARK: - 魔术包与发送

public enum WakeOnLAN {

    /// 魔术包里 0xFF 的前缀长度。
    public static let syncLength = 6
    /// MAC 重复次数。
    public static let repeatCount = 16
    /// 魔术包总长度：6 + 16 × 6 = 102。
    public static let packetLength = syncLength + repeatCount * 6

    /// 默认端口。9 是 discard，7 是 echo，两种设备都常见。
    public static let defaultPort: UInt16 = 9
    /// 默认广播地址。
    public static let defaultBroadcastAddress = "255.255.255.255"

    // MARK: MAC 解析（纯函数）

    /// 解析 MAC。接受三种写法，大小写都行，两边空白忽略：
    ///
    ///     AA:BB:CC:DD:EE:FF
    ///     AA-BB-CC-DD-EE-FF
    ///     aabbccddeeff
    ///
    /// 别的写法一律返回 nil —— 不猜、不补零、不截断。
    public static func parseMAC(_ raw: String) -> [UInt8]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 先决定分隔符：冒号、减号，或者没有分隔符。
        let separator: Character?
        if trimmed.contains(":") {
            separator = ":"
        } else if trimmed.contains("-") {
            separator = "-"
        } else {
            separator = nil
        }

        let groups: [String]
        if let separator {
            let parts = trimmed.split(separator: separator, omittingEmptySubsequences: false)
            guard parts.count == 6 else { return nil }
            // 冒号和减号混着用的写法不接受：那样 split 出来的组里还带别的分隔符，
            // 下面的十六进制校验会把它挡掉。
            groups = parts.map(String.init)
        } else {
            guard trimmed.count == 12 else { return nil }
            groups = stride(from: 0, to: 12, by: 2).map { offset in
                let start = trimmed.index(trimmed.startIndex, offsetBy: offset)
                let end = trimmed.index(start, offsetBy: 2)
                return String(trimmed[start..<end])
            }
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(6)
        for group in groups {
            guard group.count == 2,
                  group.allSatisfy({ $0.isHexDigit }),
                  let value = UInt8(group, radix: 16) else {
                return nil
            }
            bytes.append(value)
        }
        return bytes.count == 6 ? bytes : nil
    }

    /// 规范化写法：`AA:BB:CC:DD:EE:FF`（大写）。解析不了返回 nil。
    public static func normalizedMAC(_ raw: String) -> String? {
        guard let bytes = parseMAC(raw) else { return nil }
        return formatMAC(bytes)
    }

    /// 字节数组 → `AA:BB:CC:DD:EE:FF`。
    public static func formatMAC(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: 魔术包（纯函数）

    /// 构造魔术包：6 个 0xFF + MAC 重复 16 次，共 102 字节。
    /// MAC 解析不了就返回 nil（调用方自己决定怎么提示）。
    public static func magicPacket(macAddress: String) -> Data? {
        guard let mac = parseMAC(macAddress) else { return nil }
        var packet = Data(capacity: packetLength)
        packet.append(contentsOf: [UInt8](repeating: 0xFF, count: syncLength))
        for _ in 0..<repeatCount {
            packet.append(contentsOf: mac)
        }
        return packet
    }

    // MARK: 发送

    /// 发一个魔术包。
    ///
    /// - Parameters:
    ///   - macAddress: 目标 MAC，三种写法都行。
    ///   - port: 目标端口，默认 9（7 也常见）。
    ///   - broadcastAddress: 广播地址，默认 255.255.255.255。
    ///
    /// **返回不代表目标醒了** —— 只代表 sendto 把 102 字节交给了内核。
    /// 广播包可能被本机防火墙拦掉，目标设备也可能没开 WOL。
    public static func send(
        macAddress: String,
        port: UInt16 = defaultPort,
        broadcastAddress: String = defaultBroadcastAddress
    ) throws {
        guard let packet = magicPacket(macAddress: macAddress) else {
            throw WakeOnLANError.invalidMAC(macAddress)
        }

        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        // 端口是网络字节序；广播包的端口没有协商过程，写死即可。
        target.sin_port = port.bigEndian
        let parsed = broadcastAddress.withCString { inet_pton(AF_INET, $0, &target.sin_addr) }
        guard parsed == 1 else {
            throw WakeOnLANError.invalidBroadcastAddress(broadcastAddress)
        }

        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw WakeOnLANError.socketFailed(String(cString: strerror(errno)))
        }
        defer { close(descriptor) }

        var enable: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST,
                         &enable, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw WakeOnLANError.optionFailed(String(cString: strerror(errno)))
        }

        // UDP 的 sendto 一般不会卡，但网卡排队满的时候也可能阻塞，给个上限。
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO,
                   &timeout, socklen_t(MemoryLayout<timeval>.size))

        let sent = packet.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(descriptor, raw.baseAddress, raw.count, 0,
                           address, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard sent == packet.count else {
            let reason = sent < 0 ? String(cString: strerror(errno)) : "只发出 \(sent) 字节（应发 \(packet.count) 字节）"
            throw WakeOnLANError.sendFailed(reason)
        }
    }

    // MARK: 厂商（OUI）

    /// 内置的常见厂商表，键是 MAC 前 3 字节。
    ///
    /// 只收「确定对得上」的 OUI：宁可显示「未知厂商」，也不瞎猜 ——
    /// 猜错比不猜更糟，用户会拿它当依据去操作设备。
    static let ouiTable: [String: String] = [
        // 虚拟化 / 网络设备
        "00:50:56": "VMware",
        "00:0C:29": "VMware",
        "00:05:69": "VMware",
        "00:1C:14": "VMware",
        "08:00:27": "VirtualBox",
        "52:54:00": "QEMU",
        "00:15:5D": "Microsoft (Hyper-V)",
        "00:16:3E": "Xen",
        "00:1C:42": "Parallels",
        // Apple
        "00:03:93": "Apple",
        "00:0A:27": "Apple",
        "00:1B:63": "Apple",
        "00:1E:C2": "Apple",
        "3C:07:54": "Apple",
        "8C:85:90": "Apple",
        "A4:83:E7": "Apple",
        "F0:18:98": "Apple",
        // 树莓派
        "B8:27:EB": "Raspberry Pi",
        "DC:A6:32": "Raspberry Pi",
        "E4:5F:01": "Raspberry Pi",
        // Google / Nest
        "00:1A:11": "Google",
        "3C:5A:B4": "Google",
        "44:07:0B": "Google",
        "F4:F5:D8": "Google",
        "18:B4:30": "Nest",
        "64:16:66": "Nest",
        // 手机 / 平板 / 穿戴
        "00:12:FB": "Samsung",
        "00:15:99": "Samsung",
        "00:16:32": "Samsung",
        "00:1D:25": "Samsung",
        "00:1E:75": "LG Electronics",
        "00:1C:62": "LG Electronics",
        "64:09:80": "Xiaomi",
        "78:11:DC": "Xiaomi",
        "8C:BE:BE": "Xiaomi",
        "F0:B4:29": "Xiaomi",
        "00:E0:FC": "Huawei",
        "00:18:82": "Huawei",
        "28:6E:D4": "Huawei",
        "48:46:FB": "Huawei",
        "70:72:3C": "Huawei",
        "7C:1E:52": "Microsoft",
        "00:13:A9": "Sony",
        "00:09:BF": "Nintendo",
        // 网络设备 / 路由
        "00:1D:0F": "TP-Link",
        "14:CC:20": "TP-Link",
        "50:C7:BF": "TP-Link",
        "00:09:5B": "Netgear",
        "00:14:6C": "Netgear",
        "A0:40:A0": "Netgear",
        "00:0D:88": "D-Link",
        "00:1B:11": "D-Link",
        "1C:7E:E5": "D-Link",
        "00:15:6D": "Ubiquiti",
        "24:A4:3C": "Ubiquiti",
        "F0:9F:C2": "Ubiquiti",
        "00:0C:42": "MikroTik",
        "4C:5E:0C": "MikroTik",
        "00:00:0C": "Cisco",
        "00:1A:A1": "Cisco",
        "00:11:32": "Synology",
        "00:10:18": "Broadcom",
        "00:E0:4C": "Realtek",
        // 电脑 / 外设
        "00:1B:21": "Intel",
        "00:1E:64": "Intel",
        "00:1E:67": "Intel",
        "3C:A9:F4": "Intel",
        "00:14:22": "Dell",
        "00:1C:23": "Dell",
        "00:21:9B": "Dell",
        "18:03:73": "Dell",
        "F8:BC:12": "Dell",
        "00:1B:78": "HP",
        "00:1F:29": "HP",
        "3C:D9:2B": "HP",
        "00:1B:FC": "ASUS",
        "00:24:8C": "ASUS",
        "2C:56:DC": "ASUS",
        // 智能家居 / 物联网
        "00:0E:58": "Sonos",
        "48:A6:B8": "Sonos",
        "5C:AA:FD": "Sonos",
        "00:17:88": "Philips Hue",
        "EC:B5:FA": "Philips Hue",
        "54:EF:44": "Aqara",
        "7C:49:EB": "Aqara",
        "2C:AA:8E": "Wyze",
        "44:65:0D": "Amazon",
        "68:37:E9": "Amazon",
        "F0:27:2D": "Amazon",
        "24:0A:C4": "Espressif",
        "3C:71:BF": "Espressif",
        "84:F3:EB": "Espressif",
        "A4:CF:12": "Espressif",
        "CC:50:E3": "Espressif"
    ]

    /// 按 MAC 查厂商。查不到返回「未知厂商」，不猜。
    static func vendor(forMAC mac: String) -> String {
        guard let bytes = parseMAC(mac), bytes.count == 6 else { return unknownVendor }
        let key = String(format: "%02X:%02X:%02X", bytes[0], bytes[1], bytes[2])
        return ouiTable[key] ?? unknownVendor
    }

    static let unknownVendor = "未知厂商"
}

// MARK: - 本机网络

/// 本机的 IPv4 网段。扫描只用它推断范围。
struct LocalIPv4Network {
    let interfaceName: String
    let address: String
    let prefixLength: Int
    /// 子网广播地址（不是 255.255.255.255，是本网段的那个）。
    let broadcastAddress: String

    /// 要 ping 的地址。网段比 /24 大就只取本机所在的 /24；比 /24 小就按实际范围。
    func scanHosts() -> [String] {
        guard prefixLength < 32 else { return [] }

        // 网段比 /24 大（前缀更小）时收窄到本机的 /24：六万多台设备扫不动，也不是本机的网段。
        let effectivePrefix = max(prefixLength, 24)
        let effectiveMask: UInt32 = effectivePrefix >= 32 ? 0xFFFF_FFFF : (0xFFFF_FFFF << (32 - UInt32(effectivePrefix)))

        let base = LocalIPv4Network.value(of: address) & effectiveMask
        let hostBits = 32 - UInt32(effectivePrefix)
        // /24 及更大的网段固定 1…254；/25、/26 这类更小的网段按实际主机数算，
        // 去掉网络地址和广播地址。
        let count = hostBits >= 8 ? 254 : Int((1 << hostBits) - 2)
        guard count > 0 else { return [] }

        let own = LocalIPv4Network.value(of: address)
        var hosts: [String] = []
        hosts.reserveCapacity(count)
        for offset in 1...count {
            let value = base &+ UInt32(offset)
            if value == own { continue }
            hosts.append(LocalIPv4Network.string(from: value))
        }
        return hosts
    }

    static func value(of ip: String) -> UInt32 {
        var address = in_addr()
        guard inet_pton(AF_INET, ip, &address) == 1 else { return 0 }
        return UInt32(bigEndian: address.s_addr)
    }

    static func string(from value: UInt32) -> String {
        var address = in_addr(s_addr: value.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    /// netmask 的位数：`255.255.255.0` → 24。只数连续的前导 1 —— 非连续掩码是非法配置，
    /// 数到第一个 0 为止，后面的位不再算。
    static func prefixLength(fromNetmask netmask: UInt32) -> Int {
        var bits = 0
        var mask = netmask
        while mask & 0x8000_0000 != 0 {
            bits += 1
            mask <<= 1
        }
        return bits
    }
}

// MARK: - 扫描器

/// 局域网扫描。
///
/// 状态（是否在扫、进度、提示文字）放在主线程上，阻塞的活全部丢到后台队列 ——
/// 扫一轮 /24 要 ping 254 个地址，放在主线程上界面会整片卡死。
@MainActor
public final class NetworkScanner {

    public static let shared = NetworkScanner()

    /// 当前是否在扫。
    public private(set) var isScanning = false
    /// 0…1 的进度。
    public private(set) var progress: Double = 0
    /// 给界面看的一句话状态。
    public private(set) var statusText = ""
    /// 进度变化回调。界面把它转成自己的 @State，避免为了进度引入额外依赖。
    public var onUpdate: ((Double, String) -> Void)?

    /// 最近一轮扫描**是否尝试过**特权助手兜底。
    ///
    /// 界面靠它区分「还没试过助手」和「试过了、助手也没帮上忙」——
    /// 这两种情况该给用户看的话不一样。
    public private(set) var lastHelperFallbackAttempted = false
    /// 最近一轮扫描，助手兜底**补到了几条** MAC。
    public private(set) var lastHelperFallbackRecoveredCount = 0

    /// 扫描代号。进度回调要跨回主线程，晚到的旧回调不能把新一轮的状态改回去。
    private var generation = 0

    /// 并发 ping 的数量。64 路在 /24 上一轮七八秒能扫完；再高对家用路由是压力。
    ///
    /// `nonisolated`：这三个常量被 nonisolated 的扫描函数读，标了 @MainActor 的话
    /// Swift 6 会把这种跨 actor 读当错误。
    nonisolated static let pingConcurrency = 64
    /// 单次 ping 等回包的毫秒数。太低会把慢设备漏掉，太高会让整轮变慢。
    nonisolated static let pingTimeoutMilliseconds = 500
    /// ping 进程本身的硬上限（秒）。`-W` 只控制等回包，进程启动异常时靠这个兜底。
    nonisolated static let pingProcessTimeout: TimeInterval = 2.5

    private init() {}

    /// 扫当前网段。返回按 IP 排序的设备列表。
    ///
    /// 扫的过程中 `progress` / `statusText` 会持续更新；扫完 `isScanning` 回到 false。
    ///
    /// 助手兜底的情况记在 `lastHelperFallbackAttempted` /
    /// `lastHelperFallbackRecoveredCount` 里 —— 界面要靠它区分
    /// 「还没试过助手」和「试过了、助手也没帮上忙」。
    public func scan() async -> [WakeOnLANDevice] {
        guard !isScanning else { return [] }
        isScanning = true
        generation += 1
        let current = generation
        report(0, "正在读取本机网络信息…")
        defer { isScanning = false }

        let outcome = await NetworkScanner.performScan { [weak self] fraction, text in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.report(fraction, text)
            }
        }
        lastHelperFallbackAttempted = outcome.helperFallbackAttempted
        lastHelperFallbackRecoveredCount = outcome.helperFallbackRecoveredCount
        report(1, outcome.devices.isEmpty ? "没有扫到设备。" : "扫描完成，共 \(outcome.devices.count) 台设备。")
        return outcome.devices
    }

    private func report(_ fraction: Double, _ text: String) {
        progress = min(max(fraction, 0), 1)
        statusText = text
        onUpdate?(progress, text)
    }

    // MARK: 扫描流程（不碰主线程）

    /// 真正的扫描。nonisolated：整个流程跑在后台，只通过回调用报进度。
    nonisolated static func performScan(
        progress: @escaping @Sendable (Double, String) -> Void
    ) async -> WoScanOutcome {

        guard let network = localNetwork() else {
            progress(1, "读不到本机 IPv4 地址，无法扫描。")
            return WoScanOutcome(devices: [])
        }

        // 第一遍 ARP：已经通信过的设备，先收进来，界面能尽早点亮一部分。
        var table = await readARPTable()
        progress(0.06, "已读到 \(table.count) 条 ARP 记录，正在扫描 \(network.address)/\(network.prefixLength)…")

        let hosts = network.scanHosts()
        guard !hosts.isEmpty else {
            progress(1, "本机网段内没有可扫的地址。")
            return WoScanOutcome(devices: merge(table: table, alive: [], network: network))
        }

        let alive = await pingSweep(hosts: hosts) { done in
            let fraction = 0.06 + 0.88 * (Double(done) / Double(hosts.count))
            progress(fraction, "正在扫描… \(done)/\(hosts.count)")
        }

        // 第二遍 ARP：ping 触发过解析，新设备这时才带 MAC 出现在表里。
        progress(0.96, "扫描完成，正在读取 ARP 表…")
        table = await readARPTable()

        // 兜底：本地读邻居表可能读到一张空表（本地网络隐私上下文）。
        // 这时问 root 的特权助手再取一次原文，用同一套解析函数解析后合并。
        let missingCount = alive.filter { table[$0]?.mac.isEmpty ?? true }.count
        if missingCount > 0 {
            progress(0.97, "扫描完成，正在通过特权助手补齐设备 MAC…")
        }
        let fallback = await applyHelperFallback(table: table, alive: alive)
        table = fallback.table

        progress(0.99, "扫描完成，正在整理设备…")
        return WoScanOutcome(
            devices: merge(table: table, alive: alive, network: network),
            helperFallbackAttempted: fallback.attempted,
            helperFallbackRecoveredCount: fallback.recoveredCount
        )
    }

    /// 读本机 IPv4 网段。
    ///
    /// 用 `getifaddrs`（与 `ifconfig` 同一个数据来源）：不用起进程、不用解析文本，
    /// 掩码和地址都是内核直接给的。优先挑有默认路由的那块网卡 —— 家用机同时开着
    /// VPN / 虚拟机桥接时，en0 以外的网段扫了也没意义。
    nonisolated static func localNetwork() -> LocalIPv4Network? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [LocalIPv4Network] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            // 回环、未启用、点对点（VPN 的 utun）、链路本地 169.254 都不算局域网。
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_POINTOPOINT == 0,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  let maskPointer = current.pointee.ifa_netmask else { continue }

            let name = String(cString: current.pointee.ifa_name)
            let address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var value = sin.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buffer)
            }
            guard !address.isEmpty, !address.hasPrefix("169.254.") else { continue }

            let netmask = maskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                UInt32(bigEndian: sin.pointee.sin_addr.s_addr)
            }
            let prefix = LocalIPv4Network.prefixLength(fromNetmask: netmask)
            guard prefix > 0, prefix <= 30 else { continue }

            let ipValue = LocalIPv4Network.value(of: address)
            let broadcastValue = ipValue | ~netmask
            candidates.append(LocalIPv4Network(
                interfaceName: name,
                address: address,
                prefixLength: prefix,
                broadcastAddress: LocalIPv4Network.string(from: broadcastValue)
            ))
        }

        guard !candidates.isEmpty else { return nil }
        // en0 是 Mac 的主网卡，有就优先用它。
        if let ethernet = candidates.first(where: { $0.interfaceName == "en0" }) {
            return ethernet
        }
        return candidates.first
    }

    /// 并发 ping 整个网段，返回回应了的地址。
    ///
    /// 用 TaskGroup 控制同时在跑的数量：一次把 254 个 ping 全拉起来会顶到进程数上限，
    /// 串行又太慢。
    nonisolated static func pingSweep(
        hosts: [String],
        onProgress: @escaping @Sendable (Int) -> Void
    ) async -> Set<String> {
        var alive = Set<String>()
        var completed = 0

        await withTaskGroup(of: (String, Bool).self) { group in
            var iterator = hosts.makeIterator()
            // 先把并发槽填满，之后完成一个补一个 —— 始终维持 pingConcurrency 路在跑。
            for _ in 0..<pingConcurrency {
                guard let host = iterator.next() else { break }
                group.addTask { (host, await pingOnce(host)) }
            }

            while let (host, ok) = await group.next() {
                completed += 1
                onProgress(completed)
                if ok { alive.insert(host) }
                if let next = iterator.next() {
                    group.addTask { (next, await pingOnce(next)) }
                }
            }
        }

        return alive
    }

    /// ping 一次。回包就算活。
    nonisolated static func pingOnce(_ host: String) async -> Bool {
        let result = await run(
            "/sbin/ping",
            ["-c", "1", "-W", "\(pingTimeoutMilliseconds)", "-t", "2", host],
            timeout: pingProcessTimeout
        )
        return result.status == 0
    }

    // MARK: ARP

    /// 读 ARP 表，返回 IP → (MAC, 主机名)。
    ///
    /// 读两种格式，因为 macOS 版本不同：
    ///   - 经典 `arp -a`：`? (192.168.1.1) at 3c:22:fb:aa:bb:cc on en0 ifscope [ethernet]`
    ///   - 新版邻居表 `arp -l -a`（macOS 26 起）：表头是
    ///     `Neighbor  Linklayer Address  Expire(O) ...`，一行一条。
    /// 两个都读，按 IP 合并，谁先有 MAC 用谁。
    nonisolated static func readARPTable() async -> [String: (mac: String, name: String)] {
        var table: [String: (mac: String, name: String)] = [:]

        let classic = await run("/usr/sbin/arp", ["-a"], timeout: 5)
        for entry in parseClassicARP(classic.stdout) {
            table[entry.ip] = (entry.mac, entry.name)
        }

        let neighbors = await run("/usr/sbin/arp", ["-l", "-a"], timeout: 5)
        for entry in parseNeighborTable(neighbors.stdout) {
            if table[entry.ip] == nil || table[entry.ip]?.mac.isEmpty == true {
                table[entry.ip] = (entry.mac, table[entry.ip]?.name ?? entry.name)
            }
        }

        return table
    }

    /// 解析经典 `arp -a` 输出。
    ///
    /// 样本（macOS 实测格式）：
    ///
    ///     ? (192.168.1.1) at 3c:22:fb:aa:bb:cc on en0 ifscope [ethernet]
    ///     router.lan (192.168.1.2) at a4:83:e7:11:22:33 on en0 ifscope [ethernet]
    ///     ? (192.168.1.9) at (incomplete) on en0 ifscope [ethernet]
    ///
    /// `(incomplete)` 表示解析没成功，没有 MAC，跳过。
    nonisolated static func parseClassicARP(_ text: String) -> [(ip: String, mac: String, name: String)] {
        var entries: [(ip: String, mac: String, name: String)] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let open = line.firstIndex(of: "("),
                  let close = line[open...].firstIndex(of: ")") else { continue }

            let namePart = line[line.startIndex..<open].trimmingCharacters(in: .whitespaces)
            let ip = String(line[line.index(after: open)..<close])
            guard isIPv4(ip) else { continue }

            // "at" 之后、空格之前就是 MAC（可能是 `(incomplete)`）。
            let rest = line[line.index(after: close)...]
            guard let atRange = rest.range(of: " at ") else { continue }
            let afterAt = rest[atRange.upperBound...]
            let macToken = String(afterAt.prefix(while: { $0 != " " }))
            guard let mac = WakeOnLAN.normalizedMAC(macToken) else { continue }

            entries.append((ip, mac, namePart == "?" ? "" : namePart))
        }

        return entries
    }

    /// 解析 `arp -l -a` 的邻居表。
    ///
    /// 表头：
    ///
    ///     Neighbor   Linklayer Address  Expire(O) Expire(I)  Netif Refs Prbs
    ///     192.168.1.1  3c:22:fb:aa:bb:cc  1180  1180  en0  1
    ///
    /// Neighbor 列可能是个 IP，也可能是主机名；主机名的情况下取不到 IP，
    /// 这一行就没法用（本工具以 IP 为准）。
    nonisolated static func parseNeighborTable(_ text: String) -> [(ip: String, mac: String, name: String)] {
        var entries: [(ip: String, mac: String, name: String)] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("Neighbor") else { continue }

            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { continue }

            let neighbor = fields[0]
            guard isIPv4(neighbor) else { continue }
            guard fields[1].contains(":") || fields[1].count == 12 else { continue }
            guard let mac = WakeOnLAN.normalizedMAC(fields[1]) else { continue }

            entries.append((neighbor, mac, ""))
        }

        return entries
    }

    // MARK: - 路由表里的邻居条目（netstat）

    /// 解析 `netstat -rn -f inet` 里的邻居条目。
    ///
    /// 样本（macOS 26 实测）：
    ///
    ///     Routing tables
    ///
    ///     Internet:
    ///     Destination        Gateway            Flags        Netif Expire
    ///     default            192.168.1.1        UGSc           en0
    ///     192.168.1          link#11            UCS            en0        !
    ///     192.168.1/32       link#11            UCS            en0        !
    ///     192.168.1.1        ec:e7:c2:9f:49:a1  UHLWIir        en0   1180
    ///     192.168.1.2        link#21            UHLWIg     bridge100   !
    ///
    /// 第 1 列是目标，第 2 列是链路层地址 —— **只有主机路由的第 2 列才是 MAC**。
    /// 所以规则是：
    ///   - 第 1 列必须是纯 IPv4。`192.168.1.1/32`（主机路由）、`192.168.1`
    ///     （网段路由）、`default` 都不是邻居，跳过；
    ///   - 第 2 列必须能解析成 MAC。`link#21`（接口号）、网关 IP、主机名
    ///     都解析不出来，跳过。
    ///
    /// 这一路是**补充**来源：ARP 表读不到时，路由表里往往还留着邻居条目。
    nonisolated static func parseNetstatNeighbors(_ text: String) -> [(ip: String, mac: String, name: String)] {
        var entries: [(ip: String, mac: String, name: String)] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { continue }

            // 第 1 列：必须是纯 IPv4（带斜杠、带前缀的都不是邻居条目）。
            let destination = fields[0]
            guard isIPv4(destination) else { continue }

            // 第 2 列：只有 MAC 才算数。
            guard let mac = WakeOnLAN.normalizedMAC(fields[1]) else { continue }

            entries.append((destination, mac, ""))
        }

        return entries
    }

    // MARK: - 特权助手兜底

    /// 助手兜底的结果。
    struct WoHelperFallbackResult {
        /// 合并之后的邻居表。
        let table: [String: (mac: String, name: String)]
        /// 是否真的去问过助手。
        let attempted: Bool
        /// 助手补到了几条 MAC。
        let recoveredCount: Int
    }

    /// 助手不认识这条命令（旧版本）时置位，之后不再白跑一趟。
    private nonisolated(unsafe) static var helperLacksNeighborCommand = false

    /// 问助手要邻居表的超时（秒）。
    ///
    /// 助手那边只是跑三条只读命令，正常是毫秒级的；10 秒是给系统慢 /
    /// 助手刚好在重启兜底的。
    nonisolated static let helperNeighborTimeout: TimeInterval = 10

    /// 用特权助手补齐在线设备缺失的 MAC。
    ///
    /// 只在**主路确实缺 MAC** 时才走：在线设备里还有拿不到 MAC 的，
    /// 才值得去问助手一趟。全都拿到了还去问，就是白跑一次进程。
    ///
    /// 助手那边只有一条只读命令（`readNeighborTable`），返回的是**原文**；
    /// 解析用的是和主路完全相同的那几个纯函数，所以两条路不会解析出
    /// 不一样的结果。
    nonisolated static func applyHelperFallback(
        table: [String: (mac: String, name: String)],
        alive: Set<String>
    ) async -> WoHelperFallbackResult {
        let missing = alive.filter { table[$0]?.mac.isEmpty ?? true }
        // 主路已经齐了：没缺的不去打扰助手。
        guard !missing.isEmpty else {
            return WoHelperFallbackResult(table: table, attempted: false, recoveredCount: 0)
        }

        guard let payload = await fetchNeighborTableViaHelper() else {
            // 试过了，但没拿到（助手没装 / 版本太旧 / 助手不可达）。
            return WoHelperFallbackResult(table: table, attempted: true, recoveredCount: 0)
        }

        let remote = parseNeighborTablePayload(payload)
        let merged = mergeNeighborTables(local: table, remote: remote)
        let recovered = missing.filter { !(merged[$0]?.mac.isEmpty ?? true) }.count
        return WoHelperFallbackResult(table: merged, attempted: true, recoveredCount: recovered)
    }

    /// 通过特权助手读一次邻居表原文。
    ///
    /// 失败时返回 nil，不抛错：助手是**可选**路径，没装助手、助手是旧版、
    /// 助手没跑起来，都不该让整次扫描失败。
    nonisolated static func fetchNeighborTableViaHelper() async -> WoNeighborTablePayload? {
        guard !helperLacksNeighborCommand else { return nil }

        do {
            let response = try await HelperClient.shared.send(
                .init(command: .readNeighborTable),
                timeout: helperNeighborTimeout
            )
            guard response.success else {
                if response.message.localizedCaseInsensitiveContains("unknown command") {
                    // 旧版助手：别再白跑一趟（和 ThermalMonitor 对温度命令的处理一样）。
                    helperLacksNeighborCommand = true
                    NSLog("[DeepSleep] 助手不支持邻居表命令（旧版本），MAC 兜底已降级")
                } else {
                    NSLog("[DeepSleep] 通过助手读取邻居表失败：%@", response.message)
                }
                return nil
            }
            let payload = WoNeighborTablePayload(
                arp: response.payload["arp"] ?? "",
                neighbor: response.payload["neighbor"] ?? "",
                routes: response.payload["routes"] ?? ""
            )
            return payload.isEmpty ? nil : payload
        } catch {
            NSLog("[DeepSleep] 特权助手不可用（读取邻居表失败）：%@", error.localizedDescription)
            return nil
        }
    }

    /// 把助手回传的原文解析成邻居表。
    ///
    /// 三段原文各走各的解析函数，但**用的是和主路同一批函数** ——
    /// 助手那边不做任何格式判断，格式变了只改这一处。
    nonisolated static func parseNeighborTablePayload(
        _ payload: WoNeighborTablePayload
    ) -> [String: (mac: String, name: String)] {
        var table: [String: (mac: String, name: String)] = [:]

        for entry in parseClassicARP(payload.arp) {
            table[entry.ip] = (entry.mac, entry.name)
        }
        for entry in parseNeighborTable(payload.neighbor) {
            if table[entry.ip] == nil || table[entry.ip]?.mac.isEmpty == true {
                table[entry.ip] = (entry.mac, table[entry.ip]?.name ?? entry.name)
            }
        }
        for entry in parseNetstatNeighbors(payload.routes) {
            if table[entry.ip] == nil || table[entry.ip]?.mac.isEmpty == true {
                table[entry.ip] = (entry.mac, table[entry.ip]?.name ?? entry.name)
            }
        }

        return table
    }

    /// 合并两张邻居表：**本地已有的 MAC 不动**，只补空缺。
    ///
    /// 不覆盖本地已有的 MAC：本地表是这一轮扫描刚读到的，更贴近当下；
    /// 助手的表可能是几秒前的快照。
    nonisolated static func mergeNeighborTables(
        local: [String: (mac: String, name: String)],
        remote: [String: (mac: String, name: String)]
    ) -> [String: (mac: String, name: String)] {
        var merged = local
        for (ip, entry) in remote {
            let existing = merged[ip]
            if let existing, !existing.mac.isEmpty {
                // 本地已经有 MAC：只补名字（本地没名字、助手有名字的情况）。
                if existing.name.isEmpty && !entry.name.isEmpty {
                    merged[ip] = (existing.mac, entry.name)
                }
                continue
            }
            let localName = existing?.name ?? ""
            let name = localName.isEmpty ? entry.name : localName
            merged[ip] = (entry.mac, name)
        }
        return merged
    }

    // MARK: 合并

    /// ARP 表（有 MAC）和 ping 结果（可能有 MAC、可能只有 IP）合并成设备列表。
    ///
    /// 只保留本网段内的地址：ARP 表里有别的网卡的条目（比如虚拟机的桥接网段），
    /// 那些不是「当前连接的网络」上的设备。
    nonisolated static func merge(
        table: [String: (mac: String, name: String)],
        alive: Set<String>,
        network: LocalIPv4Network
    ) -> [WakeOnLANDevice] {
        let hosts = Set(network.scanHosts())
        var result: [WakeOnLANDevice] = []
        var seen = Set<String>()

        // 先放有 MAC 的：ARP 表里在本网段内的条目（不管这次有没有 ping 通，
        // 它确实在这个网段上，用户可能就想唤醒那台睡着的机器）。
        for (ip, entry) in table where hosts.contains(ip) {
            // 只有 IP、没有 MAC 的条目交给下面那条处理（它发不了魔术包）。
            guard !entry.mac.isEmpty else { continue }
            guard !seen.contains(entry.mac) else { continue }
            seen.insert(entry.mac)
            result.append(WakeOnLANDevice(
                ipAddress: ip,
                macAddress: entry.mac,
                deviceName: entry.name.isEmpty ? ip : entry.name,
                vendor: WakeOnLAN.vendor(forMAC: entry.mac)
            ))
        }

        // 再放只有 IP 的：ping 有回应但 ARP 表里没 MAC。
        for ip in alive where hosts.contains(ip) {
            // 表里有 MAC 的已经在上面加过了；表里只有一条没 MAC 的记录，
            // 或者压根没有记录，都走下面这条 —— 这台设备在线但发不了魔术包。
            if let entry = table[ip], !entry.mac.isEmpty { continue }
            guard !result.contains(where: { $0.ipAddress == ip }) else { continue }
            result.append(WakeOnLANDevice(
                ipAddress: ip,
                macAddress: "",
                deviceName: ip,
                vendor: WakeOnLAN.unknownVendor
            ))
        }

        // 按 IP 数值排序，不是字符串：否则 192.168.1.100 会排到 192.168.1.9 前面。
        return result.sorted { LocalIPv4Network.value(of: $0.ipAddress) < LocalIPv4Network.value(of: $1.ipAddress) }
    }

    nonisolated static func isIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, text, &address) == 1
    }

    // MARK: 跑外部命令

    struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    /// 跑一个外部命令。阻塞部分扔到全局队列，读管道和等退出都有超时。
    nonisolated static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments, timeout))
            }
        }
    }

    nonisolated static func runBlocking(
        _ executable: String,
        _ arguments: [String],
        _ timeout: TimeInterval
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        // 两个管道同时读：只读一个的话另一个写满缓冲区，子进程会卡在 write 上。
        let group = DispatchGroup()
        var outData = Data()
        var errData = Data()
        let lock = NSLock()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); outData = data; lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData = data; lock.unlock()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            let hardDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < hardDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            // terminate 只是 SIGTERM，卡在内核里的进程可能不理，用 SIGKILL 收尸。
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        process.waitUntilExit()
        group.wait()

        lock.lock()
        let outText = String(decoding: outData, as: UTF8.self)
        let errText = String(decoding: errData, as: UTF8.self)
        lock.unlock()

        return ProcessResult(status: process.terminationStatus, stdout: outText, stderr: errText, timedOut: timedOut)
    }
}
