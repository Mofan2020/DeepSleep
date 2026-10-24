//
//  GatewayDisclaimer.swift
//  Deep Sleep
//
//  本地 AI 网关的免责申明：第一次进网关页之前要明确告知风险。
//
//  为什么需要它：网关会在本机开一个端口，接收别的程序发来的请求并转发到
//  厂商 API，请求内容与 API Key 都会经过这台电脑。这不是「打开就完事」的
//  设置项，是有真实暴露面的功能，所以要先确认一次。
//
//  持久化契约（两个 key 都满足才算已同意）：
//  - Bool  `llm.gateway.disclaimerAccepted`
//  - Int   `llm.gateway.disclaimerVersion`（当前版本 = 1）
//
//  「不同意」不写任何持久化 —— 不同意 = 从未同意过，下次进入照旧弹同一张弹窗。
//  正文语义有实质变化时把版本号 +1，老用户下次进入会重新看到一次；
//  纯错别字修正不动版本号。
//

import SwiftUI

// MARK: - 免责状态

/// 免责申明的状态与持久化。
enum GatewayDisclaimer {

    /// UserDefaults key：是否已同意。
    static let acceptedKey = "llm.gateway.disclaimerAccepted"

    /// UserDefaults key：同意时的正文版本。
    static let versionKey = "llm.gateway.disclaimerVersion"

    /// 当前正文版本。正文语义有实质变化时 +1。
    static let currentVersion = 1

    /// 是否已同意当前版本的免责申明。
    static var accepted: Bool {
        let flag = UserDefaults.standard.bool(forKey: acceptedKey)
        let version = UserDefaults.standard.integer(forKey: versionKey)
        return flag && version >= currentVersion
    }

    /// 记录「已同意」。两个 key 一起写，缺一个都算没同意。
    static func accept() {
        UserDefaults.standard.set(true, forKey: acceptedKey)
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
    }

    /// 清掉同意记录（重新征求同意）。目前只用于测试与排障。
    static func reset() {
        UserDefaults.standard.removeObject(forKey: acceptedKey)
        UserDefaults.standard.removeObject(forKey: versionKey)
    }
}

// MARK: - 免责弹窗

/// 免责申明弹窗。
///
/// 用 `.sheet` 而不是 `.alert`：正文有四段，`.alert` 的 message 放不下也不可滚动。
struct GatewayDisclaimerView: View {

    /// 「同意并继续」。
    let onAccept: () -> Void
    /// 「不同意」或直接关闭。
    let onReject: () -> Void

    @State private var isSubmitting = false
    @State private var errorText: String?

    /// 正文。文案是定稿，改动请同步 `GatewayDisclaimer.currentVersion`。
    private static let bodyParagraphs: [String] = [
        "本地网关会在你的 Mac 上开一个端口，接收其他程序发来的模型请求，再转发到对应的厂商 API。请求内容和 API Key 都会经过这台电脑。",
        "填写的 API Key 存在 macOS 钥匙串里，不写进配置文件，也不会发往除你选择的厂商之外的任何地方。调用记录只写在本机的数据库里。",
        "网关默认只监听 127.0.0.1，同一个网络里的其他设备连不上。如果在设置里改了监听地址，这个限制就不存在了。",
        "网关还是试验性功能，随时可能调整或移除，升级之后的行为也可能变化。"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.bodyParagraphs, id: \.self) { paragraph in
                        Text(paragraph)
                            .font(.callout)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            buttonRow
        }
        .padding(22)
        .frame(width: 520)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("本地 AI 网关")
                .font(.title3.weight(.semibold))
            Text("使用前请先确认下面几点")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 按钮

    private var buttonRow: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 8)
            Button("不同意", role: .cancel) {
                onReject()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityHint("不启用网关，随时可以再打开")

            Button {
                submit()
            } label: {
                if isSubmitting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("同意并继续")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .frame(minWidth: 132)
            .disabled(isSubmitting)
        }
    }

    private func submit() {
        isSubmitting = true
        errorText = nil
        GatewayDisclaimer.accept()
        onAccept()
    }
}
