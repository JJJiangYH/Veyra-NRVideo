// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import CoreImage
import Foundation
import Metal
import MetalFX
import VideoToolbox

private let pq = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
private let bt2020 = kCVImageBufferColorPrimaries_ITU_R_2020 as String
private let p010 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
private let frame60 = 60000.0 / 1001.0
private let frame30 = frame60 / 2
private let clock = ProcessInfo.processInfo

private func log(_ text: String) {
    print(text)
    fflush(stdout)
}

private func time(_ index: Int, fps: Int32) -> CMTime {
    CMTime(value: Int64(index) * 1001, timescale: fps * 1000)
}

private func frameReader(_ input: MediaFile) throws -> ClipReader {
    try ClipReader(media: input, track: input.video, settings: [
        kCVPixelBufferPixelFormatTypeKey as String: p010,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferMetalCompatibilityKey as String: true
    ], from: .zero, until: nil)
}

private func grid(_ buffer: CVPixelBuffer) throws -> [UInt16] {
    guard CVPixelBufferGetPixelFormatType(buffer) == p010,
          CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
        throw MediaProblem("无法读取 10-bit 亮度平面")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
        throw MediaProblem("视频缺少亮度平面")
    }
    let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let columns = 112
    let rows = 64
    var result = [UInt16]()
    result.reserveCapacity(columns * rows)
    for row in 0..<rows {
        let y = (2 * row + 1) * height / (2 * rows)
        let stagger = row % 2
        let line = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
        for column in 0..<columns {
            let x = min(width - 1, (4 * column + 1 + 2 * stagger) * width / (4 * columns))
            result.append(line[x] >> 6)
        }
    }
    return result
}

private func difference(_ a: [UInt16], _ b: [UInt16]) -> Double {
    var sum = 0
    for i in a.indices { sum += abs(Int(a[i]) - Int(b[i])) }
    return Double(sum) / Double(a.count)
}

private func pct(_ data: [Double], _ rank: Double) -> Double {
    guard !data.isEmpty else { return 0 }
    let ordered = data.sorted()
    return ordered[Int((Double(ordered.count - 1) * rank).rounded())]
}

private struct Cadence {
    let indices: [Int]
    let discarded: [Double]
    let retainedChanges: [Double]
    let switches: Int
    let originalCount: Int
    let firstPTS: Double

    static func scan(_ media: MediaFile) throws -> Cadence {
        let read = try frameReader(media)
        var previous: [UInt16]?
        var deltas: [Double] = []
        var firstPTS: Double?
        while try autoreleasepool(invoking: { () -> Bool in
            guard let sample = try read.next() else { return false }
            guard let buffer = sample.imageBuffer else { throw MediaProblem("解码帧没有像素数据") }
            let current = try grid(buffer)
            if let previous { deltas.append(difference(previous, current)) }
            else { firstPTS = sample.presentationTimeStamp.seconds }
            previous = current
            return true
        }) {}
        guard deltas.count >= 2, let firstPTS else { throw MediaProblem("素材没有足够的帧") }
        let sourceCount = deltas.count + 1
        let pairs = sourceCount / 2
        var costs = [0.0, 0.0]
        var back = Array(repeating: [0, 0], count: pairs)
        let penalty = 1.35
        for pair in 0..<pairs {
            var next = [0.0, 0.0]
            for phase in 0...1 {
                let i = pair * 2 + phase
                let distance = deltas[min(i, deltas.count - 1)]
                let unchanged = costs[phase]
                let switched = costs[1 - phase] + penalty
                back[pair][phase] = unchanged <= switched ? phase : 1 - phase
                next[phase] = log1p(distance) + min(unchanged, switched)
            }
            costs = next
        }
        var phase = costs[0] <= costs[1] ? 0 : 1
        var choices = Array(repeating: 0, count: pairs)
        for pair in (0..<pairs).reversed() {
            choices[pair] = phase
            phase = back[pair][phase]
        }
        let indices = choices.enumerated().map { pair, phase in 2 * pair + phase }
        let discarded = indices.compactMap { $0 < deltas.count ? deltas[$0] : nil }
        let retained = indices.compactMap { $0 > 0 ? deltas[$0 - 1] : nil }
        let switches = zip(choices, choices.dropFirst()).filter { $0 != $1 }.count
        let odd = deltas.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let even = deltas.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        log(String(format: "CADENCE source=%d selected=%d firstPTS=%.4f phaseSwitches=%d adjacentP50=%.3f/%.3f keptChangeP50=%.3f discardedP50=%.3f discardedP95=%.3f",
                   sourceCount, indices.count, firstPTS, switches, pct(odd, 0.5), pct(even, 0.5),
                   pct(retained, 0.5), pct(discarded, 0.5), pct(discarded, 0.95)))
        return Cadence(indices: indices, discarded: discarded, retainedChanges: retained, switches: switches,
                       originalCount: sourceCount, firstPTS: firstPTS)
    }
}

private final class HDRWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let fps: Int32
    private(set) var count = 0

    init(_ url: URL, width: Int, height: Int, fps: Int32, bitrate: Int, offset: CMTime = .zero) throws {
        self.fps = fps
        self.offset = offset
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieTimeScale = 60000
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                AVVideoExpectedSourceFrameRateKey: Double(fps) / 1.001,
                AVVideoAverageBitRateKey: bitrate,
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        input.mediaTimeScale = 60000
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw MediaProblem("无法配置 HEVC Main 10 硬件编码") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaProblem("无法开始编码") }
        writer.startSession(atSourceTime: .zero)
    }

    private let offset: CMTime

    func append(_ buffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(buffer) == p010 else { throw MediaProblem("输出帧不是 P010") }
        let start = clock.systemUptime
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, clock.systemUptime - start < 20 else {
                throw writer.error ?? MediaProblem("编码等待超时")
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        let pts = CMTimeAdd(offset, time(count, fps: fps))
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            throw writer.error ?? MediaProblem("写入视频帧失败")
        }
        count += 1
    }

    func finish() throws {
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTimeAdd(offset, time(count, fps: fps)))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 60) == .success, writer.status == .completed else {
            throw writer.error ?? MediaProblem("生成 MP4 失败")
        }
    }
}

private final class HDRMetalScaler {
    private let queue: MTLCommandQueue
    private let context: CIContext
    private let scaler: any MTLFXSpatialScaler
    private let source: any MTLTexture
    private let result: any MTLTexture
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    private let pqSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
    private let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw MediaProblem("无法启动 Metal")
        }
        self.queue = queue
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = 1920
        descriptor.inputHeight = 1080
        descriptor.outputWidth = 3840
        descriptor.outputHeight = 2160
        descriptor.colorTextureFormat = .rgba16Float
        descriptor.outputTextureFormat = .rgba16Float
        descriptor.colorProcessingMode = .hdr
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            throw MediaProblem("无法启用 MetalFX HDR")
        }
        self.scaler = scaler
        let sourceDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1920, height: 1080, mipmapped: false)
        sourceDesc.storageMode = .private
        sourceDesc.usage = scaler.colorTextureUsage.union([.shaderWrite, .renderTarget])
        let resultDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 3840, height: 2160, mipmapped: false)
        resultDesc.storageMode = .private
        resultDesc.usage = scaler.outputTextureUsage.union(.shaderRead)
        guard let source = device.makeTexture(descriptor: sourceDesc), let result = device.makeTexture(descriptor: resultDesc) else {
            throw MediaProblem("无法分配 HDR 放大纹理")
        }
        self.source = source
        self.result = result
        scaler.colorTexture = source
        scaler.outputTexture = result
        scaler.inputContentWidth = 1920
        scaler.inputContentHeight = 1080
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: linear, .cacheIntermediates: false])
    }

    func resize(_ frame: CVPixelBuffer, using output: VideoPixelConverter) throws -> CVPixelBuffer {
        guard let command = queue.makeCommandBuffer() else { throw MediaProblem("无法创建 Metal 命令") }
        let image = CIImage(cvPixelBuffer: frame, options: [.toneMapHDRtoSDR: false, .colorSpace: pqSpace])
        context.render(image, to: source, commandBuffer: command, bounds: bounds, colorSpace: linear)
        scaler.encode(commandBuffer: command)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? MediaProblem("MetalFX 处理失败") }
        guard let enlarged = CIImage(mtlTexture: result, options: [.colorSpace: linear]) else {
            throw MediaProblem("无法读取 MetalFX HDR 输出")
        }
        return try output.convert(enlarged)
    }
}

@main
private struct ProcessGTA {
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count >= 3 else { throw MediaProblem("用法：scan|prepare|enhance|verify input [temporary destination]") }
            let media = try await MediaFile.open(URL(fileURLWithPath: args[2]))
            guard media.hdrTransfer == pq, media.transform.isIdentity,
                  media.size == CGSize(width: 1920, height: 1080) || media.size == CGSize(width: 3840, height: 2160) else {
                throw MediaProblem("预期横屏 1080p 或 4K PQ HDR 文件")
            }
            let start = clock.systemUptime
            switch args[1] {
            case "scan":
                _ = try Cadence.scan(media)
            case "prepare", "enhance":
                guard args.count >= 4 else { throw MediaProblem("缺少输出路径") }
                let url = URL(fileURLWithPath: args[3])
                if args[1] == "prepare" { try prepare(media, url: url) }
                else { try await enhance(media, url: url, secondsLimit: args.count >= 5 ? Double(args[4]) : nil) }
            case "verify":
                try await verify(media, expectedFPS: args.count >= 4 ? Int(args[3]) ?? 60 : 60)
            default: throw MediaProblem("未知操作")
            }
            log(String(format: "WALL_SECONDS=%.3f", clock.systemUptime - start))
        } catch {
            FileHandle.standardError.write(Data(("ERROR " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static func prepare(_ media: MediaFile, url: URL) throws {
        guard abs(Double(media.frameRate) - frame60) < 0.15 else { throw MediaProblem("输入需要 59.94 fps") }
        let cadence = try Cadence.scan(media)
        let width = Int(media.size.width)
        let height = Int(media.size.height)
        let writer = try HDRWriter(url, width: width, height: height, fps: 30,
                                   bitrate: width == 3840 ? 65_000_000 : 32_000_000,
                                   offset: CMTime(seconds: cadence.firstPTS, preferredTimescale: 60000))
        let reader = try frameReader(media)
        var index = 0
        while writer.count < cadence.indices.count {
            let hasFrame = try autoreleasepool { () throws -> Bool in
                guard let sample = try reader.next(), let frame = sample.imageBuffer else { return false }
                if cadence.indices[writer.count] == index { try writer.append(frame) }
                index += 1
                return true
            }
            guard hasFrame else { throw MediaProblem("去重写入提前结束") }
        }
        try writer.finish()
        log("PREPARED frames=\(writer.count) width=\(width) height=\(height)")
    }

    static func enhance(_ media: MediaFile, url: URL, secondsLimit: Double?) async throws {
        guard abs(Double(media.frameRate) - frame30) < 0.15 else { throw MediaProblem("输入需要 29.97 fps") }
        let prepStart = clock.systemUptime
        let width = Int(media.size.width)
        let height = Int(media.size.height)
        let upscale = width < 3840
        let hdr = HDRColour(transfer: pq)
        guard let interpolate = VeyraInterpolation(width: width, height: height, quality: true, multiplier: 2) else {
            throw MediaProblem("无法启动 \(width)×\(height) 高质量补帧")
        }
        let scaler = try upscale ? HDRMetalScaler() : nil
        let convertInput = try VideoPixelConverter(width: width, height: height, hdr: hdr, forInterpolation: true, floatingPoint: true)
        let convertOutput = try VideoPixelConverter(width: 3840, height: 2160, hdr: hdr, forInterpolation: false)
        let read = try frameReader(media)
        let videoRange = try await media.video.load(.timeRange)
        let writer = try HDRWriter(url, width: 3840, height: 2160, fps: 60, bitrate: 65_000_000, offset: videoRange.start)
        let maxPairs = secondsLimit.map { Int($0 * frame30) } ?? Int.max
        var previousRGB: CVPixelBuffer?
        var previousOutput: CVPixelBuffer?
        var previousGrid: [UInt16]?
        var generated = 0
        var repeated = 0
        var sceneCuts = 0
        var sourceIndex = 0
        var frTimes: [Double] = []
        var renderTimes: [Double] = []
        var groupTimes: [Double] = []

        func rendered(_ frame: CVPixelBuffer) throws -> CVPixelBuffer {
            let start = clock.systemUptime
            defer { renderTimes.append((clock.systemUptime - start) * 1000) }
            if let scaler { return try scaler.resize(frame, using: convertOutput) }
            if CVPixelBufferGetPixelFormatType(frame) == p010 { return frame }
            return try convertOutput.convert(frame)
        }

        while sourceIndex < maxPairs {
            let advanced = try autoreleasepool { () throws -> Bool in
                let groupStart = clock.systemUptime
                guard let sample = try read.next(), let frame = sample.imageBuffer else { return false }
                let luma = try grid(frame)
                let rgb = try convertInput.convert(frame)
                if let prior = previousRGB, let priorOutput = previousOutput, let previousGrid {
                    let change = difference(previousGrid, luma)
                    if change < 0.12 || change > 118 {
                        try writer.append(priorOutput)
                        if change > 118 { sceneCuts += 1 }
                        else { repeated += 1 }
                    } else {
                        let fgStart = clock.systemUptime
                        guard let between = interpolate.interpolate(previous: prior, previousTime: time(sourceIndex - 1, fps: 30),
                            current: rgb, currentTime: time(sourceIndex, fps: 30))?.first else {
                            throw MediaProblem("VideoToolbox 在第 \(sourceIndex) 组生成失败")
                        }
                        frTimes.append((clock.systemUptime - fgStart) * 1000)
                        try writer.append(rendered(between.buffer))
                        generated += 1
                    }
                }
                let full = try rendered(frame)
                try writer.append(full)
                previousRGB = rgb
                previousOutput = full
                previousGrid = luma
                sourceIndex += 1
                groupTimes.append((clock.systemUptime - groupStart) * 1000)
                if sourceIndex.isMultiple(of: 300) {
                    let seconds = clock.systemUptime - prepStart
                    log(String(format: "PROGRESS source=%d output=%d elapsed=%.1f throughput=%.1f",
                               sourceIndex, writer.count, seconds, Double(writer.count) / seconds))
                }
                return true
            }
            if !advanced { break }
        }
        guard let previousOutput else { throw MediaProblem("没有可处理的 30 fps 视频帧") }
        try writer.append(previousOutput)
        try writer.finish()
        log(String(format: "ENHANCED width=3840 height=2160 source=%d output=%d generated=%d duplicateHold=%d cutHold=%d finalHold=1 fgP50=%.2f fgP95=%.2f renderP50=%.2f renderP95=%.2f groupP50=%.2f groupP95=%.2f",
                   sourceIndex, writer.count, generated, repeated, sceneCuts, pct(frTimes, 0.5), pct(frTimes, 0.95),
                   pct(renderTimes, 0.5), pct(renderTimes, 0.95), pct(groupTimes, 0.5), pct(groupTimes, 0.95)))
    }

    static func verify(_ media: MediaFile, expectedFPS: Int) async throws {
        guard let format = try await media.video.load(.formatDescriptions).first,
              CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC,
              CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String == bt2020,
              let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
              let hvcc = atoms["hvcC"] as? Data, hvcc.count > 18,
              (hvcc[17] & 7) == 2, (hvcc[18] & 7) == 2,
              abs(Double(media.frameRate) - Double(expectedFPS) / 1.001) < 0.15 else {
            throw MediaProblem("成品规格校验未通过")
        }
        let read = try frameReader(media)
        var previous = CMTime.invalid
        var maxJitter = 0.0
        var frames = 0
        var first: [UInt16] = []
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let sample = try read.next() else { return false }
            guard let pixel = sample.imageBuffer, CVPixelBufferGetPixelFormatType(pixel) == p010 else {
                throw MediaProblem("成片无法以 P010 解码")
            }
            let pts = sample.presentationTimeStamp
            if previous.isValid {
                let gap = (pts - previous).seconds
                guard gap > 0 else { throw MediaProblem("视频时间戳未单调递增") }
                maxJitter = max(maxJitter, abs(gap - 1.001 / Double(expectedFPS)))
            } else {
                first = try grid(pixel)
            }
            previous = pts
            frames += 1
            return true
        }) {}
        guard frames > 0, maxJitter < 0.0001, !media.audioTracks.isEmpty else {
            throw MediaProblem("成片帧率节奏或音轨校验不通过")
        }
        log(String(format: "VERIFIED %.0fx%.0f fps=%.4f frames=%d audioTracks=%d duration=%.3f maxJitterMS=%.4f lumaP50=%.0f lumaP99=%.0f",
                   media.size.width, media.size.height, media.frameRate, frames, media.audioTracks.count,
                   media.duration.seconds, maxJitter * 1000, pct(first.map(Double.init), 0.5), pct(first.map(Double.init), 0.99)))
    }
}
