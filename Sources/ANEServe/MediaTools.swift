import Foundation

struct MediaMetadata {
    let duration: Double
    let hasAudio: Bool
    let hasVideo: Bool
}

enum MediaTools {
    /// Demuxers ffmpeg may open for request media. Playlists (hls), concat lists, and text
    /// renderers (tty) can read other files on the Mac, so they are left out.
    static let allowedDemuxers = "mov,matroska,avi,mpegts,mpeg,wav,aiff,caf,mp3,aac,flac,ogg"
    /// Applies to the input that follows these options on every ffmpeg and ffprobe command line.
    static let inputRestrictions = ["-protocol_whitelist", "file", "-format_whitelist", allowedDemuxers]

    static func resolve(_ name: String) -> String? {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }.first(where: FileManager.default.isExecutableFile)
    }

    /// Runs ffmpeg or ffprobe and returns its standard output. Cancelling the calling task terminates the process.
    static func run(_ name: String, _ arguments: [String]) async throws -> Data {
        guard let executable = resolve(name) else {
            throw APIError(status: 503, message: "\(name) was not found. Install ffmpeg (including ffprobe) and retry.", type: "service_unavailable_error", code: "media_tool_unavailable")
        }
        let job = MediaProcess(name: name, executable: executable, arguments: ["-v", "error"] + inputRestrictions + arguments)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try job.run() })
                }
            }
        } onCancel: {
            job.terminate()
        }
    }

    static func inspect(_ url: URL) async throws -> MediaMetadata {
        let data = try await run("ffprobe", ["-show_entries", "format=duration:stream=codec_type,duration", "-of", "json", url.path])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = object["streams"] as? [[String: Any]] else {
            throw APIError(message: "Media metadata could not be read.", code: "invalid_media")
        }
        let format = object["format"] as? [String: Any]
        let video = streams.first { $0["codec_type"] as? String == "video" }
        let duration = video?["duration"] as? String ?? format?["duration"] as? String
        guard let raw = duration, let seconds = Double(raw), seconds.isFinite, seconds > 0 else {
            throw APIError(message: "The media must have a finite, positive duration.", code: "invalid_media")
        }
        return MediaMetadata(duration: seconds, hasAudio: streams.contains { $0["codec_type"] as? String == "audio" }, hasVideo: video != nil)
    }
}

/// One ffmpeg or ffprobe run that another thread can stop.
private final class MediaProcess: @unchecked Sendable {
    private let name: String
    private let process = Process()
    private let lock = NSLock()
    private var terminated = false

    init(name: String, executable: String, arguments: [String]) {
        self.name = name
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    /// Runs to completion on the calling thread and returns standard output.
    func run() throws -> Data {
        let output = Pipe()
        process.standardOutput = output
        try start()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if wasTerminated { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            throw APIError(message: "\(name) could not read or convert the supplied media.", code: "invalid_media")
        }
        return data
    }

    /// Stops the process, or keeps it from starting.
    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        terminated = true
        if process.isRunning { process.terminate() }
    }

    private func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if terminated { throw CancellationError() }
        try process.run()
    }

    private var wasTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }
}

/// Runs at most `limit` operations at once; later callers wait their turn, in order.
actor JobLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) { self.limit = limit }

    nonisolated func run<T>(_ operation: () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try await operation()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async throws {
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Passes the slot to the next waiter, if any.
    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
