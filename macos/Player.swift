// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import AVFoundation
import CoreImage

final class VideoSurface: NSView {
    var receiveFile: ((URL) -> Void)?
    var activatePlayback: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel("视频预览")
    }

    required init?(coder: NSCoder) { nil }

    func show(_ display: AVSampleBufferDisplayLayer?) {
        layer?.sublayers = display.map { [$0] } ?? []
        needsLayout = true
    }

    func showImage(_ image: CGImage) {
        let display = CALayer()
        display.contents = image
        display.contentsGravity = .resizeAspect
        layer?.sublayers = [display]
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers?.first?.frame = bounds
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 { activatePlayback?() }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFile(sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedFile(sender) else { return false }
        receiveFile?(url)
        return true
    }

    private func droppedFile(_ sender: NSDraggingInfo) -> URL? {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])?.first as? URL
    }
}

struct PlaybackPerformance: Codable {
    let source: Int
    let generated: Int
    let skipped: Int
    let queued: Int
    let queuedLate: Int
    let skippedLateGenerated: Int
    let timedSubmissions: Int
    let rendererFrames: Int?
    let rendererDrops: Int?
    let rendererDelayMs: Double?
    let stages: [String: PipelineTimings.Summary]
}

final class Preview {
    let display = AVSampleBufferDisplayLayer()
    let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audio = AVSampleBufferAudioRenderer()
    private let timings: PipelineTimings
    private let work = DispatchQueue(label: "io.veyra.preview", qos: .userInitiated)
    private var pump: DispatchSourceTimer?
    private var frames: VideoFrames?
    private var renderer: VideoRenderer?
    private var obsOutput: VeyraOBSOutput?
    private var captions: LiveCaptions?
    private var lastOBSFrame = Date.distantPast
    private var audioReader: ClipReader?
    private var videoEnd = false
    private var audioEnd = false
    private var ready = false
    private var lastVideo = CMTime.invalid
    private var lastAudio = CMTime.invalid
    private var format: CMVideoFormatDescription?
    private var snapshots: [VideoFrame] = []
    private var renderedCount = 0
    private var skippedLateGenerated = 0
    private var lastStats = Date.distantPast
    var onReady: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onStatistics: ((PlaybackPerformance) -> Void)?

    init(hasAudio: Bool, time: CMTime, timingWindow: Int = 180) {
        timings = PipelineTimings(capacity: timingWindow)
        display.videoGravity = .resizeAspect
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(display.sampleBufferRenderer)
        if hasAudio { synchronizer.addRenderer(audio) }
        synchronizer.setRate(0, time: time)
    }

    var time: CMTime { synchronizer.currentTime() }
    var playing: Bool { synchronizer.rate != 0 }
    func play(at rate: Float = 1) { synchronizer.rate = rate }
    func pause() { synchronizer.rate = 0 }
    func volume(_ value: Float) { audio.volume = value }

    func setCaptions(_ captions: LiveCaptions?) {
        work.async { self.captions = captions }
    }

    func setOBSOutput(_ output: VeyraOBSOutput?) {
        work.async { self.obsOutput = output }
    }

    func start(media: MediaFile, effects: Effects, time startTime: CMTime, audioTrack: AVAssetTrack?) {
        work.async { [self] in
            do {
                frames = try VideoFrames(media: media, effects: effects, from: startTime, timings: timings)
                renderer = try VideoRenderer(media: media, effects: effects, timings: timings)
                if let track = audioTrack {
                    audioReader = try ClipReader(media: media, track: track, settings: ClipReader.audioSettings, from: startTime)
                } else {
                    audioEnd = true
                }
                let timer = DispatchSource.makeTimerSource(queue: work)
                timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.refill() }
                pump = timer
                timer.resume()
            } catch {
                reportError(error)
            }
        }
    }

    func stop() {
        pause()
        work.async { [self] in
            pump?.cancel()
            pump = nil
            frames = nil
            audioReader = nil
            obsOutput = nil
            captions = nil
            renderer = nil
            snapshots.removeAll()
            audio.flush()
        }
    }

    private func refill() {
        autoreleasepool {
            do {
                try prepareVideo()
                try prepareAudio()
                if !ready, lastVideo.isValid,
                   (videoEnd || lastVideo.seconds - time.seconds >= 0.075 || !display.sampleBufferRenderer.isReadyForMoreMediaData), (audioEnd || lastAudio.isValid) {
                    ready = true
                    DispatchQueue.main.async { [weak self] in self?.onReady?() }
                }
                if !ready, videoEnd, !lastVideo.isValid { throw MediaProblem("此位置没有可显示的视频帧。") }
                if !ready || Date().timeIntervalSince(lastStats) >= 0.5 {
                    lastStats = Date()
                    reportPerformance { [weak self] stats in self?.onStatistics?(stats) }
                }
                if videoEnd && audioEnd { pump?.cancel(); pump = nil }
            } catch {
                reportError(error)
            }
        }
    }

    private func prepareVideo() throws {
        if let obsOutput, Date().timeIntervalSince(lastOBSFrame) >= 1.0 / 60,
           let displayFrame = snapshots.last(where: { $0.pts <= time }) {
            lastOBSFrame = Date()
            obsOutput.publish(displayFrame.buffer)
        }
        guard let frames, let renderer, !videoEnd else { return }
        let sink = display.sampleBufferRenderer
        if sink.status == .failed { throw sink.error ?? MediaProblem("视频显示失败。") }
        for _ in 0..<3 {
            guard sink.isReadyForMoreMediaData,
                  !lastVideo.isValid || lastVideo.seconds - time.seconds < 0.28 else { return }
            guard let raw = try frames.next() else { videoEnd = true; return }
            if raw.generated && synchronizer.rate != 0 && raw.pts <= time {
                skippedLateGenerated += 1
                continue
            }
            let frame = try renderer.render(raw)
            if frame.generated && synchronizer.rate != 0 && frame.pts <= time {
                skippedLateGenerated += 1
                continue
            }
            if format == nil {
                guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame.buffer,
                        formatDescriptionOut: &format) == noErr else { throw MediaProblem("无法描述输出帧。") }
            }
            guard let format else { throw MediaProblem("缺少输出帧格式。") }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.pts, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frame.buffer,
                    formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
                  let sample else { throw MediaProblem("无法为预览打包视频帧。") }
            if !lastVideo.isValid,
               let items = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
               CFArrayGetCount(items) == 1 {
                let entry = unsafeBitCast(CFArrayGetValueAtIndex(items, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(entry, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if synchronizer.rate != 0 {
                timings.record(.videoQueueLead, seconds: (frame.pts - time).seconds)
            }
            sink.enqueue(sample)
            renderedCount += 1
            lastVideo = frame.pts
            snapshots.append(frame)
            while snapshots.count > 2 && snapshots[1].pts < time { snapshots.removeFirst() }
            if snapshots.count > 24 { snapshots.removeFirst() }
        }
    }

    private func prepareAudio() throws {
        guard let audioReader, !audioEnd else { return }
        if audio.status == .failed { throw audio.error ?? MediaProblem("音频播放失败。") }
        for _ in 0..<8 {
            guard audio.isReadyForMoreMediaData,
                  !lastAudio.isValid || lastAudio.seconds - time.seconds < 0.45 else { return }
            guard let sample = try audioReader.next() else { audioEnd = true; return }
            audio.enqueue(sample)
            if synchronizer.rate != 0 { captions?.feed(sample) }
            lastAudio = sample.presentationTimeStamp
        }
    }

    private func reportError(_ error: Error) {
        pump?.cancel()
        pump = nil
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    func performance(completion: @escaping (PlaybackPerformance) -> Void) {
        work.async { self.reportPerformance(completion) }
    }

    private func reportPerformance(_ completion: @escaping (PlaybackPerformance) -> Void) {
        let source = frames?.sourceCount ?? 0
        let generated = frames?.generatedCount ?? 0
        let skipped = frames?.skippedCount ?? 0
        let queued = renderedCount
        let late = timings.lateAtQueue
        let skippedLate = skippedLateGenerated
        let submitted = timings.timedSubmissions
        let stages = timings.snapshot()
        display.sampleBufferRenderer.loadVideoPerformanceMetrics { metrics in
            let total = metrics?.totalNumberOfFrames
            let dropped = metrics?.numberOfDroppedFrames
            let displayed = max(0, (total ?? 0) - (dropped ?? 0))
            let delay = displayed == 0 ? nil : metrics.map { $0.totalAccumulatedFrameDelay * 1000 / Double(displayed) }
            let report = PlaybackPerformance(source: source, generated: generated, skipped: skipped, queued: queued,
                queuedLate: late, skippedLateGenerated: skippedLate, timedSubmissions: submitted, rendererFrames: total,
                rendererDrops: dropped, rendererDelayMs: delay, stages: stages)
            DispatchQueue.main.async { completion(report) }
        }
    }

    func screenshot(to url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let currentTime = time
        work.async { [self] in
            let result = Result {
                guard let frame = snapshots.last(where: { $0.pts <= currentTime }) ?? snapshots.first,
                      let renderer, let colour = CGColorSpace(name: CGColorSpace.sRGB) else {
                    throw MediaProblem("请等待视频画面出现。")
                }
                try renderer.context.writePNGRepresentation(of: CIImage(cvPixelBuffer: frame.buffer),
                    to: url, format: .RGBA8, colorSpace: colour)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
