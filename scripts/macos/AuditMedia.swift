// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct AuditFailure: Error { var reason: String }

@main
struct AuditMedia {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("audio audit: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 && (args[1] == "audio" || (args[1] == "stills" && args.count >= 4)) else { throw AuditFailure(reason: "用法：audit-media audio INPUT... | stills DIRECTORY INPUT...") }
        if args[1] == "stills" {
            let out = URL(fileURLWithPath: args[2], isDirectory: true)
            for (index, path) in args.dropFirst(3).enumerated() {
                let asset = AVURLAsset(url: URL(fileURLWithPath: path))
                let generator = AVAssetImageGenerator(asset: asset)
                generator.maximumSize = CGSize(width: 960, height: 540)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let image = try await generator.image(at: CMTime(value: 240240, timescale: 60000)).image
                let file = out.appendingPathComponent("audit-still-\(index).jpg")
                guard let dst = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw AuditFailure(reason: "destination") }
                CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
                guard CGImageDestinationFinalize(dst) else { throw AuditFailure(reason: "image finalize") }
            }
            return
        }
        for path in args.dropFirst(2) {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AuditFailure(reason: "no track") }
            let reader = try AVAssetReader(asset: asset)
            let audio = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(audio)
            guard reader.startReading() else { throw AuditFailure(reason: "start reading") }
            var hash = SHA256()
            var packets = 0
            var sampleBytes = 0
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let sample = audio.copyNextSampleBuffer() else { return false }
                guard let data = sample.dataBuffer else { return true }
                let length = CMBlockBufferGetDataLength(data)
                guard length > 0 else { return true }
                var bytes = Data(count: length)
                let status = bytes.withUnsafeMutableBytes { raw in
                    CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw AuditFailure(reason: "copy data") }
                hash.update(data: bytes)
                sampleBytes += length
                packets += 1
                return true
            }) {}
            guard reader.status == .completed else { throw AuditFailure(reason: "reader status \(reader.status.rawValue): \(String(describing: reader.error))") }
            let video = try await asset.loadTracks(withMediaType: .video).first!
            let duration = try await asset.load(.duration).seconds
            let videoRange = try await video.load(.timeRange)
            let audioRange = try await track.load(.timeRange)
            print("\(hash.finalize().map { String(format: "%02x", $0) }.joined()) \(packets) \(sampleBytes) \(duration) \(videoRange.start.seconds) \(audioRange.start.seconds) \(path)")
        }
    }
}
