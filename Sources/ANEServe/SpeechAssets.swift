import Foundation
import Speech
import AVFoundation

actor SpeechAssets {
    static let shared = SpeechAssets()
    private var installation: Task<Void, Error>?

    static func transcriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    static func readiness() async -> [String: Any] {
        guard SpeechTranscriber.isAvailable else {
            return ["locale": "en-US", "status": "unsupported", "ready": false]
        }
        let status = await AssetInventory.status(forModules: [transcriber()])
        return ["locale": "en-US", "status": String(describing: status), "ready": status == .installed]
    }

    func prepare() async throws {
        if let installation { return try await installation.value }
        let task = Task {
            guard SpeechTranscriber.isAvailable else {
                throw APIError(status: 503, message: "SpeechTranscriber is unavailable on this Mac.", type: "service_unavailable_error", code: "speech_unavailable")
            }
            let module = Self.transcriber()
            let status = await AssetInventory.status(forModules: [module])
            if status == .installed { return }
            guard status != .unsupported else {
                throw APIError(status: 503, message: "English (United States) transcription is unsupported on this Mac.", type: "service_unavailable_error", code: "speech_locale_unsupported")
            }
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                throw APIError(status: 503, message: "Speech assets could not be installed. Connect the Mac to the internet and run ane-serve --prepare-speech, then retry.", type: "service_unavailable_error", code: "speech_assets_unavailable")
            }
            guard await AssetInventory.status(forModules: [module]) == .installed else {
                throw APIError(status: 503, message: "Speech assets are not ready. Run ane-serve --prepare-speech and retry after installation finishes.", type: "service_unavailable_error", code: "speech_assets_unavailable")
            }
        }
        installation = task
        defer { installation = nil }
        try await task.value
    }

    static func transcribe(_ url: URL) async throws -> (segments: [VideoTranscriptSegment], fullText: String, elapsed: Double) {
        try await shared.prepare()
        let started = CFAbsoluteTimeGetCurrent()
        let module = transcriber()
        let analyzer = SpeechAnalyzer(modules: [module])
        let file = try AVAudioFile(forReading: url)
        let reader = Task { () throws -> [VideoTranscriptSegment] in
            var segments: [VideoTranscriptSegment] = []
            for try await result in module.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(VideoTranscriptSegment(startTimeSec: result.range.start.seconds.isFinite ? result.range.start.seconds : 0,
                                                           endTimeSec: result.range.end.seconds.isFinite ? result.range.end.seconds : 0, text: text))
                }
            }
            return segments
        }
        do {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            let segments = try await reader.value
            return (segments, segments.map(\.text).joined(separator: " "), CFAbsoluteTimeGetCurrent() - started)
        } catch {
            reader.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}
