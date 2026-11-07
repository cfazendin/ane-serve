import Foundation
import CoreFoundation
import FoundationModels

struct APIError: LocalizedError {
    var status = 400
    var message: String
    var type = "invalid_request_error"
    var param: String?
    var code = "invalid_request"

    var errorDescription: String? { message }

    var body: [String: Any] {
        ["error": object]
    }

    var object: [String: Any] {
        ["message": message, "type": type, "param": param as Any? ?? NSNull(), "code": code]
    }

    static func unsupported(_ param: String) -> APIError {
        APIError(message: "The '\(param)' parameter is not supported.", param: param, code: "unsupported_parameter")
    }

    static func requireModel() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            let message: String
            switch reason {
            case .deviceNotEligible: message = "This Mac is not eligible for Apple's on-device model."
            case .appleIntelligenceNotEnabled: message = "Enable Apple Intelligence on the server Mac."
            case .modelNotReady: message = "The on-device model is not ready. Allow its download to finish on the server Mac."
            @unknown default: message = "Apple's on-device model is unavailable on this Mac."
            }
            throw APIError(status: 503, message: message, type: "service_unavailable_error", code: "model_unavailable")
        }
    }

    static func from(_ error: Error) -> APIError {
        if let error = error as? APIError { return error }
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded:
                return APIError(message: "The conversation exceeds the model's context window. Shorten the messages or requested output.", param: "messages", code: "context_length_exceeded")
            case .rateLimited:
                return APIError(status: 429, message: "The on-device model is rate limited. Retry later.", type: "rate_limit_error", code: "rate_limit_exceeded")
            case .guardrailViolation, .refusal:
                return APIError(message: "The on-device model declined this request.", code: "content_filter")
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide, .unsupportedLanguageOrLocale:
                return APIError(message: error.localizedDescription, code: "unsupported_model_input")
            case .timeout:
                return APIError(status: 504, message: "The on-device model timed out.", type: "timeout_error", code: "model_timeout")
            @unknown default:
                break
            }
        }
        if error is SystemLanguageModel.Error {
            return APIError(status: 503, message: "The on-device model's assets are unavailable.", type: "service_unavailable_error", code: "model_unavailable")
        }
        return APIError(status: 500, message: "The server could not complete the request.", type: "server_error", code: "internal_error")
    }
}

enum RequestJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data), let object = value as? [String: Any] else {
            throw APIError(message: "The request body must be a valid JSON object.", code: "invalid_json")
        }
        return object
    }

    static func value(_ object: [String: Any], _ key: String) -> Any? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        return value
    }

    static func string(_ object: [String: Any], _ key: String) throws -> String? {
        guard let value = Self.value(object, key) else { return nil }
        guard let string = value as? String else {
            throw APIError(message: "'\(key)' must be a string.", param: key)
        }
        return string
    }

    static func bool(_ object: [String: Any], _ key: String, param: String? = nil) throws -> Bool? {
        guard let value = Self.value(object, key) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw APIError(message: "'\(param ?? key)' must be a boolean.", param: param ?? key)
        }
        return number.boolValue
    }

    static func number(_ object: [String: Any], _ key: String) throws -> Double? {
        guard let value = Self.value(object, key) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
            throw APIError(message: "'\(key)' must be a finite number.", param: key)
        }
        return number.doubleValue
    }

    static func integer(_ object: [String: Any], _ key: String) throws -> Int? {
        guard let number = try number(object, key) else { return nil }
        guard let integer = Int(exactly: number) else {
            throw APIError(message: "'\(key)' must be an integer.", param: key)
        }
        return integer
    }

    static func validateKeys(_ object: [String: Any], allowed: Set<String>) throws {
        for key in object.keys.sorted() where !allowed.contains(key) && value(object, key) != nil {
            throw APIError.unsupported(key)
        }
    }
}

struct GenerationSettings {
    let temperature: Double?
    let maxTokens: Int?

    init(_ object: [String: Any]) throws {
        temperature = try RequestJSON.number(object, "temperature")
        if let temperature, !(0...2).contains(temperature) {
            throw APIError(message: "'temperature' must be between 0 and 2.", param: "temperature")
        }
        let maximum = try RequestJSON.integer(object, "max_tokens")
        let completionMaximum = try RequestJSON.integer(object, "max_completion_tokens")
        if let maximum, let completionMaximum, maximum != completionMaximum {
            throw APIError(message: "Use one output token limit, or give both limits the same value.", param: "max_completion_tokens")
        }
        maxTokens = maximum ?? completionMaximum
        if let maxTokens, maxTokens <= 0 {
            throw APIError(message: "The output token limit must be a positive integer.", param: maximum != nil ? "max_tokens" : "max_completion_tokens")
        }
    }

    var options: GenerationOptions {
        GenerationOptions(
            samplingMode: temperature == 0 ? .greedy : nil,
            temperature: temperature,
            maximumResponseTokens: maxTokens
        )
    }
}
