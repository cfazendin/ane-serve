import Foundation
import Network
import FoundationModels
import Vision
import Speech
import AVFoundation

public final class ANEServeServer: @unchecked Sendable {
    static let maximumConnections = 64
    static let maximumMediaJobs = 2
    static let maximumHeaderBytes = 65_536
    static let maximumBodyBytes = 52_428_800
    /// Seconds a client has to send its complete request headers.
    static let headerTimeout: TimeInterval = 30
    /// Seconds a request body may stall before the connection is closed.
    static let bodyIdleTimeout: TimeInterval = 30
    private static let headerDelimiter = Data("\r\n\r\n".utf8)

    public let host: String
    public let port: UInt16
    public let apiKey: String?
    public let pathPolicy: PathPolicy
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.aneserve.http", qos: .userInitiated, attributes: .concurrent)
    private let telemetry: SiliconTelemetrySampler
    private let hardware: HardwareProfile
    private let onRequestLog: (@Sendable (String) -> Void)?
    /// Each video scan or transcription runs several ffmpeg and model passes, so only a few run at once.
    private let mediaJobs = JobLimiter(limit: ANEServeServer.maximumMediaJobs)
    private let chat: ChatEndpoint

    private let statsLock = NSLock()
    private var totalRequestsServed: Int = 0
    private var openConnections = 0

    private func nextRequestNumber() -> Int {
        statsLock.lock()
        defer { statsLock.unlock() }
        totalRequestsServed += 1
        return totalRequestsServed
    }

    private func reserveConnection() -> Bool {
        statsLock.lock()
        defer { statsLock.unlock() }
        guard openConnections < Self.maximumConnections else { return false }
        openConnections += 1
        return true
    }

    private func releaseConnection() {
        statsLock.lock()
        defer { statsLock.unlock() }
        openConnections -= 1
    }

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 8090,
        apiKey: String? = nil,
        pathPolicy: PathPolicy = .disabled,
        telemetry: SiliconTelemetrySampler,
        hardware: HardwareProfile,
        onRequestLog: (@Sendable (String) -> Void)? = nil
    ) {
        self.host = host
        self.port = port
        let normalizedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = (normalizedKey?.isEmpty == false) ? normalizedKey : nil
        self.pathPolicy = pathPolicy
        self.telemetry = telemetry
        self.hardware = hardware
        self.onRequestLog = onRequestLog
        self.chat = ChatEndpoint(pathPolicy: pathPolicy, telemetry: telemetry, hardware: hardware, log: onRequestLog)
    }

    public func start() throws {
        try ServerBinding.validate(host: host, apiKey: apiKey)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "ANEServeServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
        if host != "0.0.0.0" && host != "::" && host != "*" {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }
        // A specific endpoint already carries its port; supplying it again to
        // NWListener produces EINVAL on current Network.framework releases.
        let newListener = try NWListener(using: params, on: params.requiredLocalEndpoint == nil ? nwPort : .any)
        newListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let err):
                self?.onRequestLog?("FATAL: Listener on port \(self?.port ?? 0) failed: \(err)")
                exit(1)
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        newListener.start(queue: queue)
        self.listener = newListener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        guard reserveConnection() else {
            // Over the limit: answer without reading the request, then close.
            connection.start(queue: queue)
            Self.sendResponse(Self.errorResponse(APIError(status: 503, message: "The server has too many open connections. Retry shortly.",
                                                          type: "service_unavailable_error", code: "too_many_connections")), on: connection)
            return
        }
        // A serial queue per connection keeps the reader's state single-threaded.
        let reader = ConnectionReader(connection: connection, queue: DispatchQueue(label: "com.aneserve.connection", target: queue))
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed:
                reader.close()
                connection.cancel()
            case .cancelled:
                reader.close()
                connection.stateUpdateHandler = nil
                self?.releaseConnection()
            default:
                break
            }
        }
        connection.start(queue: reader.queue)
        reader.startTimer(seconds: Self.headerTimeout)
        receiveHead(reader)
    }

    /// Reads the request line and headers, then settles authentication before reading any body.
    private func receiveHead(_ reader: ConnectionReader) {
        reader.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumHeaderBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return reader.connection.cancel() }
            guard !reader.isClosed else { return }
            if let data { reader.buffer.append(data) }
            guard let end = reader.buffer.range(of: Self.headerDelimiter) else {
                if error != nil {
                    reader.connection.cancel()
                } else if isComplete || reader.buffer.count >= Self.maximumHeaderBytes {
                    reader.finish(with: Self.errorResponse(APIError(message: "Invalid or oversized HTTP headers.", code: "invalid_http_request")))
                } else {
                    self.receiveHead(reader)
                }
                return
            }
            let head: HTTPRequestHead
            do {
                let headerData = reader.buffer[reader.buffer.startIndex..<end.lowerBound]
                guard headerData.count <= Self.maximumHeaderBytes, let text = String(data: headerData, encoding: .utf8) else {
                    throw APIError(message: "Invalid or oversized HTTP headers.", code: "invalid_http_request")
                }
                head = try HTTPRequestHead.parse(text)
            } catch {
                reader.finish(with: Self.errorResponse(APIError.from(error)))
                return
            }
            if let response = Self.earlyResponse(for: head, apiKey: self.apiKey) {
                reader.finish(with: response)
                return
            }
            // The body gets its own preallocated buffer, so appending a chunk never copies what came before.
            reader.body = Data(capacity: head.contentLength)
            reader.body.append(reader.buffer[end.upperBound...].prefix(head.contentLength))
            reader.buffer = Data()
            self.receiveBody(reader, head: head)
        }
    }

    private func receiveBody(_ reader: ConnectionReader, head: HTTPRequestHead) {
        let remaining = head.contentLength - reader.body.count
        guard remaining > 0 else { return dispatch(head, reader) }
        reader.startTimer(seconds: Self.bodyIdleTimeout)
        reader.connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 1_048_576)) { [weak self] data, _, isComplete, error in
            guard let self else { return reader.connection.cancel() }
            guard !reader.isClosed else { return }
            if let data { reader.body.append(data) }
            if reader.body.count >= head.contentLength {
                self.dispatch(head, reader)
            } else if error != nil {
                reader.connection.cancel()
            } else if isComplete {
                reader.finish(with: Self.errorResponse(APIError(message: "The HTTP request body is incomplete.", code: "incomplete_body")))
            } else {
                self.receiveBody(reader, head: head)
            }
        }
    }

    private func dispatch(_ head: HTTPRequestHead, _ reader: ConnectionReader) {
        reader.cancelTimer()
        let body = reader.body
        reader.body = Data()
        let connection = reader.connection
        reader.requestTask = Task { await self.routeHTTPRequest(head, body: body, on: connection) }
    }

    static func parseContentLength(from headerString: String) throws -> Int {
        var length: Int?
        let lines = headerString.components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw APIError(message: "Malformed HTTP header.", code: "invalid_http_request") }
            let name = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if name == "transfer-encoding" {
                throw APIError(message: "Transfer-Encoding is unsupported. Send JSON with Content-Length.", code: "unsupported_transfer_encoding")
            }
            if name == "content-length" {
                guard length == nil, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int(value) else {
                    throw APIError(message: "Content-Length must appear once and contain a nonnegative integer.", code: "invalid_content_length")
                }
                length = parsed
            }
        }
        if lines.first?.hasPrefix("POST ") == true && length == nil {
            throw APIError(status: 411, message: "POST requests require Content-Length.", code: "length_required")
        }
        return length ?? 0
    }

    static func sendResponse(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Answers a request without reading its body: browser requests to a server without a key,
    /// CORS preflights, failed authentication, and bodies over the size limit.
    static func earlyResponse(for head: HTTPRequestHead, apiKey: String?) -> Data? {
        if apiKey == nil && head.hasOrigin {
            return errorResponse(APIError(status: 403, message: "Browser-origin requests require an API key configured on the server.", type: "authentication_error", code: "api_key_required"))
        }
        if head.method == "OPTIONS" {
            return httpResponse(status: "200 OK", json: [:])
        }
        if let apiKey, !verifyAPIKey(apiKey, in: head.headerLines) {
            return errorResponse(APIError(status: 401, message: "Invalid or missing API key. Provide Authorization: Bearer <key> or X-API-Key: <key>.", type: "authentication_error", code: "invalid_api_key"))
        }
        if head.contentLength > maximumBodyBytes {
            return errorResponse(APIError(status: 413, message: "Request body exceeds the 50 MB limit.", code: "payload_too_large"))
        }
        return nil
    }

    private func routeHTTPRequest(_ head: HTTPRequestHead, body bodyData: Data, on connection: NWConnection) async {
        let reqNum = nextRequestNumber()
        let responseData: Data

        switch (head.method, head.path) {
        case ("GET", "/v1/models"), ("GET", "/models"):
            responseData = Self.httpResponse(status: "200 OK", json: [
                "object": "list",
                "data": [
                    [
                        "id": "apple-foundation-model-ane",
                        "object": "model",
                        "created": 1735689600,
                        "owned_by": "apple-on-device-ane",
                        "hardware": hardware.aneDescription
                    ]
                ]
            ])

        case ("GET", "/"), ("GET", "/v1/health"), ("GET", "/health"):
            let sample = telemetry.sampleNext()
            let speech = await SpeechAssets.readiness()
            let modelReady = SystemLanguageModel.default.isAvailable
            let json: [String: Any] = [
                "status": "ok",
                "service": "ane-serve",
                "requests_served": reqNum,
                "readiness": ["language_model": ["ready": modelReady, "status": String(describing: SystemLanguageModel.default.availability)],
                              "speech": speech, "ffmpeg": MediaTools.resolve("ffmpeg") != nil, "ffprobe": MediaTools.resolve("ffprobe") != nil],
                "hardware": [
                    "soc": hardware.cpuBrand,
                    "os": hardware.osVersion,
                    "coreai_architecture": hardware.coreAIArchitecture,
                    "ane_cores": hardware.aneCoreCount,
                    "ane_engine": hardware.aneDescription,
                    "gpu": hardware.gpuName,
                    "unified_memory_gb": hardware.unifiedMemoryGB
                ],
                "endpoints": [
                    "GET  /v1/health": "Hardware profile, readiness, and system-wide ANE/CPU/GPU telemetry",
                    "POST /v1/chat/completions": "OpenAI-compatible chat with Apple's on-device model, including image input",
                    "POST /v1/ane/prompt": "Alias of /v1/chat/completions",
                    "POST /v1/vision/analyze": "Vision OCR and classification tags, plus a separate model caption",
                    "POST /v1/audio/transcribe": "On-device en-US speech transcription of audio or video",
                    "POST /v1/video/scan": "Transcript, scene detection, OCR, captions, and a summary in one report"
                ],
                "live_telemetry": TelemetrySample.json(sample)
            ]
            responseData = Self.httpResponse(status: "200 OK", json: json)

        case ("POST", "/v1/chat/completions"), ("POST", "/v1/ane/prompt"):
            await chat.handle(bodyData, number: reqNum, on: connection)
            return

        case ("POST", "/v1/vision/analyze"):
            responseData = await handleVisionAnalyzeRequest(bodyData: bodyData, reqNum: reqNum)

        case ("POST", "/v1/audio/transcribe"):
            responseData = await handleAudioTranscribeRequest(bodyData: bodyData, reqNum: reqNum)

        case ("POST", "/v1/video/scan"):
            responseData = await handleVideoScanRequest(bodyData: bodyData, reqNum: reqNum)

        default:
            responseData = Self.errorResponse(APIError(status: 404, message: "Unknown route \(head.method) \(head.path).", code: "route_not_found"))
        }
        Self.sendResponse(responseData, on: connection)
    }

    // MARK: - Image analysis

    private func handleVisionAnalyzeRequest(bodyData: Data, reqNum: Int) async -> Data {
        let image: ValidatedImage
        let customPrompt: String?
        let detailLevel: String
        let settings: GenerationSettings
        do {
            let object = try RequestJSON.object(bodyData)
            try RequestJSON.validateKeys(object, allowed: ImageInput.fields.union(["prompt", "detail", "temperature", "max_tokens", "max_completion_tokens"]))
            settings = try GenerationSettings(object)
            customPrompt = try RequestJSON.string(object, "prompt")
            if let customPrompt, customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw APIError(message: "'prompt' must not be empty.", param: "prompt")
            }
            detailLevel = try RequestJSON.string(object, "detail") ?? "medium"
            guard ["short", "medium", "detailed"].contains(detailLevel) else {
                throw APIError(message: "'detail' must be 'short', 'medium', or 'detailed'.", param: "detail")
            }
            guard let parsedImage = try ImageInput.fromObject(object, pathPolicy: pathPolicy) else {
                throw APIError(message: "Provide 'image_base64', 'image_path', or a base64 data URL in 'image_url'.", param: "image_base64")
            }
            image = parsedImage
            try APIError.requireModel()
        } catch {
            return Self.errorResponse(APIError.from(error))
        }

        onRequestLog?("[Req #\(reqNum)] Image OCR + Classification + VLM")
        let snapStart = telemetry.takeSnapshot()
        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. Run Vision OCR and scene classification on the validated image.
        var ocrTexts: [String] = []
        var ocrDetails: [[String: Any]] = []
        var classifications: [[String: Any]] = []

        let textReq = VNRecognizeTextRequest { req, _ in
            guard let results = req.results as? [VNRecognizedTextObservation] else { return }
            for obs in results {
                if let top = obs.topCandidates(1).first {
                    ocrTexts.append(top.string)
                    ocrDetails.append([
                        "text": top.string,
                        "confidence": round(Double(top.confidence) * 1000) / 1000,
                        "bbox": [
                            round(Double(obs.boundingBox.origin.x) * 1000) / 1000,
                            round(Double(obs.boundingBox.origin.y) * 1000) / 1000,
                            round(Double(obs.boundingBox.size.width) * 1000) / 1000,
                            round(Double(obs.boundingBox.size.height) * 1000) / 1000
                        ]
                    ])
                }
            }
        }
        textReq.recognitionLevel = .accurate
        textReq.usesLanguageCorrection = true

        let classifyReq = VNClassifyImageRequest { req, _ in
            guard let results = req.results as? [VNClassificationObservation] else { return }
            for obs in results.prefix(8) where obs.confidence >= 0.15 {
                classifications.append([
                    "label": obs.identifier,
                    "confidence": round(Double(obs.confidence) * 1000) / 1000
                ])
            }
        }

        let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
        do {
            try handler.perform([textReq, classifyReq])
        } catch {
            return Self.errorResponse(APIError(message: "Vision could not analyze the image.", param: "image_base64", code: "image_processing_failed"))
        }

        // 2. Caption the image with the on-device model. Pass only a short OCR preview (up to 3 lines /
        // 140 chars) so the caption describes the image instead of repeating its text.
        let vlmDescription: String
        do {
            let attachment = Attachment(image.cgImage)
            let topTags = classifications.prefix(5).compactMap { $0["label"] as? String }.joined(separator: ", ")
            let ocrPreview = VideoIntelligenceScanner.briefOCRHint(from: ocrTexts)

            let lengthInstruction: String
            switch detailLevel {
            case "short":
                lengthInstruction = "Write a concise 1–2 sentence visual caption."
            case "detailed":
                lengthInstruction = "Write a detailed 4–6 sentence visual description."
            default:
                lengthInstruction = "Write a rich, natural 3–4 sentence visual description (1 short paragraph) covering the main subjects, setting, layout, colors, and action."
            }

            let session = LanguageModelSession(
                instructions: """
                You are an expert vision assistant. \
                \(lengthInstruction) \
                You may weave in the main title, brand, or sign name naturally if present, \
                but NEVER transcribe, copy, or list out menus, tables, stats, or long OCR text dumps—the full OCR text is already stored in a separate searchable field.
                """
            )
            let defaultPrompt = """
            Describe this image visually (Vision scene tags: \(topTags.isEmpty ? "none" : topTags); \
            brief OCR preview: \(ocrPreview)). \
            Focus on what the image looks like in natural sentences and do not paste or list out raw OCR lines.
            """
            let promptText = customPrompt ?? defaultPrompt
            let resp = try await session.respond(options: settings.options) {
                attachment
                promptText
            }
            vlmDescription = resp.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return Self.errorResponse(APIError.from(error))
        }

        let elapsed = max(CFAbsoluteTimeGetCurrent() - startTime, 1e-3)
        let metrics = telemetry.json(since: snapStart, host: hardware)
        onRequestLog?("[Req #\(reqNum)] Image analysis complete in \(String(format: "%.2f", elapsed))s")

        return Self.httpResponse(status: "200 OK", json: [
            "id": "ane-vision-\(UUID().uuidString.prefix(8))",
            "elapsed_seconds": round(elapsed * 1000) / 1000,
            "vlm_description": vlmDescription,
            "ocr_line_count": ocrTexts.count,
            "ocr_full_text": ocrTexts.joined(separator: "\n"),
            "ocr_text": ocrTexts,
            "ocr_blocks": ocrDetails,
            "classifications": classifications,
            "ane_telemetry": metrics
        ])
    }

    // MARK: - Transcription

    private func handleAudioTranscribeRequest(bodyData: Data, reqNum: Int) async -> Data {
        do {
            let object = try RequestJSON.object(bodyData)
            try RequestJSON.validateKeys(object, allowed: ["audio_path", "video_path", "audio_base64", "format", "max_duration_sec"])
            let maximum = try RequestJSON.number(object, "max_duration_sec") ?? 600
            guard maximum > 0, maximum <= 3600 else {
                throw APIError(message: "'max_duration_sec' must be greater than 0 and at most 3600.", param: "max_duration_sec")
            }
            let input = try MediaInput(object, paths: ["audio_path", "video_path"], base64: "audio_base64", defaultFormat: "wav", pathPolicy: pathPolicy)
            defer { input.cleanup() }
            return try await mediaJobs.run {
                let metadata = try await MediaTools.inspect(input.url)
                guard metadata.hasAudio else { throw APIError(message: "The media must contain an audio track.", code: "invalid_audio") }
                let duration = min(maximum, metadata.duration)
                try await SpeechAssets.shared.prepare()
                let wav = FileManager.default.temporaryDirectory.appendingPathComponent("ane_pcm_\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: wav) }
                let snapshot = telemetry.takeSnapshot()
                let started = CFAbsoluteTimeGetCurrent()
                _ = try await MediaTools.run("ffmpeg", ["-nostdin", "-y", "-i", input.url.path, "-t", String(duration), "-vn", "-ac", "1", "-ar", "16000", "-f", "wav", wav.path])
                let result = try await SpeechAssets.transcribe(wav)
                let elapsed = max(CFAbsoluteTimeGetCurrent() - started, 0.001)
                let segments: [[String: Any]] = result.segments.map { ["start_sec": $0.startTimeSec, "end_sec": $0.endTimeSec, "text": $0.text] }
                onRequestLog?("[Req #\(reqNum)] Transcription complete in \(String(format: "%.2f", elapsed))s")
                return Self.httpResponse(status: "200 OK", json: [
                    "id": "ane-speech-\(UUID().uuidString.prefix(8))", "audio_duration_seconds": duration,
                    "elapsed_seconds": elapsed, "realtime_speedup_x": duration / elapsed,
                    "text": result.fullText, "segments": segments, "ane_telemetry": telemetry.json(since: snapshot, host: hardware)
                ])
            }
        } catch { return Self.errorResponse(APIError.from(error)) }
    }

    // MARK: - Video analysis

    private func handleVideoScanRequest(bodyData: Data, reqNum: Int) async -> Data {
        do {
            let object = try RequestJSON.object(bodyData)
            try RequestJSON.validateKeys(object, allowed: ["video_path", "video_base64", "format", "max_duration_sec", "frame_interval_sec", "scene_threshold", "max_vlm_scenes"])
            // Validate numbers before loading uploads, logging integer conversions, or starting media tools.
            let options = try VideoScanOptions(object)
            let input = try MediaInput(object, paths: ["video_path"], base64: "video_base64", defaultFormat: "mp4", pathPolicy: pathPolicy)
            defer { input.cleanup() }
            onRequestLog?("[Req #\(reqNum)] Video scan: up to \(options.maxDuration)s, \(options.maxVLMScenes) captions")
            let report = try await mediaJobs.run {
                try await VideoIntelligenceScanner(telemetry: telemetry).scanVideo(
                    at: input.url, maxDurationSeconds: options.maxDuration, frameSampleIntervalSeconds: options.frameInterval,
                    sceneDistanceThreshold: options.sceneThreshold, maxVLMScenes: options.maxVLMScenes)
            }
            let data = try JSONEncoder().encode(report)
            let reportObject = try RequestJSON.object(data)
            return Self.httpResponse(status: "200 OK", json: reportObject)
        } catch { return Self.errorResponse(APIError.from(error)) }
    }

    // MARK: - Helpers

    private static func timingSafeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        var diff = aBytes.count ^ bBytes.count
        let count = min(aBytes.count, bBytes.count)
        for i in 0..<count {
            diff |= Int(aBytes[i] ^ bBytes[i])
        }
        return diff == 0
    }

    private static func verifyAPIKey(_ expectedKey: String, in headerLines: [String]) -> Bool {
        for line in headerLines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if name == "authorization" {
                let token = value.hasPrefix("Bearer ")
                    ? String(value.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
                    : value
                if timingSafeEquals(token, expectedKey) { return true }
            } else if name == "x-api-key" && timingSafeEquals(value, expectedKey) {
                return true
            }
        }
        return false
    }

    static func errorResponse(_ error: APIError) -> Data {
        let reasons = [400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 408: "Request Timeout", 411: "Length Required",
                       413: "Payload Too Large", 429: "Too Many Requests", 500: "Internal Server Error",
                       502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout"]
        return httpResponse(status: "\(error.status) \(reasons[error.status] ?? "Error")", json: error.body)
    }

    static func httpResponse(status: String, json: [String: Any]) -> Data {
        // Legacy media validation errors use the same envelope as chat and images.
        var payload = json
        if let message = json["error"] as? String {
            let code = Int(status.prefix(3)) ?? 500
            payload = APIError(status: code, message: message,
                               type: code >= 500 ? "server_error" : "invalid_request_error",
                               code: code >= 500 ? "internal_error" : "invalid_request").body
        }
        let bodyData = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: application/json; charset=utf-8\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: Content-Type, Authorization, X-API-Key\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(bodyData)
        return packet
    }
}
