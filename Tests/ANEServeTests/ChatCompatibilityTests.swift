import XCTest
import FoundationModels
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ANEServe

final class ChatCompatibilityTests: XCTestCase {
    private func parse(_ object: [String: Any]) throws -> ChatRequest {
        try ChatRequest.parse(JSONSerialization.data(withJSONObject: object))
    }

    private func assertInvalid(_ object: [String: Any], param: String? = nil, code: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(object), file: file, line: line) { error in
            guard let error = error as? APIError else { return XCTFail("Expected APIError, got \(error)", file: file, line: line) }
            if let param { XCTAssertEqual(error.param, param, file: file, line: line) }
            if let code { XCTAssertEqual(error.code, code, file: file, line: line) }
        }
    }

    func testConversationUsesNativeRolesAndKeepsInstructionOrder() throws {
        let request = try parse([
            "messages": [
                ["role": "system", "content": "Be concise."],
                ["role": "developer", "content": "Use English."],
                ["role": "user", "content": "Remember the color blue."],
                ["role": "assistant", "content": "I will remember blue."],
                ["role": "user", "content": "Which color?"],
                ["role": "user", "content": "Answer in one word."]
            ]
        ])
        XCTAssertEqual(request.turns.map(\.role), ["user", "assistant", "user"])
        let transcript = request.makeTranscript(defaultInstructions: "unused default")
        XCTAssertEqual(transcript.count, 3)
        guard case .instructions(let instructions) = transcript[0],
              case .prompt(let user) = transcript[1],
              case .response(let assistant) = transcript[2],
              case .text(let instructionText) = instructions.segments[0],
              case .text(let userText) = user.segments[0],
              case .text(let assistantText) = assistant.segments[0] else { return XCTFail("Roles were not preserved") }
        XCTAssertEqual(instructionText.content, "Be concise.\n\nUse English.")
        XCTAssertEqual(userText.content, "Remember the color blue.")
        XCTAssertEqual(assistantText.content, "I will remember blue.")
        XCTAssertEqual(request.turns.last?.parts.count, 3)
        assertInvalid(["messages": [["role": "user", "content": "Hello"], ["role": "system", "content": "Later"]]], param: "messages[1].role")
        assertInvalid(["messages": [["role": "tool", "content": "result"]]], param: "messages[0].role")
        assertInvalid(["messages": [["role": "assistant", "content": "prefill"]]], param: "messages")
        assertInvalid(["prompt": "Hello", "messages": [["role": "user", "content": "Hello"]]], param: "messages")
    }

    func testGenerationAndStreamSettingsAreStrictlyTyped() throws {
        let request = try parse(["prompt": "Hello", "temperature": 0, "max_tokens": 12, "stream": true, "stream_options": ["include_usage": true]])
        XCTAssertEqual(request.settings.options.maximumResponseTokens, 12)
        XCTAssertEqual(request.settings.options.samplingMode, .greedy)
        XCTAssertTrue(request.stream)
        XCTAssertTrue(request.includeUsage)
        XCTAssertNil(try parse(["prompt": "Hello"]).settings.maxTokens)
        XCTAssertEqual(try parse(["prompt": "Hello", "max_completion_tokens": 25]).settings.maxTokens, 25)
        for value: Any in [true, 0, -1, 1.5, "12", 1e100] {
            assertInvalid(["prompt": "Hello", "max_tokens": value], param: "max_tokens")
        }
        for value: Any in [true, -0.1, 2.1, "0.5"] {
            assertInvalid(["prompt": "Hello", "temperature": value], param: "temperature")
        }
        for value: Any in [1, 0, "true"] { assertInvalid(["prompt": "Hello", "stream": value], param: "stream") }
        assertInvalid(["prompt": "Hello", "max_tokens": 10, "max_completion_tokens": 11], param: "max_completion_tokens")
        assertInvalid(["prompt": "Hello", "stream_options": ["include_usage": true]], param: "stream_options")
        assertInvalid(["prompt": "Hello", "stream": true, "stream_options": ["include_usage": 1]], param: "stream_options.include_usage")
        assertInvalid(["prompt": "Hello", "top_p": 0.8], param: "top_p", code: "unsupported_parameter")
        XCTAssertNoThrow(try parse(["prompt": "Hello", "top_p": 1, "presence_penalty": 0, "frequency_penalty": 0]))
        XCTAssertNoThrow(try parse(["prompt": "Hello", "stop": [], "tools": [], "tool_choice": "auto"]))
        assertInvalid(["prompt": "Hello", "stop": ["END"]], param: "stop", code: "unsupported_parameter")
        assertInvalid(["prompt": "Hello", "tool_choice": "required"], param: "tool_choice", code: "unsupported_parameter")
        assertInvalid(["prompt": "Hello", "presence_penalty": 0.5], param: "presence_penalty", code: "unsupported_parameter")
        assertInvalid(["prompt": "Hello", "response_format": ["type": "json_object"]], param: "response_format", code: "unsupported_parameter")
        assertInvalid(["prompt": "Hello", "model": "unknown"], param: "model", code: "model_not_found")
        // A server reusing ChatEndpoint answers to its own model names.
        let custom = ChatModels(responseID: "custom-model", accepted: ["custom-model", "custom-alias"])
        XCTAssertNoThrow(try ChatRequest.parse(JSONSerialization.data(withJSONObject: ["prompt": "Hello", "model": "custom-alias"]), models: custom))
        XCTAssertThrowsError(try ChatRequest.parse(JSONSerialization.data(withJSONObject: ["prompt": "Hello", "model": ChatRequest.modelID]), models: custom))
        XCTAssertEqual(ChatResponse(model: "custom-model").chunk(delta: [:], includeUsage: false)["model"] as? String, "custom-model")
    }

    private func imageData() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testImageValidationAndHistoryAttachments() throws {
        let png = try imageData()
        let dataURL = "data:image/png;base64," + png.base64EncodedString()
        let message: [String: Any] = ["role": "user", "content": [["type": "image_url", "image_url": ["url": dataURL]]]]
        let request = try parse(["messages": [message, ["role": "assistant", "content": "A red square."], ["role": "user", "content": "What color was it?"]]])
        let transcript = request.makeTranscript(defaultInstructions: "Describe images.")
        guard case .prompt(let prompt) = transcript[1], case .attachment(let attachment) = prompt.segments[0],
              case .image(let image) = attachment.content else { return XCTFail("History image was dropped") }
        XCTAssertEqual(image.cgImage.width, 2)
        XCTAssertEqual(try parse(["messages": [message]]).turns.count, 1)
        assertInvalid(["prompt": "Hello", "image_base64": "!!!"], param: "image_base64", code: "invalid_base64")
        assertInvalid(["prompt": "Hello", "image_base64": Data("not an image".utf8).base64EncodedString()], code: "invalid_image")
        assertInvalid(["prompt": "Hello", "image_url": "https://example.com/photo.png"], param: "image_url", code: "invalid_image_url")
        assertInvalid(["prompt": "Hello", "image_url": "/private/tmp/photo.png"], code: "invalid_image_url")
        assertInvalid(["prompt": "Hello", "image_base64": "data:image/jpeg;base64," + png.base64EncodedString()], code: "image_mime_mismatch")
        assertInvalid(["prompt": "Hello", "image_base64": dataURL, "image_path": "/missing.png"])
        let five = Array(repeating: ["type": "image_url", "image_url": ["url": dataURL]] as [String: Any], count: 5)
        assertInvalid(["messages": [["role": "user", "content": five]]], code: "too_many_images")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ane_image_test_\(UUID().uuidString).png")
        try png.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        assertInvalid(["prompt": "Describe", "image_path": path.path], param: "image_path", code: "path_inputs_disabled")
        let body = try JSONSerialization.data(withJSONObject: ["prompt": "Describe", "image_path": path.path])
        _ = try ChatRequest.parse(body, pathPolicy: PathPolicy.mediaRoot(path.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: path), png, "Validation must not delete or modify the original file")
    }

    func testStreamingUsesUnicodeSafeDeltasAndValidSSEFrames() throws {
        var text = StreamingText()
        XCTAssertEqual(try text.append(snapshot: "e"), "e")
        XCTAssertEqual(try text.append(snapshot: "e\u{301}"), "\u{301}")
        XCTAssertEqual(try text.append(snapshot: "e\u{301}👩"), "👩")
        XCTAssertEqual(try text.append(snapshot: "e\u{301}👩‍💻"), "‍💻")
        XCTAssertEqual(try text.append(snapshot: "e\u{301}👩‍💻"), "")
        XCTAssertThrowsError(try text.append(snapshot: "replacement"))
        let response = ChatResponse()
        let chunk = response.chunk(delta: ["content": "one\ntwo"], includeUsage: true)
        let frame = try XCTUnwrap(String(data: ChatResponse.event(chunk), encoding: .utf8))
        XCTAssertTrue(frame.hasPrefix("data: {"))
        XCTAssertTrue(frame.hasSuffix("\n\n"))
        XCTAssertEqual(frame.filter { $0 == "\n" }.count, 2)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.dropFirst(6).dropLast(2).utf8)) as? [String: Any])
        XCTAssertEqual(decoded["object"] as? String, "chat.completion.chunk")
        XCTAssertTrue(decoded["usage"] is NSNull)
        let final = response.chunk(delta: [:], finishReason: "length", includeUsage: false)
        XCTAssertNil(final["usage"])
        XCTAssertEqual(ChatResponse.finishReason(outputTokens: 10, maximum: 10), "length")
        XCTAssertEqual(ChatResponse.finishReason(outputTokens: 9, maximum: 10), "stop")
    }

    func testErrorsAndHTTPFramingHaveOneEnvelope() throws {
        XCTAssertThrowsError(try ChatRequest.parse(Data("{broken".utf8))) { error in
            XCTAssertEqual((error as? APIError)?.code, "invalid_json")
        }
        let error = APIError.from(LanguageModelError.contextSizeExceeded(.init(contextSize: 4, tokenCount: 5, debugDescription: "test")))
        XCTAssertEqual(error.status, 400)
        XCTAssertEqual(error.code, "context_length_exceeded")
        let response = try XCTUnwrap(String(data: ANEServeServer.errorResponse(error), encoding: .utf8))
        let parts = response.components(separatedBy: "\r\n\r\n")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: [String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(payload["error"]).keys), ["message", "type", "param", "code"])
        XCTAssertEqual(try ANEServeServer.parseContentLength(from: "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 12"), 12)
        for header in ["Content-Length: -1", "Content-Length: nope", "Content-Length: 1\r\nContent-Length: 2", "Transfer-Encoding: chunked", "X-No-Length: yes"] {
            XCTAssertThrowsError(try ANEServeServer.parseContentLength(from: "POST /v1/chat/completions HTTP/1.1\r\n" + header))
        }
    }
}
