import Foundation
import FoundationModels

let usage = """
Usage:
  ane-serve [--host 127.0.0.1] [--port 8090] [--api-key KEY] [--media-root DIR]
  ane-serve --scan-video /absolute/path/video.mp4 [max_seconds] [max_scenes]
  ane-serve --prepare-speech

LAN bindings require ANE_API_KEY or --api-key. HOST, PORT, and ANE_MEDIA_ROOT are also supported.
Request fields that name files on this Mac (video_path, audio_path, image_path) are disabled
unless --media-root names the folder they may read.
Speech assets are prepared automatically on the first transcription request.
"""

@MainActor
func runVideoScanMode(videoPath: String, maxDuration: Double, maxVLMScenes: Int) async -> Int32 {
    do {
        _ = try VideoScanOptions(maxDuration: maxDuration, maxVLMScenes: maxVLMScenes)
        let hardware = HardwareProfile.detect()
        print("ANE-Serve video analysis — \(hardware.cpuBrand) | \(hardware.aneDescription)")
        let report = try await VideoIntelligenceScanner(telemetry: SiliconTelemetrySampler()).scanVideo(
            at: URL(fileURLWithPath: videoPath), maxDurationSeconds: maxDuration, maxVLMScenes: maxVLMScenes
        ) { print("  \($0)"); fflush(stdout) }
        print(String(format: "Analyzed %.2fs in %.2fs (%.2fx real time). Status: %@", report.analyzedDurationSec, report.totalProcessingTimeSec, report.realtimeSpeedupFactor, report.status))
        func metric(_ value: Double?, unit: String) -> String { value.map { String(format: "%.2f %@", $0, unit) } ?? "unavailable" }
        print("ANE fabric: \(metric(report.aneAverageFabricBandwidthGBps, unit: "GB/s")); GPU: \(metric(report.gpuAveragePowerWatts, unit: "W")); CPU: \(metric(report.cpuAveragePowerWatts, unit: "W"))")
        print(report.executiveSummary)
        for warning in report.warnings { print("Stage warning [\(warning.stage)/\(warning.code)]: \(warning.message)") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = URL(fileURLWithPath: videoPath + ".ane_storyboard.json")
        try encoder.encode(report).write(to: output)
        print("JSON report: \(output.path)")
        return report.status == "complete" ? 0 : 2
    } catch {
        fputs("Video scan failed: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

let args = CommandLine.arguments
if args.contains("--help") || args.contains("-h") {
    print(usage)
} else if args.contains("--prepare-speech") {
    Task {
        do {
            print("Preparing English (United States) speech assets...")
            try await SpeechAssets.shared.prepare()
            print("Speech assets are installed and ready.")
            exit(0)
        } catch {
            fputs("Speech setup failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    RunLoop.main.run()
} else if let scanIndex = args.firstIndex(of: "--scan-video") {
    guard scanIndex + 1 < args.count else { fputs(usage + "\n", stderr); exit(1) }
    let duration = scanIndex + 2 < args.count ? Double(args[scanIndex + 2]) : 180
    let scenes = scanIndex + 3 < args.count ? Int(args[scanIndex + 3]) : 8
    guard let duration, let scenes else { fputs("Duration and scene count must be numeric.\n", stderr); exit(1) }
    Task { @MainActor in
        exit(await runVideoScanMode(videoPath: args[scanIndex + 1], maxDuration: duration, maxVLMScenes: scenes))
    }
    RunLoop.main.run()
} else {
    var host = ProcessInfo.processInfo.environment["HOST"] ?? "127.0.0.1"
    var portString = ProcessInfo.processInfo.environment["PORT"] ?? "8090"
    var key = ProcessInfo.processInfo.environment["ANE_API_KEY"]
    var mediaRoot = ProcessInfo.processInfo.environment["ANE_MEDIA_ROOT"]
    var index = 1
    while index < args.count {
        let flag = args[index]
        guard ["--host", "--port", "--serve", "--api-key", "--media-root"].contains(flag), index + 1 < args.count else {
            fputs("Unknown option or missing value: \(flag)\n\(usage)\n", stderr)
            exit(1)
        }
        switch flag {
        case "--host": host = args[index + 1]
        case "--port", "--serve": portString = args[index + 1]
        case "--media-root": mediaRoot = args[index + 1]
        default: key = args[index + 1]
        }
        index += 2
    }
    guard let port = UInt16(portString), port > 0 else { fputs("Port must be an integer from 1 to 65535.\n", stderr); exit(1) }
    let pathPolicy: PathPolicy
    do {
        try ServerBinding.validate(host: host, apiKey: key)
        if let mediaRoot, !mediaRoot.isEmpty { pathPolicy = try PathPolicy.mediaRoot(mediaRoot) } else { pathPolicy = .disabled }
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    let hardware = HardwareProfile.detect()
    let server = ANEServeServer(host: host, port: port, apiKey: key, pathPolicy: pathPolicy, telemetry: SiliconTelemetrySampler(), hardware: hardware) { message in
        print("[\(ISO8601DateFormatter().string(from: Date()))] \(message)")
        fflush(stdout)
    }
    do {
        try server.start()
        print("ANE-Serve — \(hardware.cpuBrand) | \(hardware.aneDescription)")
        print("Listening on \(host):\(port). Authentication: \(server.apiKey == nil ? "disabled (localhost only)" : "enabled").")
        print("Server-side file paths: \(pathPolicy.root.map { "limited to \($0)" } ?? "disabled (upload files as base64)").")
        print("GET /v1/health reports model, speech-asset, media-tool, and telemetry readiness.")
        fflush(stdout)
        RunLoop.main.run()
    } catch {
        fputs("Could not start server: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
