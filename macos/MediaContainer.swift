// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import Foundation

final class TemporaryMedia {
    let url: URL
    private let directory: URL

    init(filename: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Veyra-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        url = directory.appendingPathComponent(filename)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum MediaContainer {
    static var supportsMatroska: Bool { ffmpeg != nil }
    static var ffmpeg: URL? {
        let resources = Bundle.main.resourceURL?.appendingPathComponent("ffmpeg")
        let path = ProcessInfo.processInfo.environment["VEYRA_FFMPEG"].map { URL(fileURLWithPath: $0) }
        let possible = [resources, path, URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
                        URL(fileURLWithPath: "/usr/local/bin/ffmpeg")]
        return possible.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func preparePlayback(_ url: URL) async throws -> TemporaryMedia? {
        guard url.pathExtension.lowercased() == "mkv" else { return nil }
        return try await Task.detached(priority: .userInitiated) {
            let media = try TemporaryMedia(filename: "playback.mov")
            let args = ["-protocol_whitelist", "file", "-i", url.path,
                        "-map", "0:v:0", "-map", "0:a?", "-map", "0:s?",
                        "-c", "copy", "-c:s", "mov_text"]
            try run(args, output: media.url)
            let asset = AVURLAsset(url: media.url)
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let formats = try await track.load(.formatDescriptions)
                // FFmpeg defaults to the hev1 tag when the source lacks a MOV
                // sample entry. AVFoundation requires hvc1 for this path.
                if formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == 0x68657631 }) {
                    let appleMedia = try TemporaryMedia(filename: "playback.mov")
                    try run(args + ["-tag:v", "hvc1"], output: appleMedia.url)
                    return appleMedia
                }
            }
            return media
        }.value
    }

    static func readSubtitle(from source: URL, index: Int) async throws -> SubtitleTrack {
        try await Task.detached(priority: .userInitiated) {
            let file = try TemporaryMedia(filename: "subtitle.srt")
            try run(["-protocol_whitelist", "file", "-i", source.path,
                     "-map", "0:s:\(index)", "-c:s", "srt"], output: file.url)
            return try SubtitleTrack(url: file.url)
        }.value
    }

    static func finishExport(_ source: URL, subtitles: URL?, start: Double, end: Double,
                             destination: URL, cancel: () -> Bool) throws {
        let local = ["-protocol_whitelist", "file"]
        var args = local + ["-i", source.path]
        if let subtitles {
            args += local + ["-ss", String(start), "-t", String(end - start), "-i", subtitles.path]
        }
        args += ["-map", "0", "-map_metadata", "0", "-c", "copy"]
        if subtitles != nil {
            args += ["-map", "1:s?", "-c:s", destination.pathExtension == "mkv" ? "srt" : "mov_text"]
        }
        try run(args, output: destination, cancel: cancel)
    }

    private static func run(_ arguments: [String], output: URL, cancel: () -> Bool = { false }) throws {
        guard let ffmpeg else { throw MediaProblem("此版本需要 FFmpeg 才能打开或导出 MKV。") }
        let log = try TemporaryMedia(filename: "ffmpeg.log")
        guard FileManager.default.createFile(atPath: log.url.path, contents: nil) else {
            throw MediaProblem("无法写入 FFmpeg 日志。")
        }
        let handle = try FileHandle(forWritingTo: log.url)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error"] + arguments + [output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = handle
        try process.run()
        let started = ProcessInfo.processInfo.systemUptime
        while process.isRunning {
            if cancel() || ProcessInfo.processInfo.systemUptime - started > 300 {
                process.terminate()
                process.waitUntilExit()
                throw MediaProblem(cancel() ? "已取消导出。" : "容器转换超时。")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.terminationStatus == 0 else {
            let description = (try? String(contentsOf: log.url, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MediaProblem(description.map { "无法转换媒体容器。\(String($0.suffix(320)))" } ?? "无法转换媒体容器。")
        }
    }
}
