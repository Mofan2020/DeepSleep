//
//  ImageUpscaleView.swift
//  Deep Sleep
//
//  「图片超分」页面：把图片放大 2 到 4 倍，算法可选。
//
//  四种算法的差别写在界面上，因为它们的**用途**不一样：
//    - 神经网络超分：系统自带 ML 模型，放大后保留更多细节。但只支持 4 倍，
//      且输入边长不超过 1920 像素（系统限制，超了会明确报错）。
//    - Lanczos / 双三次 / 最近邻：纯插值，倍数任意。
//      最近邻不插值，只复制像素 —— 适合看像素放大后的原始结构。
//
//  交互上的两个决定：
//    - 放大是**本地计算**，不需要联网、不需要额外权限；
//    - 结果默认存成 PNG（无损）。存 JPEG 会让已经有损压缩过的图片
//      再糊一代，那不是用户想要的。
//
//  2026-11 界面换新：
//    - 间距、圆角走 DS.Space / DS.Radius。
//    - 倍数用原生 Stepper，算法用原生 Picker(.segmented)。
//    - 处理中有明确的进行中状态和取消入口；取消只放弃本次结果，
//      不假装已经算完（底层计算不感知取消，只能等它自己结束）。
//

import SwiftUI
import AppKit

struct ImageUpscaleView: View {

    @State private var method: UpscaleMethod = .lanczos
    @State private var factor: Int = 2

    /// 原图。
    @State private var sourceImage: CGImage?
    @State private var sourceURL: URL?
    @State private var sourceSizeText: String = ""

    /// 放大结果。
    @State private var resultImage: CGImage?
    @State private var isWorking = false
    @State private var lastError: String?
    /// 上次放大耗时（秒）。
    @State private var elapsed: Double?
    /// 用户点了取消。置位后本次结果不再采用。
    @State private var cancelRequested = false
    /// 当前这次放大的任务句柄。取消入口靠它。
    @State private var workTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            sourceCard
            methodCard
            resultCard
        }
        .pageLayout()
    }

    // MARK: - 原图

    private var sourceCard: some View {
        SectionCard(
            title: "原图",
            subtitle: "选一张本地图片。放大在本地算，不联网、不需要额外权限。",
            symbol: "photo",
            accessory: AnyView(
                Button {
                    pickSource()
                } label: {
                    Label("选择图片…", systemImage: "folder")
                }
            )
        ) {
            if let sourceImage {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    LabeledContent("文件") {
                        HStack(spacing: DS.Space.sm) {
                            Text(sourceURL?.lastPathComponent ?? "未命名")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !sourceSizeText.isEmpty {
                                Text(sourceSizeText)
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    previewOf(sourceImage, maxHeight: 200)
                        .frame(maxWidth: .infinity)
                }
            } else {
                EmptyStateView(
                    title: "选一张图片开始",
                    message: "支持 PNG / JPEG / TIFF / HEIC / BMP / GIF。放大在本机完成，不上传。",
                    systemImage: "photo",
                    actionTitle: "选择图片…",
                    action: pickSource
                )
            }
        }
    }

    // MARK: - 算法

    private var methodCard: some View {
        SectionCard(
            title: "放大方式",
            subtitle: method.detail,
            symbol: "wand.and.stars"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Picker("算法", selection: $method) {
                    ForEach(UpscaleMethod.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: method) { _, _ in
                    // 切算法时把倍数拉到该算法支持的范围内 ——
                    // 停在不支持的倍数上，按钮会一直报错。
                    if !method.supportedFactors.contains(factor) {
                        factor = method.supportedFactors.first ?? 2
                    }
                }

                LabeledContent("倍数") {
                    Stepper(value: factorBinding,
                            in: factorRange,
                            step: 1) {
                        Text("\(factor) 倍")
                            .font(.body)
                            .monospacedDigit()
                    }
                    .controlSize(.small)
                }

                if method.needsModelDownload {
                    Text("第一次用神经网络超分，系统可能要先下载模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: DS.Space.sm) {
                    Button {
                        run()
                    } label: {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("放大", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sourceImage == nil || isWorking)
                    .keyboardShortcut(.defaultAction)

                    if isWorking {
                        Button(role: .cancel) {
                            cancelWork()
                        } label: {
                            Label("取消", systemImage: "xmark.circle")
                        }
                        .controlSize(.small)
                        .disabled(cancelRequested)
                    }

                    Spacer(minLength: DS.Space.sm)

                    StatusPill(text: workStatusText,
                               isActive: isWorking,
                               color: workStatusColor)
                }
            }
        }
    }

    // MARK: - 结果

    private var resultCard: some View {
        SectionCard(
            title: "结果",
            subtitle: resultSubtitle,
            symbol: "photo.badge.arrow.down"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                if let lastError {
                    HStack(alignment: .top, spacing: DS.Space.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.Tone.critical)
                            .font(.system(size: 11, weight: .semibold))
                        Text(lastError)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }

                if let resultImage {
                    previewOf(resultImage, maxHeight: 320)
                        .frame(maxWidth: .infinity)

                    HStack(spacing: DS.Space.sm) {
                        Button {
                            saveResult()
                        } label: {
                            Label("保存…", systemImage: "square.and.arrow.down")
                        }
                        .keyboardShortcut("s", modifiers: .command)

                        if sourceURL != nil {
                            Text("默认存成 PNG，\(factor) 倍后是 \(sourceImage?.width ?? 0)×\(sourceImage?.height ?? 0) → \(resultImage.width)×\(resultImage.height)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: DS.Space.sm)
                    }
                } else if isWorking {
                    // 处理中：不定进度 —— 底层算多久说不准，
                    // 画一个假百分比比什么都不显示更糟。
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text(cancelRequested
                             ? "正在取消：等当前这一步算完就丢弃结果，不会写盘。"
                             : "处理中，放大在本机算。神经网络超分可能要等模型下载。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if sourceImage == nil {
                    EmptyStateView(
                        title: "选一张图片开始",
                        message: "还没有选图。",
                        systemImage: "photo.badge.arrow.down"
                    )
                } else {
                    EmptyStateView(
                        title: "还没有结果",
                        message: "算法和倍数都选好了，点上面的「放大」。",
                        systemImage: "photo.badge.arrow.down",
                        actionTitle: "放大",
                        action: run
                    )
                }
            }
        }
    }

    private var resultSubtitle: String {
        if let elapsed {
            return String(format: "耗时 %.2f 秒", elapsed)
        }
        return "结果保存在本地，不上传。"
    }

    // MARK: - 状态文案

    private var workStatusText: String {
        if isWorking {
            return cancelRequested ? "取消中" : "处理中"
        }
        if resultImage != nil {
            return "已完成"
        }
        return "待处理"
    }

    private var workStatusColor: Color {
        if isWorking {
            return cancelRequested ? DS.Tone.caution : DS.Tone.info
        }
        return resultImage != nil ? DS.Tone.good : DS.Tone.idle
    }

    // MARK: - 倍数绑定

    /// Stepper 的取值范围。神经网络超分只支持 4 倍，范围就是 4...4。
    private var factorRange: ClosedRange<Int> {
        let factors = method.supportedFactors
        let low = factors.min() ?? 1
        let high = factors.max() ?? low
        return low...high
    }

    /// Stepper 只能给出范围内的整数；不同算法支持的倍数集合可能不是连续的，
    /// 这里落到该算法真正支持的那个倍数上。
    private var factorBinding: Binding<Int> {
        Binding(
            get: { factor },
            set: { newValue in
                let supported = method.supportedFactors
                if supported.contains(newValue) {
                    factor = newValue
                    return
                }
                guard let nearest = supported.min(by: { abs($0 - newValue) < abs($1 - newValue) }) else {
                    return
                }
                factor = nearest
            }
        )
    }

    // MARK: - 预览

    /// 图片预览。
    private func previewOf(_ image: CGImage, maxHeight: CGFloat) -> some View {
        Image(decorative: image, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: maxHeight)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Tone.hairline)
            )
    }

    // MARK: - 动作

    private func pickSource() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .bmp, .gif]
        panel.message = "选一张要放大的图片"
        panel.prompt = "选择"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSource(url)
    }

    private func loadSource(_ url: URL) {
        lastError = nil
        do {
            let image = try ImageUpscaler.loadImage(at: url)
            sourceImage = image
            sourceURL = url
            sourceSizeText = "\(image.width) × \(image.height)"
            // 换图了，之前的结果就没意义了。
            resultImage = nil
            elapsed = nil
        } catch {
            lastError = error.localizedDescription
            sourceImage = nil
            sourceURL = nil
            sourceSizeText = ""
        }
    }

    /// 开始放大。任务句柄存下来，取消按钮靠它。
    ///
    /// 底层的放大过程不感知取消（VideoToolbox / CoreImage 那一段没法中断），
    /// 所以「取消」的语义是**放弃本次结果**：算完直接丢掉，不写盘、不显示。
    private func run() {
        guard let sourceImage, !isWorking else { return }
        isWorking = true
        cancelRequested = false
        lastError = nil
        elapsed = nil
        let start = Date()
        let method = method
        let factor = factor

        workTask = Task { @MainActor in
            do {
                let output = try await ImageUpscaler.upscale(
                    image: sourceImage, method: method, factor: factor)
                if cancelRequested || Task.isCancelled {
                    // 算了但不要了：结果丢弃，不进界面。
                    elapsed = nil
                } else {
                    resultImage = output
                    elapsed = Date().timeIntervalSince(start)
                }
            } catch {
                if cancelRequested || Task.isCancelled {
                    elapsed = nil
                } else {
                    lastError = error.localizedDescription
                    resultImage = nil
                }
            }
            isWorking = false
            cancelRequested = false
            workTask = nil
        }
    }

    /// 请求取消本次放大。
    private func cancelWork() {
        cancelRequested = true
        workTask?.cancel()
    }

    private func saveResult() {
        guard let resultImage, let sourceURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ImageUpscaler.suggestedOutputName(
            for: sourceURL, factor: factor)
        panel.message = "保存放大后的图片"
        panel.prompt = "保存"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ImageUpscaler.writeImage(resultImage, to: url)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
