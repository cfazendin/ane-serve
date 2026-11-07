import Foundation
import FoundationModels
import Network

/// The model names a chat endpoint answers to. A server that reuses `ChatEndpoint` can keep its own
/// names. Requests may also leave the model out.
struct ChatModels: Sendable {
    /// The name every response reports.
    let responseID: String
    /// The names a request may use.
    let accepted: Set<String>

    static let aneServe = ChatModels(responseID: ChatRequest.modelID, accepted: [ChatRequest.modelID])
}

/// Serves one chat completion on a connection: it validates the request, runs Apple's on-device model,
/// writes a JSON reply or an event stream, and closes the connection. Other Swift servers built from
/// these sources hand their chat requests to it, so it holds no `ANEServeServer` state.
struct ChatEndpoint: Sendable {
    let models: ChatModels
    let pathPolicy: PathPolicy
    let telemetry: SiliconTelemetrySampler
    let hardware: HardwareProfile
    let log: (@Sendable (String) -> Void)?

    init(models: ChatModels = .aneServe, pathPolicy: PathPolicy, telemetry: SiliconTelemetrySampler,
         hardware: HardwareProfile, log: (@Sendable (String) -> Void)? = nil) {
        self.models = models
        self.pathPolicy = pathPolicy
        self.telemetry = telemetry
        self.hardware = hardware
        self.log = log
    }

    /// Returns whether a complete reply was sent.
    @discardableResult
    func handle(_ body: Data, number: Int, on connection: NWConnection) async -> Bool {
        do {
            let request = try ChatRequest.parse(body, pathPolicy: pathPolicy, models: models)
            try APIError.requireModel()
            let (session, prompt) = request.makeSession(defaultInstructions: "You are a concise, accurate assistant running on \(hardware.cpuBrand).")
            log?("[Req #\(number)] Chat: \(request.turns.count) turns, stream=\(request.stream)")
            if request.stream {
                return await stream(request, session: session, prompt: prompt, on: connection, number: number)
            }
            let snapStart = telemetry.takeSnapshot()
            let startTime = CFAbsoluteTimeGetCurrent()
            let response = try await session.respond(to: prompt, options: request.settings.options)
            let elapsed = max(CFAbsoluteTimeGetCurrent() - startTime, 1e-3)
            let json = ChatResponse(model: models.responseID).completion(
                text: response.content,
                finishReason: ChatResponse.finishReason(outputTokens: response.usage.output.totalTokenCount, maximum: request.settings.maxTokens),
                usage: ChatResponse.usage(response.usage, elapsed: elapsed), telemetry: telemetry.json(since: snapStart, host: hardware)
            )
            log?("[Req #\(number)] Chat complete in \(String(format: "%.2f", elapsed))s")
            ANEServeServer.sendResponse(ANEServeServer.httpResponse(status: "200 OK", json: json), on: connection)
            return true
        } catch {
            log?("[Req #\(number)] Chat failed: \(error.localizedDescription)")
            ANEServeServer.sendResponse(ANEServeServer.errorResponse(APIError.from(error)), on: connection)
            return false
        }
    }

    private func stream(_ request: ChatRequest, session: LanguageModelSession, prompt: Prompt, on connection: NWConnection, number: Int) async -> Bool {
        let writer = HTTPStreamWriter(connection: connection)
        let response = ChatResponse(model: models.responseID)
        let snapStart = telemetry.takeSnapshot()
        let startTime = CFAbsoluteTimeGetCurrent()
        var started = false
        defer { connection.cancel() }
        do {
            var iterator = session.streamResponse(to: prompt, options: request.settings.options).makeAsyncIterator()
            // Keep early model failures as ordinary HTTP errors, before committing SSE headers.
            var snapshot = try await iterator.next()
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nX-Accel-Buffering: no\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            try await writer.send(Data(headers.utf8))
            started = true
            try await writer.event(response.chunk(delta: ["role": "assistant", "content": ""], includeUsage: request.includeUsage))
            var text = StreamingText()
            var usage = session.usage
            while let current = snapshot {
                try Task.checkCancellation()
                let delta = try text.append(snapshot: current.content)
                usage = current.usage
                if !delta.isEmpty {
                    try await writer.event(response.chunk(delta: ["content": delta], includeUsage: request.includeUsage))
                }
                snapshot = try await iterator.next()
            }
            // The session includes final accounting even if the last snapshot had no text.
            usage = session.usage
            let elapsed = max(CFAbsoluteTimeGetCurrent() - startTime, 0.001)
            var final = response.chunk(delta: [:], finishReason: ChatResponse.finishReason(outputTokens: usage.output.totalTokenCount, maximum: request.settings.maxTokens), includeUsage: request.includeUsage)
            final["ane_telemetry"] = telemetry.json(since: snapStart, host: hardware)
            try await writer.event(final)
            if request.includeUsage { try await writer.event(response.usageChunk(ChatResponse.usage(usage, elapsed: elapsed))) }
            try await writer.send(Data("data: [DONE]\n\n".utf8))
            try await writer.finish()
            log?("[Req #\(number)] Stream complete in \(String(format: "%.2f", elapsed))s")
            return true
        } catch {
            if Task.isCancelled || error is CancellationError || error is NWError { return false }
            log?("[Req #\(number)] Stream failed: \(error.localizedDescription)")
            let apiError = APIError.from(error)
            if started {
                try? await writer.event(apiError.body)
                try? await writer.send(Data("data: [DONE]\n\n".utf8))
            } else {
                try? await writer.send(ANEServeServer.errorResponse(apiError))
            }
            try? await writer.finish()
            return false
        }
    }
}
