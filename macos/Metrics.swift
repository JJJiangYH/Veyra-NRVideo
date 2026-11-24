// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct CapturePerformance: Encodable {
    let sourceFrames: Int
    let generatedFrames: Int
    let skippedFrames: Int
    let queuedFrames: Int
    let queuedLate: Int
    let rendererFrames: Int?
    let rendererDrops: Int?
    let rendererDelayMs: Double?
    let stages: [String: PipelineTimings.Summary]
}

/// Collected on the thread that consumes a frame. A short rolling window
/// keeps player memory bounded. Benchmarks can retain a longer sample window.
final class PipelineTimings {
    enum Stage: String, CaseIterable {
        case decodeRead
        case interpolationInput
        case interpolation
        case denoise
        case metal
        case hdrOutput
        case videoQueueLead
    }

    struct Summary: Codable {
        let samples: Int
        let p50Ms: Double
        let p95Ms: Double
    }

    private let capacity: Int
    private var samples: [Stage: [Double]] = [:]
    private var nextIndex: [Stage: Int] = [:]
    private(set) var lateAtQueue = 0
    private(set) var timedSubmissions = 0

    init(capacity: Int = 180) { self.capacity = capacity }

    func record(_ stage: Stage, seconds: Double) {
        guard seconds.isFinite else { return }
        if stage == .videoQueueLead {
            timedSubmissions += 1
            if seconds < 0 { lateAtQueue += 1 }
        }
        let value = seconds * 1000
        if samples[stage, default: []].count < capacity {
            samples[stage, default: []].append(value)
        } else {
            let index = nextIndex[stage, default: 0]
            samples[stage]?[index] = value
            nextIndex[stage] = (index + 1) % capacity
        }
    }

    func snapshot() -> [String: Summary] {
        var result: [String: Summary] = [:]
        for stage in Stage.allCases {
            guard let values = samples[stage]?.sorted(), !values.isEmpty else { continue }
            result[stage.rawValue] = Summary(samples: values.count,
                p50Ms: values[(values.count - 1) / 2],
                p95Ms: values[Int(ceil(Double(values.count) * 0.95)) - 1])
        }
        return result
    }
}
