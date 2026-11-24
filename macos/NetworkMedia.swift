// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import Foundation
import Network

/// Serve just this stream's rolling HLS playlist and segments to AVPlayer.
final class LoopbackSegments {
    private let folder: URL
    private let queue = DispatchQueue(label: "io.veyra.hls-loopback")
    private let listener: NWListener
    private var replied = false

    init(folder: URL) throws {
        self.folder = folder
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.replied else { return }
                switch state {
                case .ready:
                    self.replied = true
                    if let port = self.listener.port,
                       let address = URL(string: "http://127.0.0.1:\(port.rawValue)/live.m3u8") {
                        continuation.resume(returning: address)
                    } else {
                        continuation.resume(throwing: MediaProblem("无法分配本机时移地址。"))
                    }
                case .failed(let error):
                    self.replied = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    self.replied = true
                    continuation.resume(throwing: MediaProblem("网络预览已经停止。"))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.read(connection, received: Data())
                self.queue.asyncAfter(deadline: .now() + 8) { connection.cancel() }
            }
            listener.start(queue: queue)
        }
    }

    deinit { listener.cancel() }

    private func read(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            let request = received + (data ?? Data())
            if request.count > 16384 {
                connection.cancel()
            } else if let block = String(data: request, encoding: .utf8), block.contains("\r\n\r\n") {
                self.respond(connection, request: block)
            } else if done {
                connection.cancel()
            } else {
                self.read(connection, received: request)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let lines = request.components(separatedBy: "\r\n")
        let command = lines.first?.split(separator: " ") ?? []
        guard command.count == 3, command[0] == "GET" || command[0] == "HEAD",
              command[1].hasPrefix("/") else {
            send(connection, status: "400 Bad Request")
            return
        }
        let name = String(command[1].dropFirst())
        guard name == "live.m3u8" || name == "init.mp4" ||
                (name.hasPrefix("segment-") && name.hasSuffix(".m4s") &&
                 name.dropFirst(8).dropLast(4).allSatisfy(\.isASCII) &&
                 name.dropFirst(8).dropLast(4).allSatisfy(\.isNumber)),
              let data = try? Data(contentsOf: folder.appendingPathComponent(name), options: .mappedIfSafe) else {
            send(connection, status: "404 Not Found")
            return
        }
        let mime = name.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4"
        var payload = data
        var status = "200 OK"
        var extra = ""
        if let line = lines.first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
            let values = line.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            guard values.count == 2, let from = Int(values[0]), from >= 0, from < data.count else {
                send(connection, status: "416 Range Not Satisfiable", extra: "Content-Range: bytes */\(data.count)\r\n")
                return
            }
            let to = min(Int(values[1]) ?? (data.count - 1), data.count - 1)
            guard to >= from else {
                send(connection, status: "416 Range Not Satisfiable")
                return
            }
            payload = data.subdata(in: from..<(to + 1))
            status = "206 Partial Content"
            extra = "Content-Range: bytes \(from)-\(to)/\(data.count)\r\n"
        }
        send(connection, status: status, mime: mime, body: payload, headOnly: command[0] == "HEAD", extra: extra)
    }

    private func send(_ connection: NWConnection, status: String, mime: String = "text/plain",
                      body: Data = Data(), headOnly: Bool = false, extra: String = "") {
        let header = Data(("HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Type: \(mime)\r\n" +
            "Content-Length: \(body.count)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\n\(extra)\r\n").utf8)
        connection.send(content: headOnly ? header : header + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

final class NetworkStreamBridge {
    private let folder: TemporaryMedia
    private let server: LoopbackSegments
    private let writer = Process()

    init() throws {
        folder = try TemporaryMedia(filename: "live.m3u8")
        server = try LoopbackSegments(folder: folder.url.deletingLastPathComponent())
    }

    func start(from source: URL, historyMinutes: Int) async throws -> URL {
        guard let ffmpeg = MediaContainer.ffmpeg else { throw MediaProblem("RTP/UDP 播放需要 FFmpeg。") }
        let local = try await server.start()
        writer.executableURL = ffmpeg
        writer.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error",
            "-protocol_whitelist", "udp,rtp", "-rw_timeout", "8000000", "-i", source.absoluteString,
            "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-bsf:a", "aac_adtstoasc",
            "-f", "hls", "-hls_time", "1", "-hls_list_size", String(max(3, historyMinutes * 60)),
            "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4",
            "-hls_flags", "delete_segments+temp_file+independent_segments",
            "-hls_segment_filename", folder.url.deletingLastPathComponent().appendingPathComponent("segment-%08d.m4s").path,
            folder.url.path]
        writer.standardOutput = FileHandle.nullDevice
        writer.standardError = FileHandle.nullDevice
        try writer.run()
        for _ in 0..<150 {
            try Task.checkCancellation()
            if let playlist = try? String(contentsOf: folder.url, encoding: .utf8),
               playlist.split(separator: "\n").filter({ $0.hasSuffix(".m4s") }).count >= 2 {
                return local
            }
            if !writer.isRunning { throw MediaProblem("FFmpeg 无法读取 RTP/UDP 直播源。") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw MediaProblem("等待 RTP/UDP 直播数据超时。")
    }

    deinit { if writer.isRunning { writer.terminate() } }
}
