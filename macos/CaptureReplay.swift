// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import Foundation

/// Capture-queue-owned compressed history. Each segment owns its temporary
/// directory so a concurrent export keeps the selected files alive.
final class CaptureReplay {
    private let queue: DispatchQueue
    private let includeAudio: Bool
    private let segmentDuration = 5.0
    private let retainedDuration = 60.0
    private let retainedBytes = 256 * 1024 * 1024
    private var current: (file: TemporaryMedia, writer: CaptureRecording, start: CMTime)?
    private var completed: [(file: TemporaryMedia, timestamp: CMTime)] = []
    private var pendingWrites = 0
    private var audio: CMSampleBuffer?
    private var saving = false
    private var onPendingComplete: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(queue: DispatchQueue, includeAudio: Bool) {
        self.queue = queue
        self.includeAudio = includeAudio
    }

    func addAudio(_ sample: CMSampleBuffer) throws {
        audio = sample
        try current?.writer.appendAudio(sample)
    }

    func addVideo(_ frame: VideoFrame) throws {
        if let start = current?.start, (frame.pts - start).seconds >= segmentDuration { finalizeCurrent() }
        if current == nil {
            guard pendingWrites < 2 else { return }
            let file = try TemporaryMedia(filename: "segment.mp4")
            let writer = try CaptureRecording(destination: file.url, includeAudio: includeAudio)
            if let audio { try writer.appendAudio(audio) }
            current = (file, writer, frame.pts)
        }
        try current?.writer.appendVideo(frame)
    }

    func save(seconds: Double, to destination: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !saving else { completion(.failure(MediaProblem("正在保存另一个回放。"))); return }
        saving = true
        finalizeCurrent()
        let export = {
            self.saving = false
            let count = max(1, Int(ceil(seconds / self.segmentDuration)) + 1)
            let files = self.completed.suffix(count).map(\.file)
            Task.detached(priority: .userInitiated) {
                do {
                    try await Self.export(files, seconds: seconds, destination: destination)
                    completion(.success(()))
                } catch { completion(.failure(error)) }
            }
        }
        if pendingWrites == 0 { export() }
        else { onPendingComplete = export }
    }

    private func finalizeCurrent() {
        guard let part = current else { return }
        current = nil
        pendingWrites += 1
        part.writer.finish { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.pendingWrites -= 1
                switch result {
                case .success:
                    self.completed.append((part.file, part.start))
                    self.completed.sort { $0.timestamp < $1.timestamp }
                    self.trimHistory()
                case .failure(let error):
                    self.onError?(error)
                }
                if self.pendingWrites == 0, let callback = self.onPendingComplete {
                    self.onPendingComplete = nil
                    callback()
                }
            }
        }
    }

    private func trimHistory() {
        let count = Int(retainedDuration / segmentDuration)
        while completed.count > count { completed.removeFirst() }
        func size(of file: TemporaryMedia) -> Int {
            (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        var total = completed.reduce(0) { $0 + size(of: $1.file) }
        while total > retainedBytes && !completed.isEmpty {
            total -= size(of: completed.removeFirst().file)
        }
    }

    private static func export(_ parts: [TemporaryMedia], seconds: Double, destination: URL) async throws {
        guard !parts.isEmpty else { throw MediaProblem("回放缓存里还没有视频。") }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaProblem("无法创建回放视频轨道。") }
        let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var last = CMTime.zero
        for part in parts {
            let asset = AVURLAsset(url: part.url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let videoRange = try await sourceVideo.load(.timeRange)
            try video.insertTimeRange(videoRange, of: sourceVideo, at: last)
            if let audio, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = try await sourceAudio.load(.timeRange).intersection(videoRange)
                if !audioRange.isEmpty {
                    try audio.insertTimeRange(audioRange, of: sourceAudio, at: last + (audioRange.start - videoRange.start))
                }
            }
            last = last + videoRange.duration
        }
        guard last > .zero, let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        else { throw MediaProblem("没有可保存的回放。") }
        let targetLength = CMTime(seconds: seconds, preferredTimescale: 60000)
        // Stream-copy export preserves whole GOPs at the requested start.
        exporter.timeRange = CMTimeRange(start: max(.zero, last - targetLength), end: last)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".veyra-replay-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await exporter.export(to: temporary, as: .mp4)
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) { _ = try files.replaceItemAt(destination, withItemAt: temporary) }
        else { try files.moveItem(at: temporary, to: destination) }
    }
}
