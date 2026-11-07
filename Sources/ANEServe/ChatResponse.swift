import Foundation
import FoundationModels
import Network

struct ChatResponse {
    var model = ChatRequest.modelID
    let id = "chatcmpl-\(UUID().uuidString)"
    let created = Int(Date().timeIntervalSince1970)

    func completion(text: String, finishReason: String, usage: [String: Any], telemetry: [String: Any]) -> [String: Any] {
        [
            "id": id, "object": "chat.completion", "created": created, "model": model,
            "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": finishReason]],
            "usage": usage, "ane_telemetry": telemetry
        ]
    }

    func chunk(delta: [String: Any], finishReason: String? = nil, includeUsage: Bool) -> [String: Any] {
        var chunk: [String: Any] = [
            "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
            "choices": [["index": 0, "delta": delta, "finish_reason": finishReason as Any? ?? NSNull()]]
        ]
        if includeUsage { chunk["usage"] = NSNull() }
        return chunk
    }

    func usageChunk(_ usage: [String: Any]) -> [String: Any] {
        ["id": id, "object": "chat.completion.chunk", "created": created, "model": model,
         "choices": [], "usage": usage]
    }

    static func usage(_ usage: LanguageModelSession.Usage, elapsed: Double) -> [String: Any] {
        [
            "prompt_tokens": usage.input.totalTokenCount,
            "completion_tokens": usage.output.totalTokenCount,
            "total_tokens": usage.totalTokenCount,
            "prompt_tokens_details": ["cached_tokens": usage.input.cachedTokenCount],
            "completion_tokens_details": ["reasoning_tokens": usage.output.reasoningTokenCount],
            "elapsed_seconds": (elapsed * 1000).rounded() / 1000,
            "tokens_per_second": (Double(usage.output.totalTokenCount) / max(elapsed, 0.001) * 10).rounded() / 10
        ]
    }

    static func finishReason(outputTokens: Int, maximum: Int?) -> String {
        if let maximum, outputTokens >= maximum { return "length" }
        return "stop"
    }

    static func event(_ object: [String: Any]) throws -> Data {
        var frame = Data("data: ".utf8)
        frame.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        frame.append(Data("\n\n".utf8))
        return frame
    }
}

struct StreamingText {
    private(set) var text = ""

    mutating func append(snapshot: String) throws -> String {
        // Compare UTF-8 bytes, not grapheme counts: a new token can extend the
        // preceding grapheme (combining marks, emoji skin tones, and ZWJ sequences).
        let old = Array(text.utf8)
        let next = Array(snapshot.utf8)
        guard next.starts(with: old) else {
            throw APIError(status: 502, message: "The model revised text that was already streamed.", type: "server_error", code: "invalid_model_stream")
        }
        text = snapshot
        return String(decoding: next.dropFirst(old.count), as: UTF8.self)
    }
}

struct HTTPStreamWriter {
    let connection: NWConnection

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func event(_ object: [String: Any]) async throws {
        try await send(ChatResponse.event(object))
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
