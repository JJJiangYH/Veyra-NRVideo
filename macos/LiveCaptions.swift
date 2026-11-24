// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import Foundation
import Speech
import Translation

final class LiveCaptions {
    let request = SFSpeechAudioBufferRecognitionRequest()
    private let recognizer: SFSpeechRecognizer
    private var task: SFSpeechRecognitionTask?
    private let state = NSLock()
    private var latest = ""
    private var finished = false
    var onText: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    init(locale: Locale) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw MediaProblem("当前语言没有可用的本机语音识别资源。")
        }
        self.recognizer = recognizer
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
    }

    func start() {
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                // A rolling caption avoids repeating the entire recognition session.
                let segments = result.bestTranscription.segments
                let last = segments.last?.timestamp ?? 0
                let recent = segments.filter { $0.timestamp >= last - 5 }.suffix(16)
                let caption = recent.map(\.substring).joined(separator: " ")
                let changed = self.state.withLock { () -> Bool in
                    guard !self.finished, self.latest != caption else { return false }
                    self.latest = caption
                    return true
                }
                if changed && !caption.isEmpty {
                    DispatchQueue.main.async { [weak self] in self?.onText?(caption) }
                }
            } else if let error, self.state.withLock({ !self.finished }) {
                DispatchQueue.main.async { [weak self] in self?.onError?(error) }
            }
        }
    }

    func feed(_ sample: CMSampleBuffer) {
        state.withLock {
            if !finished { request.appendAudioSampleBuffer(sample) }
        }
    }

    func stop() {
        state.withLock {
            if !finished {
                finished = true
                request.endAudio()
            }
        }
        task?.cancel()
        task = nil
    }

    deinit { stop() }
}
