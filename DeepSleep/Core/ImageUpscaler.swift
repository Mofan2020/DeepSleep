//
//  ImageUpscaler.swift
//  Deep Sleep
//
//  图片超分的算法实现。
//
//  四种方法：
//  - 神经网络超分：VideoToolbox 的 `VTSuperResolutionScaler`，系统自带 ML 模型，
//    放大后能保留更多细节（不是插值）。**只支持 4 倍**，且输入边长上限 1920。
//  - Lanczos / 双三次 / 最近邻：CoreImage 的重采样滤镜，纯插值，倍数任意。
//
//  像素格式统一走 32BGRA（kCVPixelFormatType_32BGRA）——
//  VideoToolbox 要求 pixel buffer 是 IOSurface-backed 且格式对齐，
//  BGRA 是系统处理得最快的那种。
//

import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers

// MARK: - 算法枚举

/// 超分算法。
enum UpscaleMethod: String, CaseIterable, Identifiable {
    case neural
    case lanczos
    case bicubic
    case nearest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .neural:  return "神经网络超分"
        case .lanczos: return "Lanczos"
        case .bicubic: return "双三次"
        case .nearest: return "最近邻"
        }
    }

    /// 一句话说明，给界面上的副标题用。
    var detail: String {
        switch self {
        case .neural:  return "系统自带神经网络模型，放大后保留更多细节。只支持 4 倍，输入边长不超过 1920 像素。"
        case .lanczos: return "经典高质量插值，边缘锐利，倍数任意。"
        case .bicubic: return "双三次插值，比 Lanczos 平滑，倍数任意。"
        case .nearest: return "最近邻，不做任何插值，只复制像素。适合看像素放大后的原始结构。"
        }
    }

    /// 这个算法支持哪些放大倍数。
    var supportedFactors: [Int] {
        switch self {
        case .neural: return [4]
        case .lanczos, .bicubic, .nearest: return [2, 3, 4]
        }
    }

    /// 是否需要下载模型才能用（只有神经网络超分需要）。
    var needsModelDownload: Bool { self == .neural }
}

// MARK: - 错误

/// 超分失败。
enum UpscaleError: LocalizedError {
    /// 图像读不出来。
    case cannotDecodeImage
    /// 图像没有像素尺寸。
    case invalidDimensions
    /// 神经网络超分不支持这个倍数。
    case unsupportedFactor(Int)
    /// 神经网络超分不支持这么大的输入。
    case inputTooLarge(width: Int, height: Int, limit: Int)
    /// 系统不支持神经网络超分（老系统或没有对应硬件）。
    case neuralNotSupported
    /// 模型还没下载完。
    case modelNotReady(availablePercent: Float)
    /// VideoToolbox 那边出的错。
    case videoToolbox(String)
    /// CoreImage 那边出的错。
    case coreImage(String)

    var errorDescription: String? {
        switch self {
        case .cannotDecodeImage:
            return "读不出这张图 —— 可能不是图片文件，或者已经损坏。"
        case .invalidDimensions:
            return "这张图的尺寸读不出来。"
        case .unsupportedFactor(let factor):
            return "神经网络超分只支持 4 倍，\(factor) 倍不支持。换别的算法可以用。"
        case .inputTooLarge(let w, let h, let limit):
            return "神经网络超分的输入边长上限是 \(limit) 像素，这张图是 \(w)×\(h)。先用别的算法缩小，或者换成 Lanczos。"
        case .neuralNotSupported:
            return "这台机器的系统不支持神经网络超分。换 Lanczos 或双三次。"
        case .modelNotReady(let percent):
            return "神经网络模型还没下载完（\(Int(percent * 100))%）。等下载完再试。"
        case .videoToolbox(let reason):
            return "系统超分处理失败：\(reason)"
        case .coreImage(let reason):
            return "图像处理失败：\(reason)"
        }
    }
}

// MARK: - 尺寸

/// 输出尺寸。算的时候要防溢出。
struct UpscaleSize: Equatable {
    let width: Int
    let height: Int

    var pixelCount: Int { width * height }
}

/// 尺寸换算。纯逻辑，可单独测。
enum UpscaleGeometry {
    /// 按倍数算目标尺寸。
    ///
    /// **上限保护**：目标边长不超过 8192 像素，总像素不超过 4000 万。
    /// 超过就报错而不是默默截断 —— 截断出来的图跟用户要的不是一个东西。
    static func outputSize(width: Int, height: Int, factor: Int) throws -> UpscaleSize {
        guard width > 0, height > 0 else { throw UpscaleError.invalidDimensions }
        guard factor >= 1 else { throw UpscaleError.unsupportedFactor(factor) }

        let targetWidth = width * factor
        let targetHeight = height * factor
        guard targetWidth <= 8192, targetHeight <= 8192,
              targetWidth * targetHeight <= 40_000_000 else {
            throw UpscaleError.coreImage(
                String(format: "放大后是 %d×%d，超出本工具的处理上限（边长 8192、总像素 4000 万）。",
                       targetWidth, targetHeight))
        }
        return UpscaleSize(width: targetWidth, height: targetHeight)
    }
}

// MARK: - 主入口

/// 图片超分。
enum ImageUpscaler {

    /// 神经网络超分的输入边长上限（VideoToolbox 文档：图片输入最大 1920）。
    static let neuralInputLimit = 1920

    /// 放大一张图。
    ///
    /// - Parameters:
    ///   - image: 原图。
    ///   - method: 算法。
    ///   - factor: 放大倍数。
    static func upscale(
        image: CGImage,
        method: UpscaleMethod,
        factor: Int
    ) async throws -> CGImage {
        let size = try UpscaleGeometry.outputSize(
            width: image.width, height: image.height, factor: factor)

        switch method {
        case .neural:
            return try await neuralUpscale(image: image, factor: factor, target: size)
        case .lanczos:
            return try resample(image: image, target: size, filter: .lanczos)
        case .bicubic:
            return try resample(image: image, target: size, filter: .bicubic)
        case .nearest:
            return try resample(image: image, target: size, filter: .nearest)
        }
    }

    // MARK: 神经网络超分

    /// 走 VideoToolbox 的 `VTSuperResolutionScaler`。
    ///
    /// 整条链是异步的：`process(parameters:completionHandler:)` 有回调版本，
    /// 用 `withCheckedThrowingContinuation` 包成 async。
    private static func neuralUpscale(
        image: CGImage,
        factor: Int,
        target: UpscaleSize
    ) async throws -> CGImage {
        guard VTSuperResolutionScalerConfiguration.isSupported else {
            throw UpscaleError.neuralNotSupported
        }
        guard factor == 4 else {
            throw UpscaleError.unsupportedFactor(factor)
        }
        // VideoToolbox 的图片输入上限是边长 1920。
        guard image.width <= neuralInputLimit, image.height <= neuralInputLimit else {
            throw UpscaleError.inputTooLarge(
                width: image.width, height: image.height, limit: neuralInputLimit)
        }

        guard let config = VTSuperResolutionScalerConfiguration(
            frameWidth: image.width,
            frameHeight: image.height,
            scaleFactor: factor,
            inputType: .image,
            usePrecomputedFlow: false,
            qualityPrioritization: .normal,
            revision: VTSuperResolutionScalerConfiguration.defaultRevision
        ) else {
            throw UpscaleError.videoToolbox("系统不接受这组参数（\(image.width)×\(image.height)）。")
        }

        // 模型没下载完就早退，别浪费一趟。
        if config.configurationModelStatus == .downloadRequired {
            throw UpscaleError.modelNotReady(
                availablePercent: config.configurationModelPercentageAvailable)
        }

        // 源图 → pixel buffer
        guard let sourceBuffer = makePixelBuffer(from: image) else {
            throw UpscaleError.videoToolbox("源图转成像素缓冲失败。")
        }
        // 目标缓冲
        guard let destinationBuffer = makePixelBuffer(width: target.width, height: target.height) else {
            throw UpscaleError.videoToolbox("目标像素缓冲分配失败。")
        }

        guard let sourceFrame = VTFrameProcessorFrame(
            buffer: sourceBuffer,
            presentationTimeStamp: .zero
        ) else {
            throw UpscaleError.videoToolbox("源帧创建失败。")
        }
        guard let destinationFrame = VTFrameProcessorFrame(
            buffer: destinationBuffer,
            presentationTimeStamp: .zero
        ) else {
            throw UpscaleError.videoToolbox("目标帧创建失败。")
        }

        guard let parameters = VTSuperResolutionScalerParameters(
            sourceFrame: sourceFrame,
            previousFrame: nil,
            previousOutputFrame: nil,
            opticalFlow: nil,
            submissionMode: .sequential,
            destinationFrame: destinationFrame
        ) else {
            throw UpscaleError.videoToolbox("处理参数创建失败。")
        }

        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: config)
        } catch {
            throw UpscaleError.videoToolbox(error.localizedDescription)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            processor.process(parameters: parameters) { _, error in
                if let error {
                    continuation.resume(throwing: UpscaleError.videoToolbox(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }

        processor.endSession()

        guard let output = makeCGImage(from: destinationBuffer) else {
            throw UpscaleError.videoToolbox("结果转成图片失败。")
        }
        return output
    }

    // MARK: 插值超分

    /// 走 CoreGraphics / CoreImage 的重采样。
    ///
    /// **三种插值走两条路**，这是实测出来的：
    ///
    /// - Lanczos → CoreImage 的 `CILanczosScaleTransform`。这是 CoreImage 里
    ///   唯一的缩放类滤镜，质量最好。
    /// - 双三次 → CoreGraphics 的 `kCGInterpolationHigh`（高质量插值，双三次）。
    /// - 最近邻 → CoreGraphics 的 `kCGInterpolationNone`（不插值，只复制像素）。
    ///
    /// CoreImage **没有**独立的 bicubic / nearest 缩放滤镜 ——
    /// `CICubicTransform` 和 `CINearestNeighborScale` 实测都不存在，
    /// `applyingFilter` 对不存在的滤镜名会静默返回空图（表现为放大后全黑）。
    ///
    /// CoreGraphics 那条路直接 `CGContext.draw(_:in:)`，不经过 CoreImage，
    /// 也就不经过 pixel buffer，少一道转换。
    private static func resample(
        image: CGImage,
        target: UpscaleSize,
        filter: ResampleFilter
    ) throws -> CGImage {
        switch filter {
        case .lanczos:
            return try lanczosResample(image: image, target: target)
        case .bicubic:
            return try drawResample(image: image, target: target,
                                    interpolation: .high)
        case .nearest:
            return try drawResample(image: image, target: target,
                                    interpolation: .none)
        }
    }

    /// CoreImage Lanczos 路径。
    ///
    /// 滤镜本身不做缩放（`inputScale` = 1），缩放靠后面的 transform 一步到位 ——
    /// 一次变换比「先滤镜放大再滤镜缩放」少一道重采样，细节损失更小。
    private static func lanczosResample(image: CGImage, target: UpscaleSize) throws -> CGImage {
        let source = CIImage(cgImage: image)
        let output = source.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: 1.0,
            kCIInputAspectRatioKey: 1.0
        ])

        let scaled = output.transformed(by: CGAffineTransform(
            scaleX: CGFloat(target.width) / CGFloat(image.width),
            y: CGFloat(target.height) / CGFloat(image.height)))

        guard let destination = makePixelBuffer(width: target.width, height: target.height) else {
            throw UpscaleError.coreImage("目标像素缓冲分配失败。")
        }

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        ciContext.render(scaled,
                         to: destination,
                         bounds: CGRect(x: 0, y: 0,
                                        width: target.width, height: target.height),
                         colorSpace: CGColorSpaceCreateDeviceRGB())

        guard let result = makeCGImage(from: destination) else {
            throw UpscaleError.coreImage("渲染结果转成图片失败。")
        }
        return result
    }

    /// CoreGraphics 直接绘制路径。
    ///
    /// `CGContext` 的插值质量决定了用哪种插值核：
    /// `.none` = 不插值（最近邻），`.high` = 高质量（双三次）。
    private static func drawResample(
        image: CGImage,
        target: UpscaleSize,
        interpolation: CGInterpolationQuality
    ) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: target.width,
            height: target.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw UpscaleError.coreImage("无法创建目标画布。")
        }
        context.interpolationQuality = interpolation
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: target.width, height: target.height))
        guard let result = context.makeImage() else {
            throw UpscaleError.coreImage("渲染结果为空。")
        }
        return result
    }

    /// 插值方式。
    enum ResampleFilter {
        case lanczos
        case bicubic
        case nearest
    }

    // MARK: 像素缓冲

    /// 把 CGImage 画进一个 BGRA 的 IOSurface-backed pixel buffer。
    static func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// 分配一块 BGRA 的 IOSurface-backed pixel buffer。
    static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer)
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// pixel buffer → CGImage。
    static func makeCGImage(from buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }
}

// MARK: - 文件读写

extension ImageUpscaler {

    /// 从文件读图。
    static func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw UpscaleError.cannotDecodeImage
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw UpscaleError.cannotDecodeImage
        }
        return image
    }

    /// 把图写成文件。
    ///
    /// 用 PNG（无损）。JPEG 的话，图片本身已经被有损压缩过一遍，
    /// 再存一次 JPEG 会糊成两代 —— 那是用户不想要的。
    static func writeImage(_ image: CGImage, to url: URL) throws {
        let type = UTType.png.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type, 1, nil) else {
            throw UpscaleError.coreImage("无法创建输出文件。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw UpscaleError.coreImage("写入输出文件失败。")
        }
    }

    /// 生成默认输出文件名：`原名@4x.png`。
    static func suggestedOutputName(for inputURL: URL, factor: Int) -> String {
        let base = inputURL.deletingPathExtension().lastPathComponent
        return "\(base)@\(factor)x.png"
    }
}
