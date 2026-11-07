import XCTest
@testable import ANEServe

final class ReleaseTests: XCTestCase {
    func testLANRequiresAKey() throws {
        for host in ["127.0.0.1", "::1", "localhost"] { XCTAssertNoThrow(try ServerBinding.validate(host: host, apiKey: nil)) }
        for host in ["0.0.0.0", "::", "*", "192.168.1.50"] {
            XCTAssertThrowsError(try ServerBinding.validate(host: host, apiKey: nil))
            XCTAssertThrowsError(try ServerBinding.validate(host: host, apiKey: "  "))
            XCTAssertNoThrow(try ServerBinding.validate(host: host, apiKey: "test-key"))
        }
    }

    func testVideoNumbersCannotReachUnsafeConversionsOrUnboundedSampling() throws {
        for invalid in [
            ["max_duration_sec": 1e100], ["max_duration_sec": -1], ["max_duration_sec": true],
            ["max_duration_sec": "60"], ["frame_interval_sec": 0], ["frame_interval_sec": 0.01],
            ["scene_threshold": -1], ["scene_threshold": 1e100], ["max_vlm_scenes": 1.5], ["max_vlm_scenes": 33],
            ["max_duration_sec": 3600, "frame_interval_sec": 0.25]
        ] as [[String: Any]] {
            XCTAssertThrowsError(try VideoScanOptions(invalid))
        }
        let options = try VideoScanOptions(["max_duration_sec": 60, "frame_interval_sec": 0.5, "max_vlm_scenes": 0])
        XCTAssertEqual(options.maxDuration, 60)
        XCTAssertEqual(options.maxVLMScenes, 0)
        func upload(_ format: String) throws -> MediaInput {
            try MediaInput(["video_base64": "AA==", "format": format], paths: ["video_path"], base64: "video_base64", defaultFormat: "mp4", pathPolicy: .disabled)
        }
        // Playlists and text formats can make ffmpeg read other files, so only media extensions are written.
        for format in ["../mp4", "m3u8", "m3u", "ffconcat", "asc", "txt", ""] {
            XCTAssertThrowsError(try upload(format), format)
        }
        let accepted = try upload("MP4")
        defer { accepted.cleanup() }
        XCTAssertEqual(accepted.url.pathExtension, "mp4")
    }

    func testPathFieldsStayInsideTheMediaRoot() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("ane_root_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let inside = root.appendingPathComponent("clip.mp4")
        try Data([0]).write(to: inside)
        let outside = fileManager.temporaryDirectory.appendingPathComponent("ane_outside_\(UUID().uuidString).mp4")
        try Data([0]).write(to: outside)
        defer { try? fileManager.removeItem(at: outside) }
        let link = root.appendingPathComponent("escape.mp4")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)

        func code(_ policy: PathPolicy, _ path: String) -> String? {
            do { _ = try policy.file(path, param: "video_path"); return nil }
            catch { return (error as? APIError)?.code ?? "\(error)" }
        }
        XCTAssertEqual(code(.disabled, inside.path), "path_inputs_disabled")
        let policy = try PathPolicy.mediaRoot(root.path)
        XCTAssertNil(code(policy, inside.path))
        XCTAssertNil(code(policy, root.path + "/../" + root.lastPathComponent + "/clip.mp4"))
        for path in [outside.path, link.path, root.path + "/../" + outside.lastPathComponent, root.path + "/missing.mp4", root.path, "clip.mp4"] {
            XCTAssertEqual(code(policy, path), "invalid_path", path)
        }
        XCTAssertThrowsError(try PathPolicy.mediaRoot(inside.path), "A file is not a media root")
        let media = try MediaInput(["video_path": inside.path], paths: ["video_path"], base64: "video_base64", defaultFormat: "mp4", pathPolicy: policy)
        XCTAssertEqual(media.url.path, try XCTUnwrap(policy.root) + "/clip.mp4")
    }

    func testRejectedRequestsAreAnsweredBeforeTheirBody() throws {
        func status(_ text: String, key: String?) throws -> String? {
            try ANEServeServer.earlyResponse(for: HTTPRequestHead.parse(text), apiKey: key).map { String(decoding: $0.prefix(12), as: UTF8.self) }
        }
        let upload = "POST /v1/video/scan?verbose=1 HTTP/1.1\r\nContent-Length: 60000000"
        let head = try HTTPRequestHead.parse(upload)
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.path, "/v1/video/scan")
        XCTAssertEqual(head.contentLength, 60_000_000)
        XCTAssertEqual(try status(upload, key: "k"), "HTTP/1.1 401")
        XCTAssertEqual(try status(upload + "\r\nAuthorization: Bearer k", key: "k"), "HTTP/1.1 413")
        XCTAssertEqual(try status(upload + "\r\nOrigin: https://example.com", key: nil), "HTTP/1.1 403")
        XCTAssertEqual(try status("OPTIONS /v1/video/scan HTTP/1.1\r\nOrigin: https://example.com", key: "k"), "HTTP/1.1 200")
        XCTAssertNil(try status("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 2\r\nX-API-Key: k", key: "k"))
        XCTAssertNil(try status("GET /v1/health HTTP/1.1\r\nHost: localhost", key: nil))
        XCTAssertThrowsError(try HTTPRequestHead.parse("GET /\r\nHost: localhost"))
    }

    func testPowerUsesUnitsNotMagnitude() throws {
        XCTAssertEqual(try XCTUnwrap(SiliconTelemetrySampler.wattsFromEnergy(value: 999_999, unit: "mJ", duration: 1)), 999.999, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(SiliconTelemetrySampler.wattsFromEnergy(value: 1_000_001, unit: "mJ", duration: 1)), 1000.001, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(SiliconTelemetrySampler.wattsFromEnergy(value: 1_000_000, unit: "nJ", duration: 2)), 0.0005, accuracy: 0.0000001)
        XCTAssertEqual(SiliconTelemetrySampler.wattsFromEnergy(value: 0, unit: "uJ", duration: 1), 0)
        XCTAssertNil(SiliconTelemetrySampler.wattsFromEnergy(value: 1_000_000, unit: "events", duration: 1))
        XCTAssertNil(SiliconTelemetrySampler.wattsFromEnergy(value: -1, unit: "J", duration: 1))
    }

    func testUnavailableTelemetryIsDistinctFromMeasuredZero() throws {
        let absent = TelemetrySample.json(nil)
        XCTAssertEqual(absent["status"] as? String, "unavailable")
        XCTAssertTrue(absent["gpu_power_watts"] is NSNull)
        var measured = TelemetrySample(timestamp: Date(), durationSeconds: 1)
        measured.gpuPowerWatts = 0
        let partial = TelemetrySample.json(measured)
        XCTAssertEqual(partial["status"] as? String, "partial")
        XCTAssertEqual(partial["gpu_power_watts"] as? Double, 0)
        XCTAssertTrue(partial["cpu_power_watts"] is NSNull)
        XCTAssertEqual(SiliconTelemetrySampler.histogram([("0 GB/s", 10)], unit: "GB/s")?.average, 0)
        XCTAssertNil(SiliconTelemetrySampler.histogram([("unknown", 10)], unit: "GB/s"))
        XCTAssertNil(SiliconTelemetrySampler.histogram([("1 W", 0)], unit: "W"))
    }
}
