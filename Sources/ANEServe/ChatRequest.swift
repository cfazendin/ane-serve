import Foundation
import FoundationModels

enum ChatPart {
    case text(String)
    case image(ValidatedImage)

    var segment: Transcript.Segment {
        switch self {
        case .text(let text): return .text(.init(content: text))
        case .image(let image): return .attachment(.init(content: .image(.init(image.cgImage))))
        }
    }

    var prompt: Prompt {
        switch self {
        case .text(let text): return Prompt(text)
        case .image(let image): return Prompt(Attachment(image.cgImage))
        }
    }
}

struct ChatTurn {
    let role: String
    var parts: [ChatPart]
}

struct ChatRequest {
    static let modelID = "apple-foundation-model-ane"
    let instructions: [String]
    let turns: [ChatTurn]
    let settings: GenerationSettings
    let stream: Bool
    let includeUsage: Bool

    static func parse(_ data: Data, pathPolicy: PathPolicy = .disabled, models: ChatModels = .aneServe) throws -> ChatRequest {
        let object = try RequestJSON.object(data)
        let allowed: Set<String> = [
            "model", "messages", "prompt", "system", "stream", "stream_options",
            "temperature", "max_tokens", "max_completion_tokens", "image_base64", "image_path", "image_url",
            "n", "stop", "tools", "tool_choice", "response_format", "user", "metadata",
            "top_p", "presence_penalty", "frequency_penalty"
        ]
        try RequestJSON.validateKeys(object, allowed: allowed)
        if let model = try RequestJSON.string(object, "model"), !models.accepted.contains(model) {
            throw APIError(status: 404, message: "Unknown model. Use '\(models.responseID)'.", param: "model", code: "model_not_found")
        }
        let settings = try GenerationSettings(object)
        let stream = try RequestJSON.bool(object, "stream") ?? false
        var includeUsage = false
        if let options = RequestJSON.value(object, "stream_options") {
            guard stream, let options = options as? [String: Any] else {
                throw APIError(message: "'stream_options' must be an object used with 'stream': true.", param: "stream_options")
            }
            try RequestJSON.validateKeys(options, allowed: ["include_usage"])
            includeUsage = try RequestJSON.bool(options, "include_usage", param: "stream_options.include_usage") ?? false
        }
        if let n = try RequestJSON.integer(object, "n"), n != 1 { throw APIError.unsupported("n") }
        // Many OpenAI clients always send these; only their neutral values are accepted.
        for (key, neutral) in [("top_p", 1.0), ("presence_penalty", 0.0), ("frequency_penalty", 0.0)] {
            if let value = try RequestJSON.number(object, key), value != neutral { throw APIError.unsupported(key) }
        }
        if let stop = RequestJSON.value(object, "stop") {
            guard let stop = stop as? [Any], stop.isEmpty else { throw APIError.unsupported("stop") }
        }
        if let tools = RequestJSON.value(object, "tools") {
            guard let tools = tools as? [Any], tools.isEmpty else { throw APIError.unsupported("tools") }
        }
        // With no tools to choose from, "auto" can't call one either.
        if let choice = RequestJSON.value(object, "tool_choice"), !["none", "auto"].contains(choice as? String ?? "") {
            throw APIError.unsupported("tool_choice")
        }
        if let format = RequestJSON.value(object, "response_format") {
            guard let format = format as? [String: Any], format.count == 1, format["type"] as? String == "text" else {
                throw APIError.unsupported("response_format")
            }
        }

        var instructions: [String] = []
        var turns: [ChatTurn] = []
        var imageCount = 0
        if let system = try RequestJSON.string(object, "system") { instructions.append(system) }
        if let messages = RequestJSON.value(object, "messages") {
            guard RequestJSON.value(object, "prompt") == nil,
                  let messages = messages as? [[String: Any]], !messages.isEmpty else {
                throw APIError(message: "Provide a nonempty 'messages' array or a 'prompt', not both.", param: "messages")
            }
            for (index, message) in messages.enumerated() {
                let param = "messages[\(index)]"
                for key in ["tool_calls", "function_call", "tool_call_id"] where RequestJSON.value(message, key) != nil {
                    throw APIError.unsupported(param + "." + key)
                }
                guard let role = message["role"] as? String,
                      ["system", "developer", "user", "assistant"].contains(role) else {
                    throw APIError(message: "Role must be 'system', 'developer', 'user', or 'assistant'. Tool messages are not supported.", param: param + ".role")
                }
                let parts = try parseContent(message["content"], role: role, param: param + ".content", imageCount: &imageCount)
                if role == "system" || role == "developer" {
                    guard turns.isEmpty else {
                        throw APIError(message: "System and developer instructions must precede user/assistant messages.", param: param + ".role")
                    }
                    instructions.append(parts.compactMap { part in if case .text(let text) = part { return text }; return nil }.joined(separator: "\n"))
                } else {
                    if turns.last?.role == role {
                        // Consecutive messages retain their role and content order within one native turn.
                        turns[turns.count - 1].parts.append(.text("\n"))
                        turns[turns.count - 1].parts.append(contentsOf: parts)
                    } else {
                        turns.append(ChatTurn(role: role, parts: parts))
                    }
                }
            }
        } else if let prompt = try RequestJSON.string(object, "prompt"), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            turns = [ChatTurn(role: "user", parts: [.text(prompt)])]
        } else {
            throw APIError(message: "Provide a nonempty 'messages' array or 'prompt'.", param: "messages")
        }
        guard turns.first?.role == "user", turns.last?.role == "user" else {
            throw APIError(message: "The conversation must start and end with a user turn.", param: "messages")
        }
        if imageCount == ImageInput.maximumImages && ImageInput.fields.contains(where: { RequestJSON.value(object, $0) != nil }) {
            throw APIError(message: "A request can contain at most \(ImageInput.maximumImages) images across all turns.", param: "messages", code: "too_many_images")
        }
        if let image = try ImageInput.fromObject(object, pathPolicy: pathPolicy) {
            imageCount += 1
            turns[turns.count - 1].parts.append(.image(image))
        }
        guard imageCount <= ImageInput.maximumImages else {
            throw APIError(message: "A request can contain at most \(ImageInput.maximumImages) images across all turns.", param: "messages", code: "too_many_images")
        }
        return ChatRequest(instructions: instructions, turns: turns, settings: settings, stream: stream, includeUsage: includeUsage)
    }

    private static func parseContent(_ value: Any?, role: String, param: String, imageCount: inout Int) throws -> [ChatPart] {
        if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.text(text)]
        }
        guard let content = value as? [[String: Any]], !content.isEmpty else {
            throw APIError(message: "Content must be nonempty text or a nonempty array of text/image parts.", param: param)
        }
        var parts: [ChatPart] = []
        for (index, part) in content.enumerated() {
            let field = "\(param)[\(index)]"
            switch part["type"] as? String {
            case "text":
                guard let text = part["text"] as? String else {
                    throw APIError(message: "Text parts must contain a 'text' string.", param: field + ".text")
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(text)) }
            case "image_url":
                guard role == "user" else {
                    throw APIError(message: "Images are supported only in user messages.", param: field)
                }
                guard let reference = part["image_url"] else {
                    throw APIError(message: "Image parts must contain 'image_url'.", param: field + ".image_url")
                }
                imageCount += 1
                guard imageCount <= ImageInput.maximumImages else {
                    throw APIError(message: "A request can contain at most \(ImageInput.maximumImages) images.", param: field, code: "too_many_images")
                }
                parts.append(.image(try ImageInput.fromURLValue(reference, param: field + ".image_url")))
            default:
                throw APIError(message: "Content parts must have type 'text' or 'image_url'.", param: field + ".type", code: "unsupported_content_type")
            }
        }
        guard !parts.isEmpty else { throw APIError(message: "Content must not be empty.", param: param) }
        return parts
    }

    func makeTranscript(defaultInstructions: String) -> Transcript {
        let instructionText = instructions.isEmpty ? defaultInstructions : instructions.joined(separator: "\n\n")
        var entries: [Transcript.Entry] = [
            .instructions(.init(segments: [.text(.init(content: instructionText))], toolDefinitions: []))
        ]
        for turn in turns.dropLast() {
            let segments = turn.parts.map(\.segment)
            if turn.role == "user" {
                entries.append(.prompt(.init(segments: segments)))
            } else {
                entries.append(.response(.init(assetIDs: [], segments: segments)))
            }
        }
        return Transcript(entries: entries)
    }

    func makeSession(defaultInstructions: String) -> (LanguageModelSession, Prompt) {
        let session = LanguageModelSession(model: SystemLanguageModel.default, transcript: makeTranscript(defaultInstructions: defaultInstructions))
        return (session, Prompt(turns.last!.parts.map(\.prompt)))
    }
}
