import Foundation
import Vision
import Speech
import AVFoundation
import FoundationModels

public struct VideoTranscriptSegment: Codable, Sendable {
    public let startTimeSec: Double
    public let endTimeSec: Double
    public let text: String
}

public struct VideoSceneKeyframe: Codable, Sendable {
    public let sceneIndex: Int
    public let timestampSec: Double
    public let visualChangeDistance: Float
    public let ocrText: [String]
    public let vlmDescription: String
    public let captionStatus: String
}

public struct VideoStageFailure: Codable, Sendable {
    public let stage: String
    public let code: String
    public let message: String
    public let sceneIndex: Int?

    init(stage: String, error: Error, sceneIndex: Int? = nil) {
        let api = APIError.from(error)
        self.stage = stage
        self.code = api.code
        self.message = api.message
        self.sceneIndex = sceneIndex
    }
}

public struct VideoIntelligenceReport: Codable, Sendable {
    public let videoPath: String
    public let status: String
    public let stageStatus: [String: String]
    public let warnings: [VideoStageFailure]
    public let requestedDurationSec: Double
    public let analyzedDurationSec: Double
    public let totalProcessingTimeSec: Double
    public let realtimeSpeedupFactor: Double
    public let audioTranscriptionTimeSec: Double
    public let visualScanTimeSec: Double
    public let totalFramesEvaluated: Int
    public let detectedSceneCount: Int
    public let aneAverageFabricBandwidthGBps: Double?
    public let anePeakFabricBandwidthGBps: Double?
    public let aneOverdriveResidencyPercent: Double?
    public let gpuAveragePowerWatts: Double?
    public let cpuAveragePowerWatts: Double?
    public let telemetryStatus: String
    public let transcriptSegments: [VideoTranscriptSegment]
    public let fullTranscriptText: String
    public let scenes: [VideoSceneKeyframe]
    public let executiveSummary: String

    enum CodingKeys: String, CodingKey {
        case videoPath, status, stageStatus, warnings, requestedDurationSec, analyzedDurationSec
        case totalProcessingTimeSec, realtimeSpeedupFactor, audioTranscriptionTimeSec, visualScanTimeSec
        case totalFramesEvaluated, detectedSceneCount, aneAverageFabricBandwidthGBps, anePeakFabricBandwidthGBps
        case aneOverdriveResidencyPercent, gpuAveragePowerWatts, cpuAveragePowerWatts, telemetryStatus
        case transcriptSegments, fullTranscriptText, scenes, executiveSummary
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(videoPath, forKey: .videoPath)
        try values.encode(status, forKey: .status)
        try values.encode(stageStatus, forKey: .stageStatus)
        try values.encode(warnings, forKey: .warnings)
        try values.encode(requestedDurationSec, forKey: .requestedDurationSec)
        try values.encode(analyzedDurationSec, forKey: .analyzedDurationSec)
        try values.encode(totalProcessingTimeSec, forKey: .totalProcessingTimeSec)
        try values.encode(realtimeSpeedupFactor, forKey: .realtimeSpeedupFactor)
        try values.encode(audioTranscriptionTimeSec, forKey: .audioTranscriptionTimeSec)
        try values.encode(visualScanTimeSec, forKey: .visualScanTimeSec)
        try values.encode(totalFramesEvaluated, forKey: .totalFramesEvaluated)
        try values.encode(detectedSceneCount, forKey: .detectedSceneCount)
        // Encode optional metrics explicitly: missing data is null, never zero or an omitted key.
        try values.encode(aneAverageFabricBandwidthGBps, forKey: .aneAverageFabricBandwidthGBps)
        try values.encode(anePeakFabricBandwidthGBps, forKey: .anePeakFabricBandwidthGBps)
        try values.encode(aneOverdriveResidencyPercent, forKey: .aneOverdriveResidencyPercent)
        try values.encode(gpuAveragePowerWatts, forKey: .gpuAveragePowerWatts)
        try values.encode(cpuAveragePowerWatts, forKey: .cpuAveragePowerWatts)
        try values.encode(telemetryStatus, forKey: .telemetryStatus)
        try values.encode(transcriptSegments, forKey: .transcriptSegments)
        try values.encode(fullTranscriptText, forKey: .fullTranscriptText)
        try values.encode(scenes, forKey: .scenes)
        try values.encode(executiveSummary, forKey: .executiveSummary)
    }
}

public final class VideoIntelligenceScanner: @unchecked Sendable {
    private let telemetry: SiliconTelemetrySampler

    public init(telemetry: SiliconTelemetrySampler) { self.telemetry = telemetry }

    public static func briefOCRHint(from lines: [String]) -> String {
        guard !lines.isEmpty else { return "None" }
        let preview = lines.prefix(3).joined(separator: " | ")
        let clipped = String(preview.prefix(140)) + (preview.count > 140 ? "…" : "")
        return clipped + (lines.count > 3 ? " (+\(lines.count - 3) more lines stored in ocrText)" : "")
    }

    private static func selectEvenlyDistributed<T>(_ items: [T], maxCount: Int) -> [T] {
        guard maxCount > 0, !items.isEmpty else { return [] }
        if items.count <= maxCount { return items }
        if maxCount == 1 { return [items[0]] }
        return (0..<maxCount).map { items[Int((Double($0) / Double(maxCount - 1) * Double(items.count - 1)).rounded())] }
    }

    public func scanVideo(at videoURL: URL, maxDurationSeconds: Double = 180, frameSampleIntervalSeconds: Double = 1,
                          sceneDistanceThreshold: Float = 0.42, maxVLMScenes: Int = 8,
                          progressHandler: (@Sendable (String) -> Void)? = nil) async throws -> VideoIntelligenceReport {
        let options = try VideoScanOptions(maxDuration: maxDurationSeconds, frameInterval: frameSampleIntervalSeconds,
                                           sceneThreshold: Double(sceneDistanceThreshold), maxVLMScenes: maxVLMScenes)
        let overallStart = CFAbsoluteTimeGetCurrent()
        let metadata = try await MediaTools.inspect(videoURL)
        guard metadata.hasVideo else { throw APIError(message: "The input must contain a video track.", code: "invalid_video") }
        let duration = min(options.maxDuration, metadata.duration)
        if metadata.hasAudio { try await SpeechAssets.shared.prepare() }
        let snapStart = telemetry.takeSnapshot()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ane_scan_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let wav = work.appendingPathComponent("audio.wav")
        let frames = work.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        progressHandler?(String(format: "Analyzing %.2fs of video (requested %.2fs)...", duration, options.maxDuration))
        try await withThrowingTaskGroup(of: Void.self) { group in
            if metadata.hasAudio {
                group.addTask {
                    _ = try await MediaTools.run("ffmpeg", ["-nostdin", "-y", "-i", videoURL.path, "-t", String(duration), "-vn", "-ac", "1", "-ar", "16000", "-f", "wav", wav.path])
                }
            }
            group.addTask {
                _ = try await MediaTools.run("ffmpeg", ["-nostdin", "-y", "-i", videoURL.path, "-t", String(duration),
                                                       "-vf", "fps=1/\(options.frameInterval),scale=640:-2", "-q:v", "4", frames.appendingPathComponent("frame_%06d.jpg").path])
            }
            try await group.waitForAll()
        }
        progressHandler?("Transcribing audio and analyzing scene candidates...")
        async let audioTask = Self.analyzeAudio(wav, enabled: metadata.hasAudio)
        async let visualTask = analyzeFrames(frames, options: options)
        let (audio, visual) = try await (audioTask, visualTask)
        var warnings = audio.warnings + visual.warnings
        var stages = ["transcription": metadata.hasAudio ? (audio.warnings.isEmpty ? "complete" : "failed") : "skipped",
                      "visualAnalysis": visual.warnings.isEmpty ? "complete" : "partial",
                      "captions": options.maxVLMScenes == 0 ? "skipped" : visual.scenes.allSatisfy { $0.captionStatus == "complete" } ? "complete" : "partial"]
        progressHandler?("Generating the combined summary...")
        let summary: String
        do {
            try APIError.requireModel()
            let session = LanguageModelSession(instructions: "Synthesize a video transcript and visual timeline into three concise summary bullets. Use only the supplied evidence.")
            let timeline = visual.scenes.prefix(10).map { "[\($0.timestampSec)s] \($0.vlmDescription) OCR: \(Self.briefOCRHint(from: $0.ocrText))" }.joined(separator: "\n")
            let prompt = "Video: \(videoURL.lastPathComponent). Actual analyzed duration: \(duration) seconds.\nTimeline:\n\(timeline)\nTranscript excerpt:\n\(audio.text.prefix(2400))"
            summary = try await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 256)).content
            stages["summary"] = "complete"
        } catch {
            summary = ""
            stages["summary"] = "failed"
            warnings.append(VideoStageFailure(stage: "summary", error: error))
        }
        let elapsed = max(CFAbsoluteTimeGetCurrent() - overallStart, 0.001)
        let sample: TelemetrySample?
        if let start = snapStart, let end = telemetry.takeSnapshot() { sample = telemetry.computeDelta(from: start, to: end) }
        else { sample = nil }
        return VideoIntelligenceReport(videoPath: videoURL.path, status: warnings.isEmpty ? "complete" : "partial", stageStatus: stages, warnings: warnings,
                                       requestedDurationSec: options.maxDuration, analyzedDurationSec: duration, totalProcessingTimeSec: elapsed,
                                       realtimeSpeedupFactor: duration / elapsed, audioTranscriptionTimeSec: audio.elapsed, visualScanTimeSec: visual.elapsed,
                                       totalFramesEvaluated: visual.frames, detectedSceneCount: visual.detected,
                                       aneAverageFabricBandwidthGBps: sample?.aneFabricBandwidthGBps, anePeakFabricBandwidthGBps: sample?.anePeakFabricBandwidthGBps,
                                       aneOverdriveResidencyPercent: sample?.aneOverdriveResidencyPercent, gpuAveragePowerWatts: sample?.gpuPowerWatts,
                                       cpuAveragePowerWatts: sample?.cpuPowerWatts, telemetryStatus: TelemetrySample.json(sample)["status"] as? String ?? "unavailable",
                                       transcriptSegments: audio.segments, fullTranscriptText: audio.text, scenes: visual.scenes, executiveSummary: summary)
    }

    private static func analyzeAudio(_ url: URL, enabled: Bool) async -> (segments: [VideoTranscriptSegment], text: String, elapsed: Double, warnings: [VideoStageFailure]) {
        guard enabled else { return ([], "", 0, []) }
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let result = try await SpeechAssets.transcribe(url)
            return (result.segments, result.fullText, result.elapsed, [])
        } catch {
            return ([], "", CFAbsoluteTimeGetCurrent() - start, [VideoStageFailure(stage: "transcription", error: error)])
        }
    }

    private func analyzeFrames(_ directory: URL, options: VideoScanOptions) async throws -> (scenes: [VideoSceneKeyframe], frames: Int, detected: Int, elapsed: Double, warnings: [VideoStageFailure]) {
        let start = CFAbsoluteTimeGetCurrent()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw APIError(message: "No frames could be extracted from the video.", code: "invalid_video") }
        var previous: VNFeaturePrintObservation?
        var candidates: [(URL, Double, Float)] = []
        var warnings: [VideoStageFailure] = []
        for (index, url) in files.enumerated() {
            try Task.checkCancellation()
            do {
                let request = VNGenerateImageFeaturePrintRequest()
                try VNImageRequestHandler(url: url).perform([request])
                guard let current = request.results?.first else { throw APIError(message: "Vision returned no feature print.", code: "vision_failed") }
                var distance: Float = 1
                if let previous { try current.computeDistance(&distance, to: previous) }
                if previous == nil || distance >= options.sceneThreshold {
                    candidates.append((url, Double(index) * options.frameInterval, distance))
                    previous = current
                }
            } catch {
                warnings.append(VideoStageFailure(stage: "sceneDetection", error: error))
            }
        }
        guard !candidates.isEmpty else { throw APIError(message: "Vision could not analyze any video frames.", code: "vision_failed") }
        var scenes: [VideoSceneKeyframe] = []
        for (index, candidate) in Self.selectEvenlyDistributed(candidates, maxCount: options.maxVLMScenes).enumerated() {
            var ocr: [String] = []
            do {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try VNImageRequestHandler(url: candidate.0).perform([request])
                ocr = (request.results ?? []).compactMap { observation in
                    guard let top = observation.topCandidates(1).first, top.confidence >= 0.45 else { return nil }
                    return top.string
                }
            } catch { warnings.append(VideoStageFailure(stage: "ocr", error: error, sceneIndex: index + 1)) }
            let description: String
            let captionStatus: String
            do {
                try APIError.requireModel()
                let session = LanguageModelSession(instructions: "Describe a video frame in two concise sentences. Focus on subjects, setting, layout, and action. OCR text is stored separately; do not list or transcribe long text.")
                let response = try await session.respond(options: GenerationOptions(maximumResponseTokens: 160)) {
                    Attachment(imageURL: candidate.0)
                    "Frame at \(candidate.1)s. Brief OCR hint: \(Self.briefOCRHint(from: ocr)). Describe what is visible."
                }
                description = response.content
                captionStatus = "complete"
            } catch {
                description = ""
                captionStatus = "failed"
                warnings.append(VideoStageFailure(stage: "caption", error: error, sceneIndex: index + 1))
            }
            scenes.append(VideoSceneKeyframe(sceneIndex: index + 1, timestampSec: candidate.1, visualChangeDistance: candidate.2, ocrText: ocr, vlmDescription: description, captionStatus: captionStatus))
        }
        return (scenes, files.count, candidates.count, CFAbsoluteTimeGetCurrent() - start, warnings)
    }
}
