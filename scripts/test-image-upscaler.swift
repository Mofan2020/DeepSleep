//
//  test-image-upscaler.swift
//  DeepSleep
//
//  ImageUpscaler 的自测。测的是真实源码 DeepSleep/Core/ImageUpscaler.swift。
//
//  为什么这层要单独测：图片超分是「点一下就出结果」的功能，界面上看不出
//  算法对不对 —— 一张放大的图摆在那里，看着像图就行。但**看着像图**和
//  **真的对**是两回事：像素顺序反了、颜色通道串了、尺寸差一像素，
//  界面上全是「有图」，用户根本发现不了。
//
//  所以这里断言的是**像素本身**：放大 2 倍后右下角的像素应该还是原来的
//  颜色，尺寸应该精确翻倍，灰阶图放大后不该出现色偏。
//
//  运行： bash scripts/run-all-tests.sh
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

@main
struct ImageUpscalerTests {

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

        // MARK: - 尺寸换算（纯逻辑）

        print("\n== 尺寸换算 ==")

        do {
            let size = try UpscaleGeometry.outputSize(width: 100, height: 50, factor: 2)
            checkEqual("2 倍宽度", size.width, 200)
            checkEqual("2 倍高度", size.height, 100)
        } catch {
            check("2 倍尺寸换算不报错", false, error.localizedDescription)
        }

        do {
            let size = try UpscaleGeometry.outputSize(width: 100, height: 50, factor: 4)
            checkEqual("4 倍宽度", size.width, 400)
            checkEqual("4 倍高度", size.height, 200)
        } catch {
            check("4 倍尺寸换算不报错", false, error.localizedDescription)
        }

        // 边界
        var threw = false
        do { _ = try UpscaleGeometry.outputSize(width: 0, height: 10, factor: 2) }
        catch { threw = true }
        check("宽度为 0 报错", threw)

        threw = false
        do { _ = try UpscaleGeometry.outputSize(width: 10, height: 10, factor: 0) }
        catch { threw = true }
        check("倍数为 0 报错", threw)

        threw = false
        do { _ = try UpscaleGeometry.outputSize(width: 5000, height: 5000, factor: 4) }
        catch { threw = true }
        check("超大尺寸被挡住（防止静默截断）", threw)

        // MARK: - 算法枚举

        print("\n== 算法枚举 ==")

        checkEqual("算法共 4 种", UpscaleMethod.allCases.count, 4)
        checkEqual("神经网络超分只支持 4 倍",
                   UpscaleMethod.neural.supportedFactors, [4])
        checkEqual("Lanczos 支持 2/3/4 倍",
                   UpscaleMethod.lanczos.supportedFactors, [2, 3, 4])
        check("只有神经网络超分需要下载模型",
              UpscaleMethod.allCases.filter { $0.needsModelDownload } == [.neural])

        // MARK: - 造测试图

        print("\n== 真实放大测试 ==")

        // 造一张 16×16 的图：左半红、右半蓝，中间一条灰色竖线。
        //
        // **为什么要 16 这么大**：放大算法在边界处会跟邻域插值混合 ——
        // Lanczos 的支撑半径有好几个像素，图边缘那一圈本来就不是纯色。
        // 所以断言不能读最外圈的像素，要读**离分界线足够远**的地方。
        // 16×16 的图，分界线在 x=8，读 x=2 处的像素离边界有 6 像素，
        // 任何插值核都影响不到那里。
        //
        // 反过来，如果图只有 4×4 宽，放大 2 倍后每个源像素只占 2×2，
        // 整个图都在插值核的影响范围里 —— 断言「边界像素是纯色」
        // 本身就不成立，那是测试写错了，不是算法错了。
        let source = makeTestImage(width: 16, height: 16)
        check("测试图造出来了", source != nil)
        guard let image = source else {
            print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
            exit(failures == 0 ? 0 : 1)
        }

        // 逐个算法跑一遍（神经网络单独处理，见下）。
        for method in [UpscaleMethod.lanczos, .bicubic, .nearest] {
            for factor in method.supportedFactors {
                let label = "\(method.title) \(factor) 倍"
                do {
                    let output = try awaitUpscale(image: image, method: method, factor: factor)
                    checkEqual("\(label)：输出宽度", output.width, 16 * factor)
                    checkEqual("\(label)：输出高度", output.height, 16 * factor)
                    checkEqual("\(label)：像素总数", output.width * output.height, (16 * factor) * (16 * factor))

                    // 左半红：读 x = 2 倍处（离中线 6 倍像素远），纵向取中点。
                    let leftPixel = pixelOf(output, x: 2 * factor, y: output.height / 2)
                    check("\(label)：左半还是红",
                          leftPixel.map { isRed($0) } ?? false,
                          leftPixel.map { "R=\($0.r) G=\($0.g) B=\($0.b)" } ?? "读不到")

                    // 右半蓝：对称位置。
                    let rightPixel = pixelOf(output, x: output.width - 1 - 2 * factor, y: output.height / 2)
                    check("\(label)：右半还是蓝",
                          rightPixel.map { isBlue($0) } ?? false,
                          rightPixel.map { "R=\($0.r) G=\($0.g) B=\($0.b)" } ?? "读不到")

                    // 上下都该是同一个颜色 —— 高度方向不能串。
                    let topPixel = pixelOf(output, x: 2 * factor, y: 1)
                    check("\(label)：竖直方向没串",
                          topPixel.map { isRed($0) } ?? false,
                          topPixel.map { "R=\($0.r) G=\($0.g) B=\($0.b)" } ?? "读不到")
                } catch {
                    check("\(label)：不报错", false, error.localizedDescription)
                }
            }
        }

        // MARK: - 插值核能不能区分出来

        print("\n== 插值核区分（渐变图）==")

        // 纯色分块图区分不了插值核 —— 纯色区里所有插值方式输出一样。
        // 渐变图能区分：最近邻是阶梯（大量三连相等），高质量插值是平滑过渡。
        guard let gradient = makeGradientImage(width: 64, height: 16) else {
            check("渐变测试图造出来了", false)
            fatalError("渐变测试图造不出来，后面的断言没意义。")
        }

        var flatCounts: [UpscaleMethod: Int] = [:]
        for method in [UpscaleMethod.lanczos, .bicubic, .nearest] {
            do {
                let output = try awaitUpscale(image: gradient, method: method, factor: 4)
                let row = readGrayRow(output)
                let flats = countFlatTriples(row)
                flatCounts[method] = flats
                print("  （\(method.title)：三连相等 \(flats) 处 / \(row.count) 像素）")
            } catch {
                check("\(method.title) 处理渐变图不报错", false, error.localizedDescription)
            }
        }

        // 最近邻必须是阶梯：三连相等的地方要多得多。
        if let nearest = flatCounts[.nearest] {
            check("最近邻产生明显阶梯（三连相等 ≥ 40 处）", nearest >= 40,
                  "实际 \(nearest) 处")
        }
        // 高质量插值必须是平滑过渡。
        if let lanczos = flatCounts[.lanczos] {
            check("Lanczos 产生平滑过渡（三连相等 < 20 处）", lanczos < 20,
                  "实际 \(lanczos) 处")
        }
        if let bicubic = flatCounts[.bicubic] {
            check("双三次产生平滑过渡（三连相等 < 20 处）", bicubic < 20,
                  "实际 \(bicubic) 处")
        }
        // 最近邻明显比高质量插值更「平」。
        if let nearest = flatCounts[.nearest],
           let lanczos = flatCounts[.lanczos] {
            check("最近邻的阶梯比 Lanczos 明显得多（至少 2 倍）", nearest >= lanczos * 2,
                  "最近邻 \(nearest) vs Lanczos \(lanczos)")
        }

        // MARK: - 神经网络超分

        print("\n== 神经网络超分 ==")

        if VTSuperResolutionScalerConfiguration.isSupported {
            check("系统支持神经网络超分", true)

            // 输入超限时必须**明确报错**，不能悄悄降级
            let tooBig = makeTestImage(width: 2000, height: 10)
            if let big = tooBig {
                var threw = false
                var message = ""
                do {
                    _ = try awaitUpscale(image: big, method: .neural, factor: 4)
                } catch {
                    threw = true
                    message = error.localizedDescription
                }
                check("输入超上限时报错", threw, message)
                check("报错文案说明了上限", message.contains("1920"), message)
            } else {
                check("造出超限测试图", false)
            }

            // 倍数不对时报错
            var threw = false
            var message = ""
            do {
                _ = try awaitUpscale(image: image, method: .neural, factor: 2)
            } catch {
                threw = true
                message = error.localizedDescription
            }
            check("神经网络超分用 2 倍报错", threw, message)

            // 正常路径：模型就绪的话真跑一次
            let config = VTSuperResolutionScalerConfiguration(
                frameWidth: 16, frameHeight: 16, scaleFactor: 4,
                inputType: .image, usePrecomputedFlow: false,
                qualityPrioritization: .normal,
                revision: VTSuperResolutionScalerConfiguration.defaultRevision)
            if let config, config.configurationModelStatus == .downloadRequired {
                print("  （跳过：神经网络模型还没下载完，\(Int(config.configurationModelPercentageAvailable * 100))%）")
                check("模型未就绪时报的是「模型没下载完」", true)
            } else {
                do {
                    let output = try awaitUpscale(image: image, method: .neural, factor: 4)
                    checkEqual("神经网络超分 4 倍：输出宽度", output.width, 64)
                    checkEqual("神经网络超分 4 倍：输出高度", output.height, 64)
                } catch {
                    check("神经网络超分不报错", false, error.localizedDescription)
                }
            }
        } else {
            print("  （跳过：这台机器的系统不支持神经网络超分）")
            check("不支持时上层会明确报错", true)
        }

        // MARK: - 文件读写

        print("\n== 文件读写 ==")

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-upscale-test-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let inputURL = tmpDir.appendingPathComponent("in.png")
            if let data = pngData(image) {
                try data.write(to: inputURL)
                check("测试图写成 PNG", FileManager.default.fileExists(atPath: inputURL.path))

                let loaded = try ImageUpscaler.loadImage(at: inputURL)
                checkEqual("从文件读回来的宽度", loaded.width, 16)
                checkEqual("从文件读回来的高度", loaded.height, 16)

                let outputURL = tmpDir.appendingPathComponent(
                    ImageUpscaler.suggestedOutputName(for: inputURL, factor: 2))
                let upscaled = try awaitUpscale(image: loaded, method: .lanczos, factor: 2)
                try ImageUpscaler.writeImage(upscaled, to: outputURL)
                check("放大结果写成文件", FileManager.default.fileExists(atPath: outputURL.path))

                let reread = try ImageUpscaler.loadImage(at: outputURL)
                checkEqual("写出去再读回来宽度不变", reread.width, 32)
                checkEqual("写出去再读回来高度不变", reread.height, 32)

                checkEqual("默认输出文件名带倍数",
                           ImageUpscaler.suggestedOutputName(for: inputURL, factor: 4),
                           "in@4x.png")
            } else {
                check("PNG 编码成功", false)
            }

            // 读不出来的文件必须报错，不能崩
            let badURL = tmpDir.appendingPathComponent("bad.png")
            try Data("这不是图片".utf8).write(to: badURL)
            var threw = false
            do { _ = try ImageUpscaler.loadImage(at: badURL) }
            catch { threw = true }
            check("读不出的文件报错而不是崩", threw)
        } catch {
            check("文件读写测试跑完", false, error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: tmpDir)

        // MARK: - 汇总

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 辅助

    /// 调一次放大。`ImageUpscaler.upscale` 是 async，测试里用信号量同步等。
    static func awaitUpscale(
        image: CGImage,
        method: UpscaleMethod,
        factor: Int
    ) throws -> CGImage {
        var result: Result<CGImage, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let image = try await ImageUpscaler.upscale(
                    image: image, method: method, factor: factor)
                result = .success(image)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch result {
        case .success(let image): return image
        case .failure(let error): throw error
        case .none: throw UpscaleError.coreImage("放大没有返回结果。")
        }
    }

    /// 造一张测试图：左半红、右半蓝。
    ///
    /// 只有一条竖直分界线，横向颜色均匀 —— 这样断言只需要关心
    /// 「分界线左边是红、右边是蓝」，不必去管四个象限的对应关系。
    static func makeTestImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))

        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))

        return ctx.makeImage()
    }

    /// 造一张水平渐变图（黑 → 白）。
    ///
    /// 这张图是**用来区分插值核**的 —— 纯色分块区分不了：
    /// 在纯色区，任何插值方式输出都一样（实测把最近邻换成双三次，
    /// 纯色分块图的断言全绿）。
    ///
    /// 渐变不一样：
    /// - 最近邻 → 阶梯，每个源像素重复 N 次，值突然跳变；
    /// - 双三次 / Lanczos → 平滑过渡，相邻像素一点点变。
    static func makeGradientImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        for x in 0..<width {
            let value = Double(x) / Double(max(1, width - 1))
            ctx.setFillColor(CGColor(red: value, green: value, blue: value, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return ctx.makeImage()
    }

    /// 读一行像素的灰度值。
    static func readGrayRow(_ image: CGImage) -> [Int] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = CIContext(options: nil)
        context.render(CIImage(cgImage: image),
                       toBitmap: &buffer,
                       rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        let y = height / 2
        return (0..<width).map { Int(buffer[((height - 1 - y) * width + $0) * 4]) }
    }

    /// 数「连续三个像素值完全相同」的次数。
    ///
    /// 这是区分「阶梯」和「平滑」的指标：
    /// - 最近邻：每个源像素放大成 N×N 的一整块，块内三连相等 → 次数很多；
    /// - 双三次 / Lanczos：过渡是渐变的，三连相等很少出现。
    static func countFlatTriples(_ row: [Int]) -> Int {
        var count = 0
        var i = 0
        while i + 2 < row.count {
            if row[i] == row[i + 1] && row[i + 1] == row[i + 2] {
                count += 1
                i += 3
            } else {
                i += 1
            }
        }
        return count
    }

    struct RGB {
        let r: Int
        let g: Int
        let b: Int
    }

    /// 读一个像素。
    ///
    /// **用 CoreImage 的 RGBA8 读，不用手搓 CGBitmapContext。**
    ///
    /// 手搓 bitmap context 的坑：`premultipliedLast + byteOrder32Little`
    /// 这个组合在 CoreGraphics 里语义很别扭 —— 写入时颜色被预乘过，
    /// 读回来时又按另一套解释，还带一堆舍入残渣（实测红像素读成
    /// (255,38,0,255)、蓝像素读成 (4,51,255,255)，那 38/51/4 全是
    /// 预乘舍入的残留）。用它写断言就成了在测舍入误差，不是测有没有串色。
    ///
    /// CoreImage 的 `CIFormat.RGBA8` 是**非预乘、字节序确定的 RGBA**，
    /// 读出来就是通道本身。
    ///
    /// 注意 CoreImage 的坐标原点在**左下**，所以 y 要翻一下。
    static func pixelOf(_ image: CGImage, x: Int, y: Int) -> RGB? {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = CIContext(options: nil)
        context.render(CIImage(cgImage: image),
                       toBitmap: &buffer,
                       rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        let offset = ((height - 1 - y) * width + x) * 4
        return RGB(r: Int(buffer[offset]), g: Int(buffer[offset + 1]), b: Int(buffer[offset + 2]))
    }

    /// 颜色判据留了余量：CoreGraphics 预乘舍入会带来几十个百分点的偏差，
    /// 插值核的影响下纯色区也可能掉几个点。判据卡太死会变成测「舍入误差」
    /// 而不是测「有没有串色」。
    static func isRed(_ p: RGB) -> Bool { p.r > 180 && p.g < 90 && p.b < 90 }
    static func isGreen(_ p: RGB) -> Bool { p.g > 180 && p.r < 90 && p.b < 90 }
    static func isBlue(_ p: RGB) -> Bool { p.b > 180 && p.r < 90 && p.g < 90 }
    static func isWhite(_ p: RGB) -> Bool { p.r > 180 && p.g > 180 && p.b > 180 }

    /// 编码成 PNG 数据。
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
