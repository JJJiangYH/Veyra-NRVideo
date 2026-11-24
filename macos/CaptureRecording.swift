// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import Foundation

/// An MP4 recording starts on the first processed video frame and uses the
/// original capture clock for both video and audio. Called on the capture queue.
final class CaptureRecording {
    private let destination: URL
    private let temporary: URL
    private let includeAudio: Bool
    private let replaceExisting: Bool
    private let writer: AVAssetWriter
    private var video: AVAssetWriterInput?
    private var pixels: AVAssetWriterInputPixelBufferAdaptor?
    private var audio: AVAssetWriterInput?
    private var audioDescription: CMAudioFormatDescription?
    private var startPTS = CMTime.invalid
    private var lastVideoPTS = CMTime.invalid
    private var lastAudioPTS = CMTime.invalid
    private var size = CGSize.zero
    private var count = 0
    var hasFrames: Bool { count > 0 }

    init(destination: URL, includeAudio: Bool, monitorSize: Bool = false, replaceExisting: Bool = true) throws {
        self.destination = destination
        self.includeAudio = includeAudio
        self.replaceExisting = replaceExisting
        temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".veyra-recording-" + UUID().uuidString + ".mp4")
        writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = !monitorSize
        if monitorSize { writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600) }
    }

    deinit {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: temporary)
    }

    func appendAudio(_ sample: CMSampleBuffer) throws {
        guard includeAudio else { return }
        audioDescription = sample.formatDescription
        let pts = sample.presentationTimeStamp
        guard let audio, startPTS.isValid, pts >= startPTS,
              !lastAudioPTS.isValid || pts > lastAudioPTS, audio.isReadyForMoreMediaData else { return }
        guard audio.append(sample) else { throw writer.error ?? MediaProblem("写入采集音频失败。") }
        lastAudioPTS = pts
    }

    @discardableResult
    func appendVideo(_ frame: VideoFrame) throws -> Bool {
        let dimensions = CGSize(width: CVPixelBufferGetWidth(frame.buffer), height: CVPixelBufferGetHeight(frame.buffer))
        if video == nil {
            // Wait at most for the separately selected capture audio source to
            // describe its PCM format. The caller can record video on its own.
            if includeAudio && audioDescription == nil { return false }
            try configure(size: dimensions, time: frame.pts)
        }
        guard size == dimensions else { throw MediaProblem("采集尺寸已变化。请停止后重新录制。") }
        guard let video, let pixels, video.isReadyForMoreMediaData else { return false }
        guard !lastVideoPTS.isValid || frame.pts > lastVideoPTS else { return false }
        guard pixels.append(frame.buffer, withPresentationTime: frame.pts) else {
            throw writer.error ?? MediaProblem("写入采集视频失败。")
        }
        count += 1
        lastVideoPTS = frame.pts
        return true
    }

    var temporarySize: Int {
        (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    func finish(end: CMTime? = nil, _ completion: @escaping (Result<Int, Error>) -> Void) {
        guard count > 0, writer.status == .writing else {
            completion(.failure(writer.error ?? MediaProblem("录制没有收到视频帧。")))
            return
        }
        video?.markAsFinished()
        audio?.markAsFinished()
        if let end, end > lastVideoPTS { writer.endSession(atSourceTime: end) }
        writer.finishWriting { [self] in
            completion(Result {
                guard writer.status == .completed else { throw writer.error ?? MediaProblem("整理录制文件失败。") }
                let files = FileManager.default
                if replaceExisting && files.fileExists(atPath: destination.path) {
                    _ = try files.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try files.moveItem(at: temporary, to: destination)
                }
                return count
            })
        }
    }

    private func configure(size: CGSize, time: CMTime) throws {
        self.size = size
        let bitrate = Int(min(70_000_000, max(5_000_000, size.width * size.height * 5.4)))
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoAllowFrameReorderingKey: false]
        ])
        video.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(video) else { throw MediaProblem("无法配置录制视频编码器。") }
        writer.add(video)
        self.video = video
        pixels = adaptor

        if let audioDescription, includeAudio,
           let stream = CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription)?.pointee {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: stream.mSampleRate,
                AVNumberOfChannelsKey: stream.mChannelsPerFrame,
                AVEncoderBitRateKey: stream.mChannelsPerFrame > 1 ? 192_000 : 96_000
            ], sourceFormatHint: audioDescription)
            audio.expectsMediaDataInRealTime = true
            guard writer.canAdd(audio) else { throw MediaProblem("无法配置录制音频编码器。") }
            writer.add(audio)
            self.audio = audio
        }
        guard writer.startWriting() else { throw writer.error ?? MediaProblem("无法启动录制。") }
        writer.startSession(atSourceTime: time)
        startPTS = time
    }
}

struct CaptureRecordingSummary {
    let files: Int
    let frames: Int
}

/// All recording state is confined to the capture queue. Encoders finish
/// independently of frame submission, with no more than two finishing at once.
final class CaptureRecordingSession {
    private let destination: URL
    private let includeAudio: Bool
    private let duration: Double
    private let maxBytes: Int
    private let queue: DispatchQueue
    private var current: CaptureRecording
    private var start = CMTime.invalid
    private var checkedSizeAt = CMTime.invalid
    private var lastAudio: CMSampleBuffer?
    private var index = 1
    private var pending = 0
    private var files = 0
    private var frames = 0
    private var firstError: Error?
    private var finishing: ((Result<CaptureRecordingSummary, Error>) -> Void)?

    init(destination: URL, includeAudio: Bool, seconds: Int, mib: Int, queue: DispatchQueue) throws {
        self.destination = destination
        self.includeAudio = includeAudio
        duration = Double(seconds)
        maxBytes = mib * 1_048_576
        self.queue = queue
        current = try CaptureRecording(destination: destination, includeAudio: includeAudio, monitorSize: mib > 0)
    }

    func appendAudio(_ sample: CMSampleBuffer) throws {
        if includeAudio { lastAudio = sample }
        try current.appendAudio(sample)
    }

    func appendVideo(_ frame: VideoFrame) throws {
        if let firstError { throw firstError }
        if current.hasFrames, pending < 2, shouldRotate(at: frame.pts) {
            let base = destination.deletingPathExtension().lastPathComponent
            let extensionName = destination.pathExtension
            let number = String(format: "%03d", index + 1)
            let next = destination.deletingLastPathComponent()
                .appendingPathComponent(base + "-" + number)
                .appendingPathExtension(extensionName)
            guard !FileManager.default.fileExists(atPath: next.path) else {
                throw MediaProblem("已有同名分段 \(next.lastPathComponent)，录制已停止。")
            }
            let segment = try CaptureRecording(destination: next, includeAudio: includeAudio,
                monitorSize: maxBytes > 0, replaceExisting: false)
            if let lastAudio { try segment.appendAudio(lastAudio) }
            save(current, end: frame.pts)
            current = segment
            index += 1
            start = .invalid
            checkedSizeAt = .invalid
        }
        if try current.appendVideo(frame), !start.isNumeric { start = frame.pts }
    }

    private func shouldRotate(at pts: CMTime) -> Bool {
        if duration > 0, start.isNumeric, (pts - start).seconds >= duration { return true }
        guard maxBytes > 0, !checkedSizeAt.isNumeric || (pts - checkedSizeAt).seconds >= 1 else { return false }
        checkedSizeAt = pts
        return current.temporarySize >= maxBytes
    }

    func finish(_ completion: @escaping (Result<CaptureRecordingSummary, Error>) -> Void) {
        finishing = completion
        if current.hasFrames { save(current, end: nil) }
        completeIfIdle()
    }

    private func save(_ segment: CaptureRecording, end: CMTime?) {
        pending += 1
        segment.finish(end: end) { [self] result in
            queue.async { [self] in
                pending -= 1
                switch result {
                case .success(let count):
                    files += 1
                    frames += count
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
                completeIfIdle()
            }
        }
    }

    private func completeIfIdle() {
        guard pending == 0, let completion = finishing else { return }
        finishing = nil
        if let firstError { completion(.failure(firstError)) }
        else if files == 0 { completion(.failure(MediaProblem("录制没有收到视频帧。"))) }
        else { completion(.success(CaptureRecordingSummary(files: files, frames: frames))) }
    }
}
