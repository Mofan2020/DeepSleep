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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            symbol: "photo"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        pickSource()
                    } label: {
                        Label("选择图片…", systemImage: "folder")
                    }

                    if let sourceURL {
                        Text(sourceURL.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        if !sourceSizeText.isEmpty {
                            Text(sourceSizeText)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    } else {
                        Spacer()
                    }
                }

                if let sourceImage {
                    previewOf(sourceImage, maxHeight: 180)
                        .frame(maxWidth: .infinity)
                }
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
            VStack(alignment: .leading, spacing: 12) {
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

                HStack(spacing: 10) {
                    Text("倍数")
                    Picker("倍数", selection: $factor) {
                        ForEach(method.supportedFactors, id: \.self) { f in
                            Text("\(f) 倍").tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    Spacer()
                }

                if method.needsModelDownload {
                    Text("第一次用神经网络超分，系统可能要先下载模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        Task { await run() }
                    } label: {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("放大", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                    }
                    .disabled(sourceImage == nil || isWorking)
                    .keyboardShortcut(.defaultAction)

                    if isWorking {
                        Text("处理中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
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
            VStack(alignment: .leading, spacing: 12) {
                if let lastError {
                    Text(lastError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let resultImage {
                    previewOf(resultImage, maxHeight: 320)
                        .frame(maxWidth: .infinity)

                    HStack {
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
                        Spacer()
                    }
                } else if lastError == nil {
                    Text("还没放大。选一张图，选好算法和倍数，点「放大」。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

    // MARK: - 预览

    /// 图片预览。
    private func previewOf(_ image: CGImage, maxHeight: CGFloat) -> some View {
        Image(decorative: image, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: maxHeight)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary, lineWidth: 1)
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

    private func run() async {
        guard let sourceImage else { return }
        isWorking = true
        lastError = nil
        elapsed = nil
        let start = Date()
        do {
            let output = try await ImageUpscaler.upscale(
                image: sourceImage, method: method, factor: factor)
            resultImage = output
            elapsed = Date().timeIntervalSince(start)
        } catch {
            lastError = error.localizedDescription
            resultImage = nil
        }
        isWorking = false
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
