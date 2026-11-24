// SPDX-License-Identifier: GPL-3.0-only
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct StillImage {
    let image: CIImage
    var size: CGSize { image.extent.size }

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = metadata[kCGImagePropertyPixelWidth as String] as? Int,
              let height = metadata[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 12_000, height <= 12_000 else {
            throw MediaProblem("无法读取图片尺寸，或图片边长超出 12000 像素。")
        }
        guard let decoded = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .toneMapHDRtoSDR: true]) else {
            throw MediaProblem("无法解码该图片。")
        }
        image = decoded.transformed(by: .init(translationX: -decoded.extent.minX, y: -decoded.extent.minY))
    }

    func render(effects: Effects) throws -> CGImage {
        let width = size.width * effects.scale
        let height = size.height * effects.scale
        guard width <= 12_000, height <= 12_000, width * height <= 48_000_000 else {
            throw MediaProblem("图片输出过大。请降低超分倍率。")
        }
        let renderer = try VideoRenderer(encoded: size, oriented: size, orientation: .identity,
                                         hdrTransfer: nil, effects: effects, stillImage: true)
        let buffer = try renderer.renderImage(image)
        let result = CIImage(cvPixelBuffer: buffer)
        guard let colour = CGColorSpace(name: CGColorSpace.sRGB),
              let output = renderer.context.createCGImage(result, from: result.extent, format: .RGBA8, colorSpace: colour) else {
            throw MediaProblem("无法生成处理后的图片。")
        }
        return output
    }

    static func savePNG(_ image: CGImage, to url: URL) throws {
        let bytes = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(bytes as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw MediaProblem("无法创建 PNG 编码器。")
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw MediaProblem("无法编码 PNG。") }
        try (bytes as Data).write(to: url, options: .atomic)
    }
}
