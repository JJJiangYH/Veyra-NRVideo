// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import AVFoundation
import GameController
import ScreenCaptureKit

/// Both input adapters deliver on one serial queue. The display renderer
/// receives clocked sample buffers while effect work stays off the UI thread.
final class CapturePreview: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {
    let display = AVSampleBufferDisplayLayer()
    private let audio = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "io.veyra.capture", qos: .userInitiated)
    private var renderer: VideoRenderer?
    private var obsOutput: VeyraOBSOutput?
    private var captions: LiveCaptions?
    private var lastOBSFrame = Date.distantPast
    private var currentSize = CGSize.zero
    private var outputFormat: CMVideoFormatDescription?
    private var startTime = CMTime.invalid
    private var screen: SCStream?
    private var networkPlayer: AVPlayer?
    private var networkOutput: AVPlayerItemVideoOutput?
    private var networkState: NSKeyValueObservation?
    private var networkTimer: DispatchSourceTimer?
    private var networkStream: NetworkStreamBridge?
    private var remoteStream: VeyraStreamInput?
    private var pcInputClock: Timer?
    private var pcController: ObjectIdentifier?
    private var pcControllerState: PCControllerState?
    private var deviceSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var errorObserver: NSObjectProtocol?
    private var active = true
    private var effects: Effects
    private let timings = PipelineTimings()
    private var lastStat = Date.distantPast
    private var frames = 0
    private var dropped = 0
    var onError: ((String) -> Void)?
    var onStatistics: ((Int, Int, Int, [String: PipelineTimings.Summary]) -> Void)?

    init(effects: Effects) {
        self.effects = effects
        super.init()
        display.videoGravity = .resizeAspect
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(display.sampleBufferRenderer)
        synchronizer.addRenderer(audio)
        synchronizer.rate = 0
    }

    func setVolume(_ value: Float) {
        audio.volume = value
        queue.async { self.networkPlayer?.volume = value }
    }

    func setCaptions(_ captions: LiveCaptions?) {
        queue.async { self.captions = captions }
    }

    func setOBSOutput(_ output: VeyraOBSOutput?) {
        queue.async { self.obsOutput = output }
    }

    func performance(completion: @escaping (CapturePerformance) -> Void) {
        queue.async { [self] in
            let source = frames
            let generated = generatedFrames
            let skipped = dropped
            let queued = timings.timedSubmissions
            let late = timings.lateAtQueue
            let stages = timings.snapshot()
            display.sampleBufferRenderer.loadVideoPerformanceMetrics { metrics in
                let total = metrics?.totalNumberOfFrames
                let drops = metrics?.numberOfDroppedFrames
                let displayed = max(0, (total ?? 0) - (drops ?? 0))
                let delay = displayed == 0 ? nil : metrics.map { $0.totalAccumulatedFrameDelay * 1000 / Double(displayed) }
                let report = CapturePerformance(sourceFrames: source, generatedFrames: generated, skippedFrames: skipped,
                    queuedFrames: queued, queuedLate: late, rendererFrames: total, rendererDrops: drops,
                    rendererDelayMs: delay, stages: stages)
                DispatchQueue.main.async { completion(report) }
            }
        }
    }

    func startRemote(_ stream: VeyraStreamInput, window: NSWindow,
                     start: (@escaping (String?) -> Void) -> Void) {
        remoteStream = stream
        let pictures = DispatchSemaphore(value: 3)
        let audioPackets = DispatchSemaphore(value: 24)
        stream.onVideo = { [weak self] buffer, timestamp in
            guard let self, pictures.wait(timeout: .now()) == .success else { return }
            self.queue.async {
                defer { pictures.signal() }
                self.present(buffer, pts: timestamp, duration: CMTime(value: 1, timescale: 60))
            }
        }
        stream.onAudio = { [weak self] sample in
            guard let self, audioPackets.wait(timeout: .now()) == .success else { return }
            self.queue.async {
                defer { audioPackets.signal() }
                self.monitor(sample)
            }
        }
        stream.onStatus = { [weak self] status in
            self?.queue.async { [weak self] in self?.report(status) }
        }
        start { [weak self, weak window] error in
            DispatchQueue.main.async {
                guard let self, self.remoteStream === stream else { return }
                if let error {
                    self.onError?(error)
                } else {
                    self.pcInputClock = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self, weak window] _ in
                        self?.pollPCController(enabled: window?.isKeyWindow == true)
                    }
                }
            }
        }
    }

    private struct PCControllerState: Equatable {
        var buttons: Int32 = 0
        var leftTrigger: UInt8 = 0
        var rightTrigger: UInt8 = 0
        var leftX: Int16 = 0
        var leftY: Int16 = 0
        var rightX: Int16 = 0
        var rightY: Int16 = 0

        init(_ pad: GCExtendedGamepad) {
            // Moonlight's GameStream button flags (Limelight.h).
            let mapping: [(GCControllerButtonInput?, Int32)] = [
                (pad.dpad.up, 0x0001), (pad.dpad.down, 0x0002),
                (pad.dpad.left, 0x0004), (pad.dpad.right, 0x0008),
                (pad.buttonMenu, 0x0010), (pad.buttonOptions, 0x0020),
                (pad.leftThumbstickButton, 0x0040), (pad.rightThumbstickButton, 0x0080),
                (pad.leftShoulder, 0x0100), (pad.rightShoulder, 0x0200),
                (pad.buttonHome, 0x0400), (pad.buttonA, 0x1000),
                (pad.buttonB, 0x2000), (pad.buttonX, 0x4000), (pad.buttonY, 0x8000)
            ]
            for (button, flag) in mapping where button?.isPressed == true { buttons |= flag }
            leftTrigger = UInt8(clamping: Int((pad.leftTrigger.value * 255).rounded()))
            rightTrigger = UInt8(clamping: Int((pad.rightTrigger.value * 255).rounded()))
            leftX = Self.axis(pad.leftThumbstick.xAxis.value)
            leftY = Self.axis(pad.leftThumbstick.yAxis.value)
            rightX = Self.axis(pad.rightThumbstick.xAxis.value)
            rightY = Self.axis(pad.rightThumbstick.yAxis.value)
        }

        private static func axis(_ value: Float) -> Int16 {
            Int16(clamping: Int((value * 32767).rounded()))
        }
    }

    private func pollPCController(enabled: Bool) {
        guard let stream = remoteStream else { return }
        guard enabled, let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }),
              let pad = controller.extendedGamepad else {
            if pcController != nil { stream.controllerConnected(false) }
            pcController = nil
            pcControllerState = nil
            return
        }
        let identifier = ObjectIdentifier(controller)
        if pcController != identifier {
            if pcController != nil { stream.controllerConnected(false) }
            stream.controllerConnected(true)
            pcController = identifier
            pcControllerState = nil
        }
        let state = PCControllerState(pad)
        guard state != pcControllerState else { return }
        pcControllerState = state
        stream.controllerButtons(state.buttons, leftTrigger: state.leftTrigger, rightTrigger: state.rightTrigger,
                                 leftX: state.leftX, leftY: state.leftY, rightX: state.rightX, rightY: state.rightY)
    }

    func startNetwork(_ url: URL, historyMinutes: Int) async throws {
        let local: URL
        if ["rtp", "udp"].contains(url.scheme?.lowercased() ?? "") {
            let bridge = try NetworkStreamBridge()
            networkStream = bridge
            local = try await bridge.start(from: url, historyMinutes: historyMinutes)
            guard networkStream === bridge else { return }
        } else {
            local = url
        }
        queue.async { [self] in
            guard active else { return }
            let item = AVPlayerItem(url: local)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
            ])
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.volume = audio.volume
            networkPlayer = player
            networkOutput = output
            networkState = item.observe(\.status) { [weak self] current, _ in
                if current.status == .failed {
                    let reason = current.error?.localizedDescription ?? "无法打开网络流。"
                    self?.queue.async { [weak self] in self?.report(reason) }
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.pullNetwork() }
            networkTimer = timer
            timer.resume()
            if acceptingFrames { player.play() }
        }
    }

    func shiftNetwork(seconds: Double?) {
        queue.async {
            guard let player = self.networkPlayer, let item = player.currentItem else { return }
            let seekable = item.seekableTimeRanges.last?.timeRangeValue
            let target: CMTime
            if let seconds {
                let lower = seekable?.start.seconds ?? 0
                let upper = seekable?.end.seconds ?? player.currentTime().seconds
                target = CMTime(seconds: min(upper, max(lower, player.currentTime().seconds + seconds)), preferredTimescale: 600)
            } else if let seekable {
                target = CMTime(seconds: max(seekable.start.seconds, seekable.end.seconds - 2), preferredTimescale: 600)
            } else { return }
            self.startTime = .invalid
            self.clearInterpolationHistory()
            self.display.sampleBufferRenderer.flush()
            self.synchronizer.rate = 0
            player.seek(to: target)
        }
    }

    private func pullNetwork() {
        guard acceptingFrames, let player = networkPlayer, player.rate > 0, let networkOutput else { return }
        let host = ProcessInfo.processInfo.systemUptime
        let outputTime = networkOutput.itemTime(forHostTime: host + 0.04)
        guard outputTime.isNumeric, networkOutput.hasNewPixelBuffer(forItemTime: outputTime) else { return }
        var pts = CMTime.invalid
        guard let buffer = networkOutput.copyPixelBuffer(forItemTime: outputTime, itemTimeForDisplay: &pts),
              pts.isNumeric else { return }
        present(buffer, pts: pts, duration: .invalid)
    }

    func setPlaying(_ playing: Bool) {
        queue.async {
            guard self.active else { return }
            if playing {
                self.networkPlayer?.play()
                self.startTime = .invalid
                self.clearInterpolationHistory()
                self.display.sampleBufferRenderer.flush()
            } else {
                self.networkPlayer?.pause()
                self.synchronizer.rate = 0
                self.audio.flush()
            }
            self.acceptingFrames = playing
        }
    }

    private var acceptingFrames = true
    private var interpolator: VeyraInterpolation?
    private var conversion: VideoPixelConverter?
    private var reduction: NoiseReduction?
    private var previous: VideoFrame?
    private var lastAccepted: CMTime = .invalid
    private var previousLuma: [UInt8] = []
    private var generatedFrames = 0
    private var recording: CaptureRecordingSession?
    private var replay: CaptureReplay?
    private var lastAudioSample: CMSampleBuffer?

    func configure(_ settings: Effects) {
        queue.async {
            self.effects = settings
            self.renderer = nil
            self.outputFormat = nil
            self.clearInterpolationHistory()
            self.display.sampleBufferRenderer.flush()
        }
    }

    private func clearInterpolationHistory() {
        previous = nil
        previousLuma = []
        lastAccepted = .invalid
    }

    static func windowFilter(_ window: SCWindow) -> SCContentFilter {
        SCContentFilter(desktopIndependentWindow: window)
    }

    static func displayFilter(_ display: SCDisplay, excluding windows: [SCWindow]) -> SCContentFilter {
        SCContentFilter(display: display, excludingWindows: windows)
    }

    func startScreen(filter: SCContentFilter, dimensions: CGSize) async throws {
        let configuration = SCStreamConfiguration()
        let scale = min(1, 3840 / dimensions.width, 2160 / dimensions.height)
        configuration.width = max(2, Int(dimensions.width * scale) / 2 * 2)
        configuration.height = max(2, Int(dimensions.height * scale) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Publish the stream before awaiting start so stop can shut it down.
        screen = stream
        do {
            try await stream.startCapture()
            if screen !== stream { try? await stream.stopCapture() }
        } catch {
            if screen === stream { screen = nil }
            throw error
        }
    }

    func startDevice(_ device: AVCaptureDevice, audioDevice: AVCaptureDevice?) {
        queue.async { [self] in
            do {
                guard self.active else { return }
                let session = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: device)
                let video = AVCaptureVideoDataOutput()
                video.alwaysDiscardsLateVideoFrames = true
                video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                guard session.canAddInput(input), session.canAddOutput(video) else {
                    throw MediaProblem("无法连接这台视频采集设备。")
                }
                session.beginConfiguration()
                defer {
                    session.commitConfiguration()
                    if self.deviceSession === session { session.startRunning() }
                }
                session.addInput(input)
                session.addOutput(video)
                self.videoOutput = video
                video.setSampleBufferDelegate(self, queue: self.queue)
                if let audioDevice {
                    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                    let output = AVCaptureAudioDataOutput()
                    guard session.canAddInput(audioInput), session.canAddOutput(output) else {
                        throw MediaProblem("无法连接所选采集音频。")
                    }
                    session.addInput(audioInput)
                    session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: self.queue)
                }
                self.deviceSession = session
                self.errorObserver = NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
                ) { [weak self] notification in
                    let description = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                    self?.queue.async { [weak self] in self?.report(description ?? "视频采集已经中断。") }
                }
            } catch {
                self.report(error.localizedDescription)
            }
        }
    }

    func enableReplay(_ enabled: Bool, withAudio: Bool) {
        queue.async { [self] in
            self.replay = enabled ? CaptureReplay(queue: self.queue, includeAudio: withAudio) : nil
            self.replay?.onError = { [weak self] error in self?.onReplayError?(error) }
        }
    }

    var onReplayError: ((Error) -> Void)?

    func saveReplay(to url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard let replay = self.replay else {
                DispatchQueue.main.async { completion(.failure(MediaProblem("请先打开即时回放。"))) }
                return
            }
            replay.save(seconds: 15, to: url) { result in DispatchQueue.main.async { completion(result) } }
        }
    }

    func startRecording(to url: URL, withAudio: Bool, segmentSeconds: Int, segmentMiB: Int,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result = Result {
                guard self.active, self.recording == nil else { throw MediaProblem("采集已停止或正在录制。") }
                let recording = try CaptureRecordingSession(destination: url, includeAudio: withAudio,
                    seconds: segmentSeconds, mib: segmentMiB, queue: self.queue)
                if let sample = self.lastAudioSample { try recording.appendAudio(sample) }
                self.recording = recording
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    var onRecording: ((Result<CaptureRecordingSummary, Error>) -> Void)?

    func endRecording() {
        queue.async { self.finishRecording() }
    }

    private func finishRecording() {
        guard let recording else { return }
        self.recording = nil
        recording.finish { [weak self] result in
            DispatchQueue.main.async { self?.onRecording?(result) }
        }
    }

    func stop() {
        pcInputClock?.invalidate()
        pcInputClock = nil
        remoteStream?.stop()
        remoteStream = nil
        networkStream = nil
        if let stream = screen {
            screen = nil
            Task { try? await stream.stopCapture() }
        }
        queue.async {
            self.active = false
            self.obsOutput = nil
            self.captions = nil
            self.replay = nil
            self.networkTimer?.cancel()
            self.networkTimer = nil
            self.networkState = nil
            self.networkPlayer?.pause()
            self.networkPlayer = nil
            self.networkOutput = nil
            self.finishRecording()
            if let observer = self.errorObserver { NotificationCenter.default.removeObserver(observer) }
            self.errorObserver = nil
            self.deviceSession?.stopRunning()
            self.deviceSession = nil
            self.videoOutput = nil
            self.synchronizer.rate = 0
            self.audio.flush()
            self.display.sampleBufferRenderer.flush()
            self.renderer = nil
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.report(error.localizedDescription) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen {
            if let attachment = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
               let status = attachment[.status] as? Int, status != SCFrameStatus.complete.rawValue { return }
            present(sampleBuffer)
        } else if type == .audio {
            monitor(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput { present(sampleBuffer) }
        else { monitor(sampleBuffer) }
    }

    private func monitor(_ sample: CMSampleBuffer) {
        guard active else { return }
        lastAudioSample = sample
        if acceptingFrames { captions?.feed(sample) }
        if acceptingFrames, startTime.isValid, sample.presentationTimeStamp >= startTime,
           audio.isReadyForMoreMediaData { audio.enqueue(sample) }
        do { try replay?.addAudio(sample) }
        catch { onReplayError?(error); replay = nil }
        do { try recording?.appendAudio(sample) }
        catch { stopFailedRecording(error) }
    }

    private func present(_ sample: CMSampleBuffer) {
        guard let buffer = sample.imageBuffer else { return }
        present(buffer, pts: sample.presentationTimeStamp, duration: sample.duration)
    }

    private func present(_ buffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        autoreleasepool {
            guard active, (acceptingFrames || recording != nil || replay != nil), pts.isNumeric else { return }
            let sink = display.sampleBufferRenderer
            if sink.requiresFlushToResumeDecoding { sink.flush() }
            guard recording != nil || replay != nil || sink.isReadyForMoreMediaData else { dropped += 1; return }
            do {
                let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
                if renderer == nil || currentSize != size {
                    currentSize = size
                    renderer = try VideoRenderer(encoded: size, oriented: size, orientation: .identity,
                        hdrTransfer: nil, effects: effects, timings: timings)
                    outputFormat = nil
                    let strengths = effects.denoiseStrengths
                    reduction = strengths.isEmpty ? nil : NoiseReduction(strengths: strengths, timings: timings)
                    try configureInterpolation(size)
                }
                if effects.capture60To30, lastAccepted.isValid, (pts - lastAccepted).seconds < 0.025 {
                    return
                }
                lastAccepted = pts
                guard let renderer else { return }
                let input = try reduction?.apply(buffer, pts: pts) ?? buffer
                let protected = reduction != nil && !effects.denoiseProtection.isEmpty ? buffer : nil
                let frame = VideoFrame(buffer: input, pts: pts, duration: duration, generated: false, protectedSource: protected)
                if acceptingFrames && !startTime.isValid {
                    startTime = pts
                    let queueDelay = CMTime(value: effects.interpolate ? 4 : 2, timescale: 60)
                    synchronizer.setRate(1, time: networkPlayer?.currentTime() ?? (pts - queueDelay))
                }
                for intermediate in try interpolate(frame) {
                    if recording == nil && replay == nil && (intermediate.pts <= synchronizer.currentTime() || !sink.isReadyForMoreMediaData) {
                        dropped += 1
                    } else {
                        try render(intermediate, using: renderer)
                        generatedFrames += 1
                    }
                }
                try render(frame, using: renderer)
                frames += 1
                if Date().timeIntervalSince(lastStat) >= 0.5 {
                    lastStat = Date()
                    let stats = timings.snapshot()
                    let rendered = frames
                    let skipped = dropped
                    let generated = generatedFrames
                    DispatchQueue.main.async { [weak self] in self?.onStatistics?(rendered, generated, skipped, stats) }
                }
            } catch {
                report(error.localizedDescription)
            }
        }
    }

    private func configureInterpolation(_ size: CGSize) throws {
        clearInterpolationHistory()
        interpolator = nil
        conversion = nil
        guard effects.interpolate else { return }
        let analysis = VideoFrames.interpolationSize(source: size)
        let quality = effects.multiplier != 2 && effects.multiplier != 4
        guard let backend = VeyraInterpolation(width: Int(analysis.width), height: Int(analysis.height),
                                                quality: quality, multiplier: effects.multiplier) else {
            throw MediaProblem("无法启动实时采集补帧。")
        }
        interpolator = backend
        conversion = try VideoPixelConverter(width: Int(analysis.width), height: Int(analysis.height), hdr: nil,
                                              forInterpolation: true, floatingPoint: quality)
    }

    private func interpolate(_ frame: VideoFrame) throws -> [VideoFrame] {
        guard let converter = conversion, let interpolator else { return [] }
        let buffer = try converter.convert(frame.buffer)
        let luma = VideoFrames.measure(buffer)
        let input = VideoFrame(buffer: buffer, pts: frame.pts, duration: frame.duration,
                               generated: false, protectedSource: frame.protectedSource)
        defer { previous = input; previousLuma = luma }
        guard let previous, !luma.isEmpty, luma.count == previousLuma.count,
              (input.pts - previous.pts).seconds >= 0.007, (input.pts - previous.pts).seconds <= 0.11,
              VideoFrames.shouldInterpolate(previousLuma, luma) else { return [] }
        let start = ProcessInfo.processInfo.systemUptime
        guard let result = interpolator.interpolate(previous: previous.buffer,
            previousTime: previous.pts, current: input.buffer, currentTime: input.pts) else {
            dropped += effects.multiplier - 1
            return []
        }
        timings.record(.interpolation, seconds: ProcessInfo.processInfo.systemUptime - start)
        return result.map { generated in
            let first = (generated.presentationTimeStamp - previous.pts).seconds < (input.pts - previous.pts).seconds / 2
            return VideoFrame(buffer: generated.buffer, pts: generated.presentationTimeStamp, duration: .invalid,
                generated: true, protectedSource: first ? previous.protectedSource : input.protectedSource)
        }
    }

    private func render(_ frame: VideoFrame, using renderer: VideoRenderer) throws {
        let result = try renderer.render(frame)
        if let obsOutput, Date().timeIntervalSince(lastOBSFrame) >= 1.0 / 60 {
            lastOBSFrame = Date()
            obsOutput.publish(result.buffer)
        }
        do { try replay?.addVideo(result) }
        catch { onReplayError?(error); replay = nil }
        if let recording {
            do { try recording.appendVideo(result) }
            catch { stopFailedRecording(error) }
        }
        guard acceptingFrames, display.sampleBufferRenderer.isReadyForMoreMediaData else {
            if acceptingFrames { dropped += 1 }
            return
        }
        if outputFormat == nil {
            let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: result.buffer,
                formatDescriptionOut: &outputFormat)
            guard status == noErr else { throw MediaProblem("无法创建采集预览格式。") }
        }
        guard let outputFormat else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: result.pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: result.buffer,
            formatDescription: outputFormat, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { throw MediaProblem("无法创建采集预览帧。") }
        timings.record(.videoQueueLead, seconds: (result.pts - synchronizer.currentTime()).seconds)
        display.sampleBufferRenderer.enqueue(sample)
    }

    private func stopFailedRecording(_ error: Error) {
        if let recording {
            self.recording = nil
            recording.finish { _ in }
        }
        DispatchQueue.main.async { [weak self] in self?.onRecording?(.failure(error)) }
    }

    private func report(_ error: String) {
        guard active else { return }
        acceptingFrames = false
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }
}
