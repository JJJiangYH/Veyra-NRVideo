// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import Foundation
import VideoToolbox

final class VideoExport {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }

    func run(media: MediaFile, effects: Effects, destination: URL, range: CMTimeRange? = nil,
             progress: @escaping (Double) -> Void,
             completion: @escaping (Result<ExportSummary, Error>) -> Void) {
        DispatchQueue(label: "io.veyra.export", qos: .userInitiated).async {
            let result = Result { try self.write(media, effects, destination, range, progress) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    struct ExportSummary {
        let frames: Int
        let generated: Int
        let width: Int
        let height: Int
        let audioTracks: Int
        var hasAudio: Bool { audioTracks > 0 }
    }

    private final class AudioTrackWriter {
        let reader: ClipReader
        let input: AVAssetWriterInput
        var nextSample: CMSampleBuffer?
        var isFinished = false

        init(media: MediaFile, track: AVAssetTrack, range: CMTimeRange) throws {
            reader = try ClipReader(media: media, track: track, settings: ClipReader.audioSettings,
                                    from: range.start, until: range.end)
            guard let sample = try reader.next(), let format = sample.formatDescription,
                  let encoding = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
                throw MediaProblem("所选区间没有可读取的音频采样。")
            }
            let setup: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: encoding.mSampleRate,
                AVNumberOfChannelsKey: encoding.mChannelsPerFrame,
                AVEncoderBitRateKey: encoding.mChannelsPerFrame > 1 ? 192_000 : 96_000
            ]
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: setup, sourceFormatHint: format)
            nextSample = sample
        }

        func appendReadySample(to writer: AVAssetWriter) throws -> Bool {
            guard !isFinished, input.isReadyForMoreMediaData else { return false }
            if let sample = nextSample {
                guard input.append(sample) else { throw writer.error ?? MediaProblem("写入音频失败。") }
                nextSample = try reader.next()
            } else {
                input.markAsFinished()
                isFinished = true
            }
            return true
        }
    }

    private func write(_ media: MediaFile, _ effects: Effects, _ destination: URL, _ selectedRange: CMTimeRange?,
                       _ progress: @escaping (Double) -> Void) throws -> ExportSummary {
        guard media.url.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else {
            throw MediaProblem("请选择另一个文件名，避免覆盖原视频。")
        }
        let fullRange = CMTimeRange(start: .zero, end: media.duration)
        let range = selectedRange?.intersection(fullRange) ?? fullRange
        guard range.isValid, !range.isEmpty else { throw MediaProblem("请选取有效的导出区间。") }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".veyra-" + UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let mkv = destination.pathExtension.lowercased() == "mkv"
        let subtitles = MediaContainer.supportsMatroska && media.subtitleCount > 0 ? media.asset.url : nil
        let needsRemux = mkv || subtitles != nil
        let muxed = needsRemux ? destination.deletingLastPathComponent()
            .appendingPathComponent(".veyra-" + UUID().uuidString + (mkv ? ".mkv" : ".mp4")) : temporary
        defer { if needsRemux { try? FileManager.default.removeItem(at: muxed) } }
        let renderer = try VideoRenderer(media: media, effects: effects)
        let frames = try VideoFrames(media: media, effects: effects, from: range.start, until: range.end)
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let rate = Double(media.frameRate)
        let sourceRate = effects.capture60To30 && (55...65).contains(rate) ? rate / 2 : rate
        let fps = max(24, min(120, sourceRate * (effects.interpolate ? Double(effects.multiplier) : 1)))
        let bitrate = Int(min(65_000_000, max(5_000_000, Double(renderer.outputWidth * renderer.outputHeight) * fps * 0.09)))
        let hdr = effects.preserveHDR ? media.hdrTransfer : nil
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoAllowFrameReorderingKey: false
        ]
        if hdr != nil { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hdr == nil ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: renderer.outputWidth, AVVideoHeightKey: renderer.outputHeight,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: hdr == nil ? AVVideoColorPrimaries_ITU_R_709_2 : AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: hdr ?? AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: hdr == nil ? AVVideoYCbCrMatrix_ITU_R_709_2 : AVVideoYCbCrMatrix_ITU_R_2020
            ],
            AVVideoCompressionPropertiesKey: compression
        ])
        let pixelWriter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(video) else { throw MediaProblem("无法配置视频编码。") }
        writer.add(video)

        let audio = try media.audioTracks.map { try AudioTrackWriter(media: media, track: $0, range: range) }
        for track in audio {
            guard writer.canAdd(track.input) else { throw MediaProblem("无法将此音轨编码为 AAC。") }
            writer.add(track.input)
        }

        guard writer.startWriting() else { throw writer.error ?? MediaProblem("无法开始导出。") }
        writer.startSession(atSourceTime: range.start)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        var videoDone = false
        var count = 0
        var lastProgress = Date.distantPast
        var lastChange = Date()

        while !videoDone || audio.contains(where: { !$0.isFinished }) {
            try check(writer)
            let moved = try autoreleasepool {
                var advanced = false
                if !videoDone, video.isReadyForMoreMediaData {
                    if let raw = try frames.next() {
                        let frame = try renderer.render(raw)
                        guard pixelWriter.append(frame.buffer, withPresentationTime: frame.pts) else {
                            throw writer.error ?? MediaProblem("写入视频帧失败。")
                        }
                        count += 1
                        if Date().timeIntervalSince(lastProgress) >= 0.1 {
                            lastProgress = Date()
                            let ratio = min(0.99, max(0, (frame.pts - range.start).seconds / range.duration.seconds))
                            DispatchQueue.main.async { progress(ratio) }
                        }
                    } else {
                        video.markAsFinished()
                        videoDone = true
                    }
                    advanced = true
                }
                for track in audio {
                    if try track.appendReadySample(to: writer) { advanced = true }
                }
                return advanced
            }
            if moved { lastChange = Date() }
            else if Date().timeIntervalSince(lastChange) > 15 { throw MediaProblem("编码器等待读写超时。") }
            else { Thread.sleep(forTimeInterval: 0.002) }
        }
        guard count > 0 else { throw MediaProblem("没有可写入的视频帧。") }
        writer.endSession(atSourceTime: range.end)
        let ended = DispatchSemaphore(value: 0)
        writer.finishWriting { ended.signal() }
        let deadline = Date().addingTimeInterval(60)
        while ended.wait(timeout: .now() + 0.25) == .timedOut {
            try check(writer)
            if Date() > deadline { throw MediaProblem("整理输出文件超时。") }
        }
        try check(writer)
        guard writer.status == .completed else { throw writer.error ?? MediaProblem("导出未完成。") }

        if needsRemux {
            try MediaContainer.finishExport(temporary, subtitles: subtitles, start: range.start.seconds,
                end: range.end.seconds, destination: muxed) { self.lock.withLock { self.cancelled } }
        }
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: muxed)
        } else {
            try files.moveItem(at: muxed, to: destination)
        }
        return ExportSummary(frames: count, generated: frames.generatedCount,
                             width: renderer.outputWidth, height: renderer.outputHeight, audioTracks: audio.count)
    }

    private func check(_ writer: AVAssetWriter) throws {
        if lock.withLock({ cancelled }) { throw MediaProblem("已取消导出。") }
        if writer.status == .failed || writer.status == .cancelled {
            throw writer.error ?? MediaProblem("编码器已停止。")
        }
    }
}
