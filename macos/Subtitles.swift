// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct SubtitleCue {
    let start: Double
    let end: Double
    let text: String
}

struct SubtitleTrack {
    let cues: [SubtitleCue]

    init(url: URL) throws {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count <= 16 * 1024 * 1024 else { throw MediaProblem("字幕文件超过 16 MB。") }
        guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16) else {
            throw MediaProblem("字幕需要 UTF-8 或 UTF-16 编码。")
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        cues = lines.components(separatedBy: "\n\n").compactMap(Self.parseCue).sorted { $0.start < $1.start }
        guard !cues.isEmpty else { throw MediaProblem("字幕里没有可读取的时间轴。") }
    }

    func text(at time: Double) -> String {
        cues.prefix(while: { $0.start <= time }).filter { $0.end > time }.map(\.text).joined(separator: "\n")
    }

    private static func parseCue(_ block: String) -> SubtitleCue? {
        let lines = block.split(separator: "\n")
        guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
        let points = lines[index].components(separatedBy: "-->")
        guard points.count == 2, let start = timestamp(points[0]), let end = timestamp(points[1]), start < end else {
            return nil
        }
        let text = lines.dropFirst(index + 1).joined(separator: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return text.isEmpty ? nil : SubtitleCue(start: start, end: end, text: text)
    }

    private static func timestamp(_ text: String) -> Double? {
        guard let value = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let fields = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        let values = fields.compactMap { Double($0) }
        guard fields.count == values.count, (2...3).contains(values.count), values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return nil
        }
        return values.reduce(0.0) { $0 * 60 + $1 }
    }
}
