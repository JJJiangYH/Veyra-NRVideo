// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import CoreImage
import Foundation
import Metal
import MetalFX
import VideoToolbox

struct MediaProblem: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct MediaFile {
    let url: URL
    let asset: AVURLAsset
    let prepared: TemporaryMedia?
    let video: AVAssetTrack
    let audioTracks: [AVAssetTrack]
    let subtitleCount: Int
    var audio: AVAssetTrack? { audioTracks.first }
    let duration: CMTime
    let transform: CGAffineTransform
    let frameRate: Float
    let size: CGSize
    let hdrTransfer: String?
    var hdr: Bool { hdrTransfer != nil }

    static func open(_ url: URL) async throws -> MediaFile {
        let prepared = try await MediaContainer.preparePlayback(url)
        let asset = AVURLAsset(url: prepared?.url ?? url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaProblem("文件里没有可读取的视频轨道。")
        }
        let formats = try await video.load(.formatDescriptions)
        let hdrTransfer = formats.lazy.compactMap { format in
            CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        }.first { transfer in
            transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String ||
                transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else {
            throw MediaProblem("无法读取这个文件的播放时长。")
        }
        let subtitleTracks = try await asset.loadTracks(withMediaType: .subtitle)
        let textTracks = try await asset.loadTracks(withMediaType: .text)
        return try await MediaFile(
            url: url, asset: asset, prepared: prepared, video: video, audioTracks: asset.loadTracks(withMediaType: .audio),
            subtitleCount: subtitleTracks.count + textTracks.count,
            duration: duration, transform: video.load(.preferredTransform),
            frameRate: video.load(.nominalFrameRate), size: video.load(.naturalSize), hdrTransfer: hdrTransfer
        )
    }

    var orientedSize: CGSize {
        let rect = CGRect(origin: .zero, size: size).applying(transform).standardized
        return rect.size
    }
}

struct Effects: Equatable {
    var scale: Double = 1
    var interpolate = false
    var multiplier = 2
    static let multipliers = [2, 3, 4, 6, 8]
    var capture60To30 = false
    var preserveHDR = false
    var saturation: Float = 1
    var contrast: Float = 1
    var noiseReduction: Float = 0
    var exposure: Float = 0
    var sharpness: Float = 0
    var fxaa = false
    var lookup: CubeLookup?
    var graph: PictureGraph?
    var grade = ColourGrade.identity
    var additionalDenoise: [Float] = []
    var denoiseProtection: [DenoiseRegion] = []

    var denoiseStrengths: [Float] { ([noiseReduction] + additionalDenoise).filter { $0 > 0 } }

    static func == (lhs: Effects, rhs: Effects) -> Bool {
        lhs.scale == rhs.scale && lhs.interpolate == rhs.interpolate && lhs.multiplier == rhs.multiplier && lhs.capture60To30 == rhs.capture60To30 && lhs.preserveHDR == rhs.preserveHDR &&
            lhs.saturation == rhs.saturation && lhs.contrast == rhs.contrast &&
            lhs.noiseReduction == rhs.noiseReduction && lhs.exposure == rhs.exposure && lhs.sharpness == rhs.sharpness && lhs.fxaa == rhs.fxaa && lhs.lookup?.id == rhs.lookup?.id && lhs.graph == rhs.graph && lhs.grade == rhs.grade &&
            lhs.additionalDenoise == rhs.additionalDenoise && lhs.denoiseProtection == rhs.denoiseProtection
    }

    func preview(on refreshRate: Double, sourceRate: Double) -> Effects {
        guard interpolate, sourceRate > 0, refreshRate > 0 else { return self }
        let inputRate = capture60To30 && (55...65).contains(sourceRate) ? sourceRate / 2 : sourceRate
        var result = self
        let budget = max(1, Int(refreshRate * 1.05 / inputRate))
        result.multiplier = Self.multipliers.last(where: { $0 <= min(multiplier, budget) }) ?? 1
        if result.multiplier < 2 { result.interpolate = false }
        return result
    }

    func outputSize(for media: MediaFile) -> CGSize { outputSize(source: media.orientedSize) }

    func outputSize(source: CGSize) -> CGSize {
        let boundedScale = max(1, min(scale, 4096 / max(source.width, source.height)))
        return CGSize(width: max(2, Int(source.width * boundedScale) / 2 * 2),
                      height: max(2, Int(source.height * boundedScale) / 2 * 2))
    }
}

struct CubeLookup {
    let id = UUID()
    let url: URL
    let name: String
    let dimension: Int
    let data: Data
    let minimum: [Float]
    let maximum: [Float]

    init(url: URL) throws {
        let maximumBytes = 24 * 1024 * 1024
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes else {
            throw MediaProblem("LUT 文件太大。")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var dimension = 0
        var values: [Float] = []
        var minDomain: [Float] = [0, 0, 0]
        var maxDomain: [Float] = [1, 1, 1]
        for line in text.split(whereSeparator: \.isNewline) {
            let tokens = line.prefix(while: { $0 != "#" }).split(whereSeparator: \.isWhitespace)
            guard let key = tokens.first else { continue }
            switch key {
            case "TITLE": continue
            case "LUT_3D_SIZE":
                guard dimension == 0, tokens.count == 2, let count = Int(tokens[1]), (2...64).contains(count) else {
                    throw MediaProblem("LUT 必须是 2–64 阶的 3D .cube 文件。")
                }
                dimension = count
                values.reserveCapacity(count * count * count * 4)
            default:
                let fields = key == "DOMAIN_MIN" || key == "DOMAIN_MAX" ? Array(tokens.dropFirst()) : tokens
                let triple = fields.compactMap { Float($0) }
                guard fields.count == 3, triple.count == 3, triple.allSatisfy(\.isFinite) else {
                    throw MediaProblem("LUT 中有无法读取的参数或颜色数据。")
                }
                if key == "DOMAIN_MIN" { minDomain = triple }
                else if key == "DOMAIN_MAX" { maxDomain = triple }
                else {
                    guard dimension > 0, values.count < dimension * dimension * dimension * 4 else {
                        throw MediaProblem("LUT 采样数量与声明不一致。")
                    }
                    values.append(contentsOf: triple)
                    values.append(1)
                }
            }
        }
        guard dimension > 0, values.count == dimension * dimension * dimension * 4,
              zip(minDomain, maxDomain).allSatisfy({ $0 < $1 }) else {
            throw MediaProblem("LUT 数据长度或颜色范围不正确。")
        }
        self.url = url
        self.name = url.deletingPathExtension().lastPathComponent
        self.dimension = dimension
        self.data = values.withUnsafeBytes { Data($0) }
        self.minimum = minDomain
        self.maximum = maxDomain
    }
}

struct ClipReader {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput

    init(media: MediaFile, track: AVAssetTrack, settings: [String: Any], from time: CMTime, until end: CMTime? = nil) throws {
        reader = try AVAssetReader(asset: media.asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaProblem("无法配置文件解码器。") }
        reader.add(output)
        if time > .zero || end != nil {
            reader.timeRange = CMTimeRange(start: time, end: end ?? media.duration)
        }
        guard reader.startReading() else { throw reader.error ?? MediaProblem("无法开始解码。") }
    }

    func next() throws -> CMSampleBuffer? {
        if let sample = output.copyNextSampleBuffer() { return sample }
        if reader.status == .failed { throw reader.error ?? MediaProblem("读取帧失败。") }
        return nil
    }

    static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]
}

struct VideoFrame {
    let buffer: CVPixelBuffer
    let pts: CMTime
    let duration: CMTime
    let generated: Bool
    var protectedSource: CVPixelBuffer? = nil
}

struct DenoiseRegion: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) &&
            x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.0000001 && y + height <= 1.0000001
    }
}

final class VideoFrames {
    private let reader: ClipReader
    private let interpolator: VeyraInterpolation?
    private let expectedInterval: Double
    private let capture60To30: Bool
    private let reduction: NoiseReduction?
    private let protectDenoise: Bool
    private let statistics: PipelineTimings?
    private let interpolationInput: VideoPixelConverter?
    private let usesReducedInterpolationSize: Bool
    private var previousInterpolationInput: CVPixelBuffer?
    private var pending: [VideoFrame] = []
    private var previous: VideoFrame?
    private var previousLuma: [UInt8] = []
    private(set) var sourceCount = 0
    private(set) var skippedCount = 0
    private(set) var generatedCount = 0

    static func canInterpolate(_ media: MediaFile) -> Bool {
        VeyraInterpolation.isSupported && max(media.size.width, media.size.height) <= 4096
            && min(media.size.width, media.size.height) >= 64
    }

    static func interpolationSize(_ media: MediaFile) -> CGSize { interpolationSize(source: media.size) }

    static func interpolationSize(source: CGSize) -> CGSize {
        // Some native 4K configurations crash in the system frame processor.
        // Keep its input within the tested pixel budget, while retaining the
        // native-resolution source frames for display and export.
        let scale = min(1, 1920 / max(source.width, source.height),
                        sqrt((1920 * 1080) / (source.width * source.height)))
        return CGSize(width: Int(source.width * scale) / 2 * 2,
                      height: Int(source.height * scale) / 2 * 2)
    }

    init(media: MediaFile, effects: Effects, from time: CMTime, until end: CMTime? = nil, timings: PipelineTimings? = nil) throws {
        statistics = timings
        let strengths = effects.denoiseStrengths
        reduction = strengths.isEmpty ? nil : NoiseReduction(strengths: strengths, timings: timings)
        protectDenoise = !strengths.isEmpty && !effects.denoiseProtection.isEmpty
        capture60To30 = effects.capture60To30 && media.frameRate >= 55 && media.frameRate <= 65
        let width = Int(media.size.width.rounded())
        let height = Int(media.size.height.rounded())
        let analysis = Self.interpolationSize(media)
        let analysisWidth = Int(analysis.width)
        let analysisHeight = Int(analysis.height)
        usesReducedInterpolationSize = effects.interpolate && (width != analysisWidth || height != analysisHeight)
        let hdr = effects.preserveHDR ? media.hdrTransfer.map(HDRColour.init(transfer:)) : nil
        let quality = hdr != nil || (effects.multiplier != 2 && effects.multiplier != 4)
        if effects.interpolate {
            guard Self.canInterpolate(media), !quality || VeyraInterpolation.isQualitySupported,
                  let backend = VeyraInterpolation(width: analysisWidth, height: analysisHeight,
                                                   quality: quality, multiplier: effects.multiplier) else {
                throw MediaProblem("当前视频尺寸或设备无法启动 VideoToolbox 补帧。")
            }
            interpolator = backend
        } else {
            interpolator = nil
        }
        let requiresConversion = effects.interpolate && (media.hdr || usesReducedInterpolationSize || quality || reduction != nil)
        interpolationInput = try requiresConversion
            ? VideoPixelConverter(width: analysisWidth, height: analysisHeight, hdr: hdr,
                                  forInterpolation: true, floatingPoint: quality) : nil
        expectedInterval = media.frameRate > 0 ? 1 / Double(media.frameRate) : 1 / 24
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: media.hdr
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferExtendedPixelsRightKey as String: (16 - width % 16) % 16,
            kCVPixelBufferExtendedPixelsBottomKey as String: (16 - height % 16) % 16
        ]
        reader = try ClipReader(media: media, track: media.video, settings: settings, from: time, until: end)
    }

    func next() throws -> VideoFrame? {
        if !pending.isEmpty { return pending.removeFirst() }
        while let sample = try nextSourceSample() {
            guard let decoded = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = sample.presentationTimeStamp
            guard pts.isNumeric, previous.map({ pts > $0.pts }) ?? true else { continue }
            sourceCount += 1
            if capture60To30, let previous, (pts - previous.pts).seconds < expectedInterval * 1.5 {
                skippedCount += 1
                continue
            }
            let input = try reduction?.apply(decoded, pts: pts) ?? decoded
            let buffer: CVPixelBuffer
            if let interpolationInput {
                let start = ProcessInfo.processInfo.systemUptime
                buffer = try interpolationInput.convert(input)
                statistics?.record(.interpolationInput, seconds: ProcessInfo.processInfo.systemUptime - start)
            } else {
                buffer = input
            }
            let original = usesReducedInterpolationSize || CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_64RGBAHalf ? input : buffer
            let current = VideoFrame(buffer: original, pts: pts, duration: sample.duration, generated: false,
                                     protectedSource: protectDenoise ? decoded : nil)
            defer { previous = current }
            guard let interpolator else { return current }
            let luma = Self.measure(buffer)
            defer {
                previousLuma = luma
                previousInterpolationInput = buffer
            }
            guard let previous, let previousInterpolationInput, !luma.isEmpty,
                  luma.count == previousLuma.count else { return current }
            let interval = (current.pts - previous.pts).seconds
            guard interval >= 1.0 / 144, interval <= max(0.12, expectedInterval * 2.5),
                  Self.shouldInterpolate(previousLuma, luma) else { return current }
            let interpolationStart = ProcessInfo.processInfo.systemUptime
            guard let outputs = interpolator.interpolate(previous: previousInterpolationInput, previousTime: previous.pts,
                                                         current: buffer, currentTime: pts), !outputs.isEmpty else {
                throw MediaProblem("VideoToolbox 无法处理此帧。可以关闭补帧后继续。")
            }
            statistics?.record(.interpolation, seconds: ProcessInfo.processInfo.systemUptime - interpolationStart)
            generatedCount += outputs.count
            pending = outputs.map { frame in
                let usePrevious = (frame.presentationTimeStamp - previous.pts).seconds < interval / 2
                return VideoFrame(buffer: frame.buffer, pts: frame.presentationTimeStamp, duration: .invalid,
                    generated: true, protectedSource: usePrevious ? previous.protectedSource : current.protectedSource)
            }
            pending.append(current)
            return pending.removeFirst()
        }
        return nil
    }

    private func nextSourceSample() throws -> CMSampleBuffer? {
        let start = ProcessInfo.processInfo.systemUptime
        let sample = try reader.next()
        if sample != nil { statistics?.record(.decodeRead, seconds: ProcessInfo.processInfo.systemUptime - start) }
        return sample
    }

    static func measure(_ buffer: CVPixelBuffer) -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let half = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_64RGBAHalf
        guard let base = half ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return [] }
        let stride = half ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return [] }
        var pixels: [UInt8] = []
        pixels.reserveCapacity(576)
        for row in 0..<18 {
            let y = min(height - 1, (2 * row + 1) * height / 36)
            for column in 0..<32 {
                let x = min(width - 1, (2 * column + 1) * width / 64)
                if half {
                    let bits = base.load(fromByteOffset: y * stride + x * 8 + 2, as: UInt16.self)
                    let green = Float(Float16(bitPattern: bits))
                    pixels.append(green.isFinite ? UInt8(max(0, min(255, green * 255))) : 0)
                } else if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
                    let value = base.load(fromByteOffset: y * stride + x * 2, as: UInt16.self)
                    pixels.append(UInt8(value >> 8))
                } else {
                    pixels.append(base.load(fromByteOffset: y * stride + x, as: UInt8.self))
                }
            }
        }
        return pixels
    }

    static func shouldInterpolate(_ previous: [UInt8], _ current: [UInt8]) -> Bool {
        if previous == current { return false }
        var before = [Int](repeating: 0, count: 16)
        var after = before
        var difference = 0
        for (a, b) in zip(previous, current) {
            before[Int(a) / 16] += 1
            after[Int(b) / 16] += 1
            difference += abs(Int(a) - Int(b))
        }
        let histogramDistance = zip(before, after).reduce(0) { $0 + abs($1.0 - $1.1) }
        return difference < current.count * 32 || histogramDistance < current.count
    }
}

final class VideoRenderer {
    let outputWidth: Int
    let outputHeight: Int
    let context: CIContext
    private let sourceWidth: Int
    private let sourceHeight: Int
    private let encodedSize: CGSize
    private let transform: CGAffineTransform
    private let effects: Effects
    private let queue: MTLCommandQueue
    private let cache: CVMetalTextureCache
    private let pool: CVPixelBufferPool
    private let hdrOutput: VideoPixelConverter?
    private let antiAlias: CIKernel?
    private let processing: [PictureGraph.Node]
    private let scaler: MTLFXSpatialScaler?
    private let statistics: PipelineTimings?
    private let scaleInput: MTLTexture?
    private let scaleOutput: MTLTexture?
    private let colour = CGColorSpace(name: CGColorSpace.itur_709)!

    // Equivalent to Fxaa() in linux/obs/veyra.effect, using pixel coordinates.
    private static let fxaaKernel = CIKernel(source: """
        float luma(vec3 colour) { return dot(colour, vec3(0.299, 0.587, 0.114)); }

        kernel vec4 veyraFXAA(sampler image) {
            vec2 position = destCoord();
            vec4 source = sample(image, samplerTransform(image, position));
            float centre = luma(source.rgb);
            float north = luma(sample(image, samplerTransform(image, position + vec2(0.0, -1.0))).rgb);
            float south = luma(sample(image, samplerTransform(image, position + vec2(0.0, 1.0))).rgb);
            float west = luma(sample(image, samplerTransform(image, position + vec2(-1.0, 0.0))).rgb);
            float east = luma(sample(image, samplerTransform(image, position + vec2(1.0, 0.0))).rgb);
            float lowest = min(centre, min(min(north, south), min(east, west)));
            float highest = max(centre, max(max(north, south), max(east, west)));
            if (highest - lowest < max(0.04, highest * 0.125)) return source;
            vec2 direction = vec2(-(north - south), east - west);
            float reduction = max((north + south + west + east) * 0.03125, 1.0 / 128.0);
            direction = clamp(direction / (min(abs(direction.x), abs(direction.y)) + reduction),
                              vec2(-8.0), vec2(8.0));
            vec3 narrow = 0.5 * (
                sample(image, samplerTransform(image, position - direction / 6.0)).rgb +
                sample(image, samplerTransform(image, position + direction / 6.0)).rgb);
            vec3 wide = 0.5 * narrow + 0.25 * (
                sample(image, samplerTransform(image, position - direction * 0.5)).rgb +
                sample(image, samplerTransform(image, position + direction * 0.5)).rgb);
            float wideLuma = luma(wide);
            return vec4(wideLuma < lowest || wideLuma > highest ? narrow : wide, source.a);
        }
        """)

    static var canUpscale: Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    convenience init(media: MediaFile, effects: Effects, timings: PipelineTimings? = nil) throws {
        try self.init(encoded: media.size, oriented: media.orientedSize, orientation: media.transform,
                      hdrTransfer: media.hdrTransfer, effects: effects, timings: timings)
    }

    init(encoded: CGSize, oriented: CGSize, orientation: CGAffineTransform, hdrTransfer: String?,
         effects: Effects, timings: PipelineTimings? = nil, stillImage: Bool = false) throws {
        statistics = timings
        self.effects = effects
        processing = try (effects.graph ?? .standard).compile()
        if effects.fxaa {
            guard let kernel = Self.fxaaKernel else {
                throw MediaProblem("无法初始化 FXAA。")
            }
            antiAlias = kernel
        } else {
            antiAlias = nil
        }
        transform = orientation
        encodedSize = encoded
        let size = stillImage ? CGSize(width: (oriented.width * effects.scale).rounded(),
                                       height: (oriented.height * effects.scale).rounded())
                              : effects.outputSize(source: oriented)
        outputWidth = Int(size.width)
        outputHeight = Int(size.height)
        sourceWidth = stillImage ? Int(oriented.width) : max(2, Int(oriented.width) / 2 * 2)
        sourceHeight = stillImage ? Int(oriented.height) : max(2, Int(oriented.height) / 2 * 2)
        guard let gpu = MTLCreateSystemDefaultDevice(), let queue = gpu.makeCommandQueue() else {
            throw MediaProblem("这台 Mac 无法启动 Metal。")
        }
        self.queue = queue
        let hdr = effects.preserveHDR ? hdrTransfer.map(HDRColour.init(transfer:)) : nil
        hdrOutput = try hdr.map { try VideoPixelConverter(width: Int(size.width), height: Int(size.height), hdr: $0, forInterpolation: false) }
        context = CIContext(mtlDevice: gpu, options: [
            .workingColorSpace: hdr == nil ? colour : CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .cacheIntermediates: false
        ])
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, gpu, nil, &textureCache) == kCVReturnSuccess,
              let textureCache else { throw MediaProblem("无法创建 Metal 视频纹理缓存。") }
        cache = textureCache
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth, kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var bufferPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &bufferPool) == kCVReturnSuccess,
              let bufferPool else { throw MediaProblem("无法分配输出帧。") }
        pool = bufferPool

        if hdr == nil && (outputWidth != sourceWidth || outputHeight != sourceHeight) {
            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = sourceWidth
            descriptor.inputHeight = sourceHeight
            descriptor.outputWidth = outputWidth
            descriptor.outputHeight = outputHeight
            descriptor.colorTextureFormat = .bgra8Unorm
            descriptor.outputTextureFormat = .bgra8Unorm
            descriptor.colorProcessingMode = .perceptual
            guard let configured = descriptor.makeSpatialScaler(device: gpu) else {
                throw MediaProblem("MetalFX 无法启动这个缩放档。")
            }
            scaler = configured
            let input = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: sourceWidth, height: sourceHeight, mipmapped: false)
            input.storageMode = .private
            input.usage = configured.colorTextureUsage.union([.shaderWrite, .renderTarget])
            let output = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: outputWidth, height: outputHeight, mipmapped: false)
            output.storageMode = .private
            output.usage = configured.outputTextureUsage
            guard let inputTexture = gpu.makeTexture(descriptor: input),
                  let outputTexture = gpu.makeTexture(descriptor: output) else {
                throw MediaProblem("无法分配超分纹理。")
            }
            scaleInput = inputTexture
            scaleOutput = outputTexture
            configured.inputContentWidth = sourceWidth
            configured.inputContentHeight = sourceHeight
            configured.colorTexture = inputTexture
            configured.outputTexture = outputTexture
        } else {
            scaler = nil
            scaleInput = nil
            scaleOutput = nil
        }
    }

    func render(_ frame: VideoFrame) throws -> VideoFrame {
        var decoded = CIImage(cvPixelBuffer: frame.buffer, options: [.toneMapHDRtoSDR: hdrOutput == nil])
        if frame.generated && decoded.extent.size != encodedSize {
            decoded = decoded.transformed(by: .init(scaleX: encodedSize.width / decoded.extent.width,
                                                    y: encodedSize.height / decoded.extent.height))
        }
        let protected = frame.protectedSource.map { CIImage(cvPixelBuffer: $0, options: [.toneMapHDRtoSDR: hdrOutput == nil]) }
        let buffer = try renderImage(decoded, protected: protected)
        return VideoFrame(buffer: buffer, pts: frame.pts, duration: frame.duration, generated: frame.generated)
    }

    private func orientedImage(_ decoded: CIImage) -> CIImage {
        // AVFoundation's preferred transform and the displayed Metal texture
        // use top-left coordinates. Core Image's source uses bottom-left.
        let toTopLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: decoded.extent.height)
        let image = decoded.transformed(by: toTopLeft.concatenating(transform))
        return image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    func renderImage(_ decoded: CIImage, protected: CIImage? = nil) throws -> CVPixelBuffer {
        var image = orientedImage(decoded)
        let bounds = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        if let protected, !effects.denoiseProtection.isEmpty {
            let original = orientedImage(protected)
            for region in effects.denoiseProtection {
                let rect = CGRect(x: bounds.width * region.x, y: bounds.height * region.y,
                    width: bounds.width * region.width, height: bounds.height * region.height).integral.intersection(bounds)
                if !rect.isEmpty { image = original.cropped(to: rect).composited(over: image) }
            }
        }
        for stage in processing where stage.strength > 0 {
            switch stage.kind {
            case .exposure:
                if effects.exposure != 0 {
                    image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: effects.exposure * stage.strength])
                }
            case .colour:
                if effects.saturation != 1 || effects.contrast != 1 {
                    image = image.applyingFilter("CIColorControls",
                        parameters: ["inputSaturation": 1 + (effects.saturation - 1) * stage.strength, "inputContrast": 1 + (effects.contrast - 1) * stage.strength])
                }
                image = effects.grade.apply(to: image, strength: stage.strength)
            case .lut:
                if let lut = effects.lookup {
                    if lut.minimum != [0, 0, 0] || lut.maximum != [1, 1, 1] {
                        let scales = zip(lut.minimum, lut.maximum).map { CGFloat(1 / ($1 - $0)) }
                        image = image.applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: scales[0], y: 0, z: 0, w: 0),
                            "inputGVector": CIVector(x: 0, y: scales[1], z: 0, w: 0),
                            "inputBVector": CIVector(x: 0, y: 0, z: scales[2], w: 0),
                            "inputBiasVector": CIVector(x: -CGFloat(lut.minimum[0]) * scales[0],
                                y: -CGFloat(lut.minimum[1]) * scales[1], z: -CGFloat(lut.minimum[2]) * scales[2], w: 0)
                        ])
                    }
                    image = image.applyingFilter("CIColorCube", parameters: [
                        "inputCubeDimension": lut.dimension, "inputCubeData": lut.data
                    ])
                }
            case .fxaa:
                if let antiAlias {
                    let padded = image.clampedToExtent()
                    guard let result = antiAlias.apply(extent: bounds,
                        roiCallback: { _, rect in rect.insetBy(dx: -5, dy: -5) },
                        arguments: [padded]) else { throw MediaProblem("无法应用 FXAA。") }
                    image = result
                }
            case .sharpen:
                if effects.sharpness > 0 {
                    image = image.clampedToExtent().applyingFilter("CISharpenLuminance",
                        parameters: [kCIInputSharpnessKey: effects.sharpness * stage.strength]).cropped(to: bounds)
                }
            }
        }
        if let hdrOutput {
            // The pixel-buffer render API already accounts for the CV pixel
            // buffer's origin, so undo the flip used by the Metal texture path.
            let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
            let start = ProcessInfo.processInfo.systemUptime
            let buffer = try hdrOutput.convert(image.transformed(by: flip))
            statistics?.record(.hdrOutput, seconds: ProcessInfo.processInfo.systemUptime - start)
            return buffer
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { throw MediaProblem("输出帧分配失败。") }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        var wrapped: CVMetalTexture?
        let options = [kCVMetalTextureUsage as String: MTLTextureUsage([.renderTarget, .shaderWrite]).rawValue] as CFDictionary
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, options,
                .bgra8Unorm, outputWidth, outputHeight, 0, &wrapped) == kCVReturnSuccess,
              let wrapped, let texture = CVMetalTextureGetTexture(wrapped),
              let command = queue.makeCommandBuffer() else { throw MediaProblem("无法构建 Metal 输出帧。") }

        if let scaler, let scaleInput, let scaleOutput {
            context.render(image, to: scaleInput, commandBuffer: command, bounds: bounds, colorSpace: colour)
            scaler.encode(commandBuffer: command)
            guard let blit = command.makeBlitCommandEncoder() else { throw MediaProblem("无法复制超分输出纹理。") }
            blit.copy(from: scaleOutput, to: texture)
            blit.endEncoding()
        } else {
            context.render(image, to: texture, commandBuffer: command, bounds: bounds, colorSpace: colour)
        }
        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime(wrapped) {}
        guard command.status == .completed else { throw command.error ?? MediaProblem("GPU 处理失败。") }
        if command.gpuEndTime > command.gpuStartTime {
            statistics?.record(.metal, seconds: command.gpuEndTime - command.gpuStartTime)
        }
        return pixelBuffer
    }
}


struct HDRColour {
    let transfer: String

    var colourSpace: CGColorSpace {
        let hlg = transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        return CGColorSpace(name: hlg ? CGColorSpace.itur_2100_HLG : CGColorSpace.itur_2100_PQ)!
    }
}

/// Convert to the pixel format required by interpolation or the output sink.
final class VideoPixelConverter {
    private let context: CIContext
    private let bounds: CGRect
    private let colour: CGColorSpace
    private let hdr: HDRColour?
    private let rgbPool: CVPixelBufferPool
    private let yuvPool: CVPixelBufferPool?
    private let transfer: VTPixelTransferSession?

    init(width: Int, height: Int, hdr: HDRColour?, forInterpolation: Bool, floatingPoint: Bool = false) throws {
        self.hdr = hdr
        colour = hdr?.colourSpace ?? CGColorSpace(name: CGColorSpace.itur_709)!
        guard let device = MTLCreateSystemDefaultDevice() else { throw MediaProblem("无法创建色彩转换 GPU。") }
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let rgbFormat = hdr != nil || floatingPoint ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA
        rgbPool = try Self.makePool(format: rgbFormat, width: width, height: height)
        if forInterpolation && (hdr != nil || floatingPoint) {
            yuvPool = nil
            transfer = nil
            return
        }
        let yuvFormat = hdr == nil ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange :
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        yuvPool = try Self.makePool(format: yuvFormat, width: width, height: height)
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr,
              let session else { throw MediaProblem("无法创建 YUV 色彩转换器。") }
        transfer = session
        let properties: [String: CFString] = [
            kVTPixelTransferPropertyKey_DestinationColorPrimaries as String: hdr == nil
                ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_ITU_R_2020,
            kVTPixelTransferPropertyKey_DestinationTransferFunction as String: hdr.map { $0.transfer as CFString }
                ?? kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTPixelTransferPropertyKey_DestinationYCbCrMatrix as String: hdr == nil
                ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_2020
        ]
        guard VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary) == noErr else {
            throw MediaProblem("无法设置输出色彩空间。")
        }
    }

    func convert(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        try convert(CIImage(cvPixelBuffer: source, options: [.toneMapHDRtoSDR: hdr == nil]))
    }

    func convert(_ source: CIImage) throws -> CVPixelBuffer {
        let rgb = try allocate(from: rgbPool)
        var image = source
        if image.extent.size != bounds.size {
            let horizontal = bounds.width / image.extent.width
            let vertical = bounds.height / image.extent.height
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: vertical, kCIInputAspectRatioKey: horizontal / vertical
            ])
        }
        context.render(image, to: rgb, bounds: bounds, colorSpace: colour)
        CVBufferSetAttachment(rgb, kCVImageBufferCGColorSpaceKey, colour, .shouldPropagate)
        CVBufferSetAttachment(rgb, kCVImageBufferColorPrimariesKey,
            hdr == nil ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate)
        CVBufferSetAttachment(rgb, kCVImageBufferTransferFunctionKey,
            hdr.map { $0.transfer as CFString } ?? kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        guard let yuvPool, let transfer else { return rgb }
        let yuv = try allocate(from: yuvPool)
        let result = VTPixelTransferSessionTransferImage(transfer, from: rgb, to: yuv)
        guard result == noErr else { throw MediaProblem("转换至 YUV 输出格式失败（\(result)）。") }
        return yuv
    }

    private func allocate(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw MediaProblem("无法分配色彩转换帧。")
        }
        return buffer
    }

    private static func makePool(format: OSType, width: Int, height: Int) throws -> CVPixelBufferPool {
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferExtendedPixelsRightKey as String: (16 - width % 16) % 16,
            kCVPixelBufferExtendedPixelsBottomKey as String: (16 - height % 16) % 16
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, settings as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else { throw MediaProblem("无法创建色彩转换缓冲池。") }
        return pool
    }
}

final class NoiseReduction {
    private let strengths: [Float]
    private let timings: PipelineTimings?
    private var lastTime = CMTime.invalid
    private var layers: [VeyraDenoiser] = []
    private var dimensions = CGSize.zero
    private var format: OSType = 0
    private var luma: [UInt8] = []

    init(strengths: [Float], timings: PipelineTimings?) {
        self.strengths = strengths
        self.timings = timings
    }

    func apply(_ buffer: CVPixelBuffer, pts: CMTime) throws -> CVPixelBuffer {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        if dimensions != size || format != pixelFormat {
            let configured = try strengths.map { strength in
                guard let layer = VeyraDenoiser(width: Int(size.width), height: Int(size.height),
                                              format: pixelFormat, strength: strength) else {
                    throw MediaProblem("VideoToolbox 无法为当前视频格式启用时域降噪。")
                }
                return layer
            }
            dimensions = size
            format = pixelFormat
            layers = configured
            lastTime = .invalid
            luma = []
        }
        let start = ProcessInfo.processInfo.systemUptime
        defer { timings?.record(.denoise, seconds: ProcessInfo.processInfo.systemUptime - start) }
        let samples = VideoFrames.measure(buffer)
        let interval = (pts - lastTime).seconds
        if !lastTime.isValid || interval <= 0 || interval > 0.12 ||
            (!luma.isEmpty && samples != luma && !VideoFrames.shouldInterpolate(luma, samples)) {
            for layer in layers { layer.reset() }
        }
        lastTime = pts
        luma = samples
        var result = buffer
        for layer in layers {
            guard let input = layer.prepareInput(result) else {
                throw MediaProblem("降噪层之间的像素转换失败。")
            }
            result = layer.filter(input, time: pts) ?? result
        }
        return result
    }
}
