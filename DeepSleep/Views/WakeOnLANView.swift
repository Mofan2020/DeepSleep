//
//  WakeOnLANView.swift
//  Deep Sleep
//
//  「网络唤醒」页面：扫局域网里的设备，给勾选的设备发 WOL 魔术包。
//
//  界面约定：SectionCard 分块、页面根视图 .pageLayout()、
//  错误用内联文字，不弹窗打断。
//
//  2026-11 界面换新：
//    - 间距、圆角走 DS.Space / DS.Radius。
//    - 设备列表压成紧凑行（设备名 / IP / MAC / 结果）。
//    - 扫描状态用 StatusPill + 文字双编码。
//    - 手动 MAC 输入用原生 TextField，格式不对时给具体原因。
//
//  2026-11 v1.11.1：
//    - 扫到设备却拿不到 MAC 时，列表上方说清楚原因，并告诉用户去哪里
//      开本地网络权限（系统设置 → 隐私与安全性 → 本地网络）。
//    - 「没扫到设备」「没拿到 MAC」「扫描中」三种状态分开，不混着说。
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
        }
        .pageLayout()
    }

    // MARK: - 顶部：说明 + 扫描 + 端口

    private var controlCard: some View {
        SectionCard(
            title: "网络唤醒（WOL）",
            subtitle: "扫描局域网里的设备，给选中的设备发唤醒包。",
            symbol: "power.circle",
            accent: .accentColor
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text("目标机需在系统或网卡设置里开启「唤醒以供网络访问」，网卡也要支持唤醒。")
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

                Text("有些设备只认端口 7，没反应时可以改端口再试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 显示「已发送」只代表包交给了系统。macOS 防火墙可能把它拦在
                // 本机（包根本没出网卡），这时目标机不会醒 —— 不写清楚的话，
                // 用户会以为是设备的问题，反复重发。
                Text("显示「已发送」只代表包交给了系统。macOS 防火墙可能把它拦在本机，"
                     + "这时机器不会醒。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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

    /// 扫描结果摘要：区分「有 MAC」「只有 IP」「什么都没扫到」。
    ///
    /// 助手兜底的情况一并带上 —— 界面要靠它区分「还没试过助手」
    /// 和「试过了、也没帮上忙」，这两句提示语不一样。
    private var summary: WoScanSummary {
        let scanner = NetworkScanner.shared
        return WoScanSummary(
            devices: devices,
            helperFallbackAttempted: scanner.lastHelperFallbackAttempted,
            helperFallbackRecoveredCount: scanner.lastHelperFallbackRecoveredCount
        )
    }

    /// 在线但拿不到 MAC 的设备数。
    private var missingMACCount: Int { summary.missingMACCount }

    /// 扫描状态。颜色 + 文字双编码：光靠颜色分不出「没扫」和「扫完没扫到」。
    private var scanStatusText: String {
        if isScanning { return "扫描中" }
        if !scanned { return "未扫描" }
        if devices.isEmpty { return "未扫到设备" }
        if summary.wakeableCount == 0 { return "扫到 \(devices.count) 台，没拿到 MAC" }
        return "扫描完成，共 \(devices.count) 台"
    }

    private var scanStatusColor: Color {
        if isScanning { return DS.Tone.info }
        if !scanned { return DS.Tone.idle }
        if devices.isEmpty { return DS.Tone.caution }
        if summary.wakeableCount == 0 { return DS.Tone.caution }
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
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    if missingMACCount > 0 {
                        missingMACNotice
                    }
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

    /// 有设备在线却拿不到 MAC —— 这时发不了唤醒包，必须说清楚为什么。
    ///
    /// 三种情况说三句话：
    ///   - 助手还没试过 → 多半是这台 App 没被允许访问本地网络，用户自己能解决；
    ///   - 助手试过了、补到了一些 → 说明主路读不到但兜底管用，剩下的仍然拿不到；
    ///   - 助手试过了、也没补到 → 助手（root）也读不到，这时才提「更新/重装助手」。
    private var missingMACNotice: some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Tone.caution)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("有 \(missingMACCount) 台设备在线，但没拿到 MAC 地址，发不了唤醒包。")
                    .foregroundStyle(.primary)
                Text(missingMACReason)
                    .foregroundStyle(.secondary)
                if summary.didHelperRecover {
                    Text("特权助手这一轮补到了 \(summary.helperFallbackRecoveredCount) 台的 MAC 地址。")
                        .foregroundStyle(DS.Tone.good)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(DS.Space.md)
        .insetPanel()
    }

    /// 缺 MAC 的原因说明 —— 按「助手试过了没有」分两种说法。
    private var missingMACReason: String {
        if summary.isMissingMACAfterHelper {
            return "这台 App 读不到本地网络的设备记录，特权助手（root 身份）这一轮也没读到。到「系统设置 → 隐私与安全性 → 本地网络」里允许 Deep Sleep，再重新扫描一次；如果仍然不行，说明这台 Mac 的系统没有把邻居缓存暴露出来。"
        }
        if summary.helperFallbackAttempted {
            return "这台 App 读不到本地网络的设备记录。到「系统设置 → 隐私与安全性 → 本地网络」里允许 Deep Sleep，再重新扫描一次。"
        }
        return "多半是这台 App 读不到本地网络的设备记录。到「系统设置 → 隐私与安全性 → 本地网络」里允许 Deep Sleep，再重新扫描一次。"
    }

    private var deviceSubtitle: String {
        if devices.isEmpty { return "还没有扫描结果。" }
        let wakeable = summary.wakeableCount
        let missing = summary.missingMACCount
        if missing == 0 {
            return "共 \(devices.count) 台，其中 \(wakeable) 台有 MAC 可以唤醒，已勾选 \(selected.count) 台。"
        }
        return "共 \(devices.count) 台，其中 \(wakeable) 台有 MAC 可以唤醒，\(missing) 台没拿到 MAC，已勾选 \(selected.count) 台。"
    }

    private var emptyMessage: String {
        if scanned {
            return "这个网段没扫到设备。可以手填 MAC 发送，或到「系统设置 → 隐私与安全性 → 本地网络」允许 Deep Sleep 后重扫。"
        }
        return "点上面的「扫描」开始查找局域网里的设备。"
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
            let summary = WoScanSummary(
                devices: found,
                helperFallbackAttempted: scanner.lastHelperFallbackAttempted,
                helperFallbackRecoveredCount: scanner.lastHelperFallbackRecoveredCount
            )
            if summary.missingMACCount > 0 {
                statusText = "扫描完成，共 \(found.count) 台设备，\(summary.missingMACCount) 台没拿到 MAC。"
            } else {
                statusText = "扫描完成，共 \(found.count) 台设备。"
            }
            if summary.didHelperRecover {
                statusText += "特权助手补到了 \(summary.helperFallbackRecoveredCount) 台的 MAC 地址。"
            }
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
