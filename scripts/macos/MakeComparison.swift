// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import CoreImage
import CoreText
import Foundation
import VideoToolbox

private let transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
private let primaries = kCVImageBufferColorPrimaries_ITU_R_2020 as String
private let matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
private let pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
private let frameStep = CMTime(value: 1001, timescale: 60000)

private final class HDRWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let pixels: AVAssetWriterInputPixelBufferAdaptor

    init(url: URL, width: Int, height: Int, bitrate: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoAverageBitRateKey: bitrate,
                AVVideoAllowFrameReorderingKey: false
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        ])
        input.mediaTimeScale = 60000
        pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw MediaProblem("Cannot add HEVC video track") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaProblem("Cannot start HEVC encoder") }
        writer.startSession(atSourceTime: .zero)
    }

    deinit {
        if writer.status == .writing { writer.cancelWriting() }
    }

    func append(_ buffer: CVPixelBuffer, at pts: CMTime) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                throw writer.error ?? MediaProblem("Writer stopped accepting frames")
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard pixels.append(buffer, withPresentationTime: pts) else {
            throw writer.error ?? MediaProblem("Cannot append pixel buffer")
        }
    }

    func finish(at end: CMTime) throws {
        writer.endSession(atSourceTime: end)
        input.markAsFinished()
        let completed = DispatchSemaphore(value: 0)
        writer.finishWriting { completed.signal() }
        guard completed.wait(timeout: .now() + 80) == .success, writer.status == .completed else {
            throw writer.error ?? MediaProblem("HEVC writer did not finish")
        }
    }
}

@main
private struct MakeBeforeAfter {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data(("ERROR " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { throw MediaProblem("用法：make-comparison SOURCE PROCESSED OUTPUT") }
        let original = try await MediaFile.open(URL(fileURLWithPath: args[1]))
        let enhanced = try await MediaFile.open(URL(fileURLWithPath: args[2]))
        let isUpscale = original.size.width == 1920
        guard original.transform.isIdentity, enhanced.transform.isIdentity,
              original.hdrTransfer == transfer, enhanced.hdrTransfer == transfer,
              enhanced.size == CGSize(width: 3840, height: 2160),
              abs(Double(original.frameRate) - 30000.0 / 1001) < 0.05,
              abs(Double(enhanced.frameRate) - 60000.0 / 1001) < 0.05,
              original.size == CGSize(width: 1920, height: 1080) || original.size == enhanced.size,
              abs(original.duration.seconds - enhanced.duration.seconds) < 0.04,
              original.audioTracks.count > 0 else {
            throw MediaProblem("Unexpected input resolution, cadence, transform or color")
        }
        let range = try await enhanced.video.load(.timeRange)
        let sourceRange = try await original.video.load(.timeRange)
        guard abs((range.duration - sourceRange.duration).seconds) < 0.001,
              abs((range.start - sourceRange.start).seconds) < 0.001 else {
            throw MediaProblem("两段视频的起点或时长不一致")
        }
        try compose(original, enhanced, isUpscale, videoStart: range.start, videoEnd: range.end,
                    output: URL(fileURLWithPath: args[3]))
    }

    private static func compose(_ original: MediaFile, _ enhanced: MediaFile, _ upscale: Bool,
                                videoStart: CMTime, videoEnd: CMTime, output: URL) throws {
        let width = 3840
        let height = 2160
        let fullSize = CGSize(width: 1920, height: 1080)
        let fullY = 952.0
        let detailSize = CGSize(width: 1920, height: 892)
        let detailBandY = 892.0
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let originalFrames = try VideoFrames(media: original, effects: Effects(preserveHDR: true), from: .zero)
        let enhancedFrames = try VideoFrames(media: enhanced, effects: Effects(preserveHDR: true), from: .zero)
        let converter = try VideoPixelConverter(width: width, height: height, hdr: HDRColour(transfer: transfer),
                                                forInterpolation: false)
        let writer = try HDRWriter(url: output, width: width, height: height, bitrate: 60_000_000)
        let title = try labelStrip(
            height: 128,
            left: upscale ? "处理前  ·  1080p 29.97 fps" : "处理前  ·  4K 29.97 fps",
            right: upscale ? "处理后  ·  补帧＋放大至 4K 59.94 fps" : "处理后  ·  原生 4K 补帧至 59.94 fps",
            titleSize: 43, shift: 2032
        )
        let detailTitle = try labelStrip(
            height: 60,
            left: upscale ? "同一区域放大显示  ·  1080p 源片" : "同一区域  ·  4K 像素细节",
            right: "同一区域  ·  处理后 4K 像素细节",
            titleSize: 29, shift: detailBandY
        )
        let divider = CIImage(color: CIColor(red: 0.30, green: 0.32, blue: 0.36))
            .cropped(to: CGRect(x: 1919, y: 0, width: 2, height: height))
        let background = CIImage(color: .black).cropped(to: bounds)
        let widthScale = 3840.0 / original.size.width
        var reference = try originalFrames.next()
        var nextReference = try originalFrames.next()
        var count = 0
        var maximumOffset = 0.0
        var last = CMTime.invalid

        while try autoreleasepool(invoking: {
            guard let changed = try enhancedFrames.next() else { return false }
            // Hold each source frame until its next PTS. Odd output frames show the generated frame next to that hold.
            while let upcoming = nextReference, upcoming.pts <= changed.pts + CMTime(value: 1, timescale: 120_000) {
                reference = upcoming
                nextReference = try originalFrames.next()
            }
            guard let matched = reference else { throw MediaProblem("源片缺少对应帧") }
            let offset = (changed.pts - matched.pts).seconds
            let expectedOffset = count.isMultiple(of: 2) ? 0 : frameStep.seconds
            let error = abs(offset - expectedOffset)
            guard error < 0.0002, !last.isValid || changed.pts > last else {
                throw MediaProblem("第 \(count) 帧时间戳未对齐，误差 \(error) 秒")
            }
            maximumOffset = max(maximumOffset, error)
            let source = CIImage(cvPixelBuffer: matched.buffer, options: [.toneMapHDRtoSDR: false])
            let processed = CIImage(cvPixelBuffer: changed.buffer, options: [.toneMapHDRtoSDR: false])
            let fullLeft = fit(source, size: fullSize).transformed(by: .init(translationX: 0, y: fullY))
            let fullRight = fit(processed, size: fullSize).transformed(by: .init(translationX: 1920, y: fullY))
            let sourceAt4K = source.transformed(by: .init(scaleX: widthScale, y: widthScale))
            let detailLeft = cropDetail(sourceAt4K, size: detailSize)
            let detailRight = cropDetail(processed, size: detailSize).transformed(by: .init(translationX: 1920, y: 0))
            let picture = [fullLeft, fullRight, detailLeft, detailRight, title, detailTitle, divider].reduce(background) {
                $1.composited(over: $0)
            }
            let rendered = try converter.convert(picture)
            guard validHDR(rendered, width: width, height: height) else { throw MediaProblem("HDR tags missing") }
            try writer.append(rendered, at: changed.pts)
            last = changed.pts
            count += 1
            if count.isMultiple(of: 600) {
                print("\(count) comparison frames")
                fflush(stdout)
            }
            return true
        }) {}
        let expectedCount = Int(((videoEnd - videoStart).seconds / frameStep.seconds).rounded())
        guard count == expectedCount, last.isValid else { throw MediaProblem("输出帧数应为 \(expectedCount)，实际为 \(count)") }
        try writer.finish(at: videoEnd > last ? videoEnd : last + frameStep)
        print("COMPARISON_FRAMES=\(count) MAX_SYNC_ERROR_MS=\(maximumOffset * 1000)")
    }

    private static func fit(_ image: CIImage, size: CGSize) -> CIImage {
        let ratio = size.width / image.extent.width
        return image.transformed(by: .init(scaleX: ratio, y: ratio))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func cropDetail(_ image: CIImage, size: CGSize) -> CIImage {
        let origin = CGPoint(x: (3840 - size.width) / 2, y: (2160 - size.height) * 0.42)
        return image.cropped(to: CGRect(origin: origin, size: size))
            .transformed(by: .init(translationX: -origin.x, y: -origin.y))
    }

    private static func labelStrip(height: Int, left: String, right: String,
                                   titleSize: CGFloat, shift: CGFloat) throws -> CIImage {
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let canvas = CGContext(data: nil, width: 3840, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MediaProblem("Cannot create labels")
        }
        canvas.setFillColor(red: 0.065, green: 0.075, blue: 0.098, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: 3840, height: height))
        let font = CTFontCreateWithName("PingFangSC-Medium" as CFString, titleSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.95, green: 0.96, blue: 0.99, alpha: 1)
        ]
        for (text, x) in [(left, 48.0), (right, 1968.0)] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            canvas.textPosition = CGPoint(x: x, y: (CGFloat(height) - titleSize) * 0.5 + 5)
            CTLineDraw(line, canvas)
        }
        guard let image = canvas.makeImage() else { throw MediaProblem("Cannot render labels") }
        return CIImage(cgImage: image).transformed(by: .init(translationX: 0, y: shift))
    }

    private static func validHDR(_ buffer: CVPixelBuffer, width: Int, height: Int) -> Bool {
        CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height &&
        CVPixelBufferGetPixelFormatType(buffer) == pixelFormat &&
        CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String == transfer &&
        CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String == primaries &&
        CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String == matrix
    }

}
