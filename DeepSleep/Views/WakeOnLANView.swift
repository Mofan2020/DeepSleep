//
//  WakeOnLANView.swift
//  Deep Sleep
//
//  「网络唤醒」页面：扫局域网里的设备，给勾选的设备发 WOL 魔术包。
//
//  这个页面有几件事必须写在明面上，不能让用户误以为「点了就醒」：
//    - 发出去只代表 102 字节的包交给了内核，不代表目标设备会醒；
//    - 目标设备得自己开着「唤醒以供网络访问」，网卡也得支持；
//    - macOS 上从本机发广播包可能被防火墙拦掉，这时包根本没出网卡；
//    - 扫描全靠 ARP 表 + ping，设备如果挡了 ICMP 又没和本机通信过，扫不到。
//    所以按钮写「发送魔术包」，不写「唤醒成功」。
//
//  与其他工具页一致：SectionCard 分块、页面根视图 .pageLayout()、
//  错误用内联文字，不弹窗打断。
//
//  2026-11 界面换新：
//    - 间距、圆角走 DS.Space / DS.Radius。
//    - 设备列表压成紧凑行（设备名 / IP / MAC / 结果）。
//    - 扫描状态用 StatusPill + 文字双编码。
//    - 手动 MAC 输入用原生 TextField，格式不对时给具体原因。
//

import SwiftUI

struct WakeOnLANView: View {

    @State private var devices: [WakeOnLANDevice] = []
    @State private var selected: Set<String> = []
    @State private var isScanning = false
    @State private var progress: Double = 0
    @State private var statusText = ""
    /// 每台设备各自的发送结果，按设备 id 存 —— 批量发的时候不会互相覆盖。
    @State private var results: [String: SendResult] = [:]
    @State private var portText: String = String(WakeOnLAN.defaultPort)
    @State private var scanned = false
    /// 扫到的本机网段，扫完显示出来 —— 用户能对一下扫的是不是自己想的那张网。
    @State private var subnetText: String?
    /// 手动填的 MAC 地址（扫不到设备时用）。
    @State private var manualMAC: String = ""
    /// 手动发送的结果文案。
    @State private var manualResult: String?
    @State private var isSendingManual = false

    /// 一台设备的发送结果。
    private struct SendResult {
        enum Kind { case success, failure }
        let kind: Kind
        let message: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            controlCard
            deviceCard
            noteCard
        }
        .pageLayout()
    }

    // MARK: - 顶部：说明 + 扫描 + 端口

    private var controlCard: some View {
        SectionCard(
            title: "网络唤醒（WOL）",
            subtitle: "扫描当前局域网里的设备，给选中的设备发送 WOL 魔术包。",
            symbol: "power.circle",
            accent: .accentColor
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text("目标设备必须自己在系统或网卡设置里开着「唤醒以供网络访问」，并且网卡支持 WOL。这里发出去只代表魔术包发出去了，能不能醒取决于目标机自己的设置和硬件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: DS.Space.sm) {
                    Button {
                        Task { await scan() }
                    } label: {
                        if isScanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("扫描", systemImage: "magnifyingglass")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isScanning)

                    Button("全选") { selectAll(true) }
                        .controlSize(.small)
                        .disabled(!isScanning && devices.filter(\.canWake).isEmpty)
                    Button("全不选") { selectAll(false) }
                        .controlSize(.small)
                        .disabled(selected.isEmpty)

                    Spacer(minLength: DS.Space.sm)

                    StatusPill(text: scanStatusText,
                               isActive: isScanning,
                               color: scanStatusColor)
                }

                if isScanning {
                    // 真进度：扫描器每 ping 完一段就回报一次，不是假条。
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .frame(maxWidth: 260)
                }

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let subnetText {
                    Text(subnetText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LabeledContent("端口") {
                    HStack(spacing: DS.Space.sm) {
                        TextField("9", text: $portText)
                            .frame(width: 72)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: portText) { _, _ in
                                // 换端口后旧结果就不作数了，清掉免得误导。
                                results.removeAll()
                            }
                        if let portIssue {
                            Text(portIssue)
                                .font(.caption)
                                .foregroundStyle(DS.Tone.critical)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Divider()

                manualMACSection

                HStack(spacing: DS.Space.sm) {
                    Button {
                        Task { await sendSelected() }
                    } label: {
                        Label("发送魔术包给选中的 \(selected.count) 台", systemImage: "paperplane")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(selected.isEmpty || portIssue != nil)

                    Button("清空结果") { results.removeAll() }
                        .controlSize(.small)
                        .disabled(results.isEmpty)
                    Spacer(minLength: DS.Space.sm)
                }
            }
        }
    }

    /// 手动指定 MAC。扫不到设备时用（比如设备不回 ping，但你知道它的 MAC）。
    private var manualMACSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            SubsectionHeader(title: "手动指定 MAC", symbol: "number")
            LabeledContent("MAC 地址") {
                HStack(spacing: DS.Space.sm) {
                    TextField("AA:BB:CC:DD:EE:FF", text: $manualMAC)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 180)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await sendManual() }
                    } label: {
                        if isSendingManual {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("发送魔术包", systemImage: "paperplane")
                        }
                    }
                    .controlSize(.small)
                    .disabled(macIssue != nil || portIssue != nil || isSendingManual)
                }
            }
            if let macIssue {
                Text(macIssue)
                    .font(.caption)
                    .foregroundStyle(DS.Tone.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let manualResult {
                Text(manualResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.md)
        .insetPanel(cornerRadius: DS.Radius.control)
    }

    /// 端口输入有问题时给出人话原因；没问题返回 nil。
    private var portIssue: String? {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "端口不能为空。" }
        guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return "端口只能是数字。"
        }
        guard let value = UInt16(trimmed), value > 0 else {
            return "端口要在 1–65535 之间。"
        }
        return nil
    }

    private var port: UInt16? {
        guard portIssue == nil else { return nil }
        return UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// MAC 格式不对时给出人话原因；没问题返回 nil。
    ///
    /// 接受三种写法：AA:BB:CC:DD:EE:FF、AA-BB-CC-DD-EE-FF、AABBCCDDEEFF。
    private var macIssue: String? {
        let raw = manualMAC.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "MAC 地址不能为空。" }
        let hex = raw.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard hex.count == 12, hex.allSatisfy({ $0.isHexDigit }) else {
            return "MAC 要 12 位十六进制，比如 AA:BB:CC:DD:EE:FF。"
        }
        return nil
    }

    // MARK: - 扫描状态

    /// 扫描状态。颜色 + 文字双编码：光靠颜色分不出「没扫」和「扫完没扫到」。
    private var scanStatusText: String {
        if isScanning { return "扫描中" }
        if !scanned { return "未扫描" }
        if devices.isEmpty { return "未扫到设备" }
        return "扫描完成，共 \(devices.count) 台"
    }

    private var scanStatusColor: Color {
        if isScanning { return DS.Tone.info }
        if !scanned { return DS.Tone.idle }
        if devices.isEmpty { return DS.Tone.caution }
        return DS.Tone.good
    }

    // MARK: - 设备列表

    private var deviceCard: some View {
        SectionCard(
            title: "设备",
            subtitle: deviceSubtitle,
            symbol: "list.bullet.rectangle"
        ) {
            if devices.isEmpty {
                if isScanning {
                    HStack(spacing: DS.Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("正在扫描…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                } else {
                    EmptyStateView(
                        title: scanned ? "未扫到设备" : "还没扫描",
                        message: emptyMessage,
                        systemImage: "wifi.router",
                        actionTitle: scanned ? nil : "扫描",
                        action: scanned ? nil : { Task { await scan() } }
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    headerRow
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: DS.Space.xxs) {
                            ForEach(devices) { device in
                                deviceRow(device)
                                if device.id != devices.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 400)
                }
            }
        }
    }

    private var deviceSubtitle: String {
        if devices.isEmpty { return "还没有扫描结果。" }
        let wakeable = devices.filter(\.canWake).count
        return "共 \(devices.count) 台，其中 \(wakeable) 台有 MAC 可以唤醒，已勾选 \(selected.count) 台。"
    }

    private var emptyMessage: String {
        if scanned {
            return "这个网段没扫到设备。可能设备都关着、挡了 ICMP，或者这台 Mac 读不到 ARP 表（系统版本差异），此时只能拿到 ping 回应但没有 MAC。也可以在下面手填 MAC 直接发。"
        }
        return "点上面的「扫描」开始。扫描会读一次 ARP 表、并发 ping 本网段、再读一次 ARP 表。"
    }

    private var headerRow: some View {
        HStack(spacing: DS.Space.sm) {
            Text("")
                .frame(width: 22)
            Text("设备名")
                .frame(minWidth: 120, alignment: .leading)
            Text("IP 地址")
                .frame(minWidth: 110, alignment: .leading)
            Text("MAC 地址")
                .frame(minWidth: 140, alignment: .leading)
            Text("结果")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("")
                .frame(width: 54)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, DS.Space.xs)
    }

    private func deviceRow(_ device: WakeOnLANDevice) -> some View {
        let result = results[device.id]

        return HStack(spacing: DS.Space.sm) {
            Toggle("", isOn: Binding(
                get: { selected.contains(device.id) },
                set: { newValue in
                    if newValue { selected.insert(device.id) } else { selected.remove(device.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!device.canWake)
            .frame(width: 22)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(device.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if device.vendor != WakeOnLAN.unknownVendor {
                    Text(device.vendor)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            Text(device.ipAddress)
                .frame(minWidth: 110, alignment: .leading)
                .textSelection(.enabled)

            Text(device.macAddress.isEmpty ? "—" : device.macAddress)
                .frame(minWidth: 140, alignment: .leading)
                .foregroundStyle(device.macAddress.isEmpty ? DS.Tone.idle : .primary)
                .textSelection(.enabled)

            Group {
                if let result {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: result.kind == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.kind == .success ? DS.Tone.good : DS.Tone.critical)
                            .font(.system(size: 10, weight: .bold))
                        Text(result.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if !device.canWake {
                    Text("没有 MAC，发不了")
                        .font(.caption)
                        .foregroundStyle(DS.Tone.idle)
                } else {
                    Text("")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("发送") {
                Task { await send(device) }
            }
            .controlSize(.small)
            .disabled(!device.canWake || port == nil)
            .frame(width: 54)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, DS.Space.xs)
    }

    // MARK: - 底部说明

    private var noteCard: some View {
        SectionCard(
            title: "这个工具不会做什么",
            subtitle: "有几条限制是真的绕不过去，写在这儿免得白试。",
            symbol: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                BulletLine("发送成功只说明魔术包交给了系统，不代表目标设备会醒。唤醒能不能成，取决于目标机自己有没有开「唤醒以供网络访问」、网卡支不支持 WOL。")
                BulletLine("macOS 上从本机发广播包可能被系统防火墙拦掉，这时包根本没出网卡，但界面上仍会显示已发送。")
                BulletLine("设备列表来自 ARP 表和 ping。设备如果挡了 ICMP、又没和这台 Mac 通过信，扫不到它。")
                BulletLine("只能唤醒当前网段里的设备。跨网段要路由器转发定向广播，这个工具不做。")
                BulletLine("默认广播地址是 255.255.255.255，端口 9；有些设备只认端口 7，换一下再试。")
            }
        }
    }

    // MARK: - 动作

    private func scan() async {
        guard !isScanning else { return }
        isScanning = true
        devices = []
        results.removeAll()

        let scanner = NetworkScanner.shared
        // 让扫描器的进度直接反映到页面状态上 —— 扫一轮 /24 要几秒，
        // 没有进度用户会以为卡死了。
        scanner.onUpdate = { fraction, text in
            progress = fraction
            statusText = text
        }
        progress = 0
        statusText = "正在读取本机网络信息…"

        let found = await scanner.scan()
        scanner.onUpdate = nil

        if let network = NetworkScanner.localNetwork() {
            subnetText = "本机网段 \(network.address)/\(network.prefixLength)，接口 \(network.interfaceName)，子网广播 \(network.broadcastAddress)。"
        }

        devices = found
        // 扫完默认勾上有 MAC 的设备：最常见的用法就是扫完直接发。
        selected = Set(found.filter(\.canWake).map(\.id))
        scanned = true
        isScanning = false
        if !found.isEmpty {
            statusText = "扫描完成，共 \(found.count) 台设备。"
        }
    }

    private func selectAll(_ on: Bool) {
        selected = on ? Set(devices.filter(\.canWake).map(\.id)) : []
    }

    private func send(_ device: WakeOnLANDevice) async {
        guard let port else { return }
        let outcome = await WakeOnLANView.sendOne(device, port: port)
        results[device.id] = outcome
    }

    private func sendSelected() async {
        guard let port else { return }
        let targets = devices.filter { selected.contains($0.id) && $0.canWake }
        for device in targets {
            // 一台一台发，每台单独记结果：批量里某台失败不该盖掉别人的成功。
            let outcome = await WakeOnLANView.sendOne(device, port: port)
            results[device.id] = outcome
        }
    }

    /// 手动发一个 MAC。扫不到设备、但知道 MAC 时用。
    private func sendManual() async {
        guard let port, macIssue == nil else { return }
        isSendingManual = true
        manualResult = nil
        let target = WakeOnLANDevice(
            ipAddress: "",
            macAddress: manualMAC.trimmingCharacters(in: .whitespacesAndNewlines),
            deviceName: "手动指定",
            vendor: ""
        )
        let outcome = await WakeOnLANView.sendOne(target, port: port)
        manualResult = outcome.message
        isSendingManual = false
    }

    /// 发一台，返回给界面看的结果。发送本身放到后台线程，界面不卡。
    private static func sendOne(_ device: WakeOnLANDevice, port: UInt16) async -> SendResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try WakeOnLAN.send(macAddress: device.macAddress,
                                       port: port,
                                       broadcastAddress: WakeOnLAN.defaultBroadcastAddress)
                    continuation.resume(returning: SendResult(
                        kind: .success,
                        message: "魔术包已发送（\(WakeOnLAN.packetLength) 字节，端口 \(port)）"
                    ))
                } catch {
                    continuation.resume(returning: SendResult(kind: .failure, message: "\(error)"))
                }
            }
        }
    }
}
