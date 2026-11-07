import Foundation

enum ServerBinding {
    static func validate(host: String, apiKey: String?) throws {
        guard !host.isEmpty else { throw APIError(message: "The bind host must not be empty.", param: "host") }
        let local = host == "localhost" || host == "::1" || host == "127.0.0.1"
        if !local && (apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw APIError(message: "LAN bindings require an API key. Set ANE_API_KEY or --api-key, or use --host 127.0.0.1.", param: "api_key", code: "api_key_required")
        }
    }
}

struct VideoScanOptions {
    let maxDuration: Double
    let frameInterval: Double
    let sceneThreshold: Float
    let maxVLMScenes: Int

    init(maxDuration: Double = 180, frameInterval: Double = 1, sceneThreshold: Double = 0.42, maxVLMScenes: Int = 8) throws {
        guard maxDuration.isFinite, maxDuration > 0, maxDuration <= 3600 else {
            throw APIError(message: "'max_duration_sec' must be greater than 0 and at most 3600.", param: "max_duration_sec")
        }
        guard frameInterval.isFinite, (0.25...60).contains(frameInterval) else {
            throw APIError(message: "'frame_interval_sec' must be between 0.25 and 60.", param: "frame_interval_sec")
        }
        guard ceil(maxDuration / frameInterval) <= 3600 else {
            throw APIError(message: "The requested duration and interval exceed the 3600-frame scan limit.", param: "frame_interval_sec")
        }
        guard sceneThreshold.isFinite, (0...2).contains(sceneThreshold) else {
            throw APIError(message: "'scene_threshold' must be between 0 and 2.", param: "scene_threshold")
        }
        guard (0...32).contains(maxVLMScenes) else {
            throw APIError(message: "'max_vlm_scenes' must be an integer between 0 and 32.", param: "max_vlm_scenes")
        }
        self.maxDuration = maxDuration
        self.frameInterval = frameInterval
        self.sceneThreshold = Float(sceneThreshold)
        self.maxVLMScenes = maxVLMScenes
    }

    init(_ object: [String: Any]) throws {
        try self.init(maxDuration: RequestJSON.number(object, "max_duration_sec") ?? 180,
                      frameInterval: RequestJSON.number(object, "frame_interval_sec") ?? 1,
                      sceneThreshold: RequestJSON.number(object, "scene_threshold") ?? 0.42,
                      maxVLMScenes: RequestJSON.integer(object, "max_vlm_scenes") ?? 8)
    }
}

/// Limits which server-side files the `*_path` request fields may read.
public struct PathPolicy: Sendable {
    /// Canonical media root, or nil when path fields are disabled.
    public let root: String?

    public static let disabled = PathPolicy(root: nil)

    private init(root: String?) { self.root = root }

    /// Allows path fields to read regular files inside `directory`, after resolving symlinks.
    public static func mediaRoot(_ directory: String) throws -> PathPolicy {
        var isDirectory: ObjCBool = false
        guard let root = canonicalPath(directory),
              FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw APIError(message: "The media root must be an existing folder: \(directory)", param: "media_root")
        }
        return PathPolicy(root: root)
    }

    /// Returns the resolved file for a request path. Throws when path fields are disabled, or
    /// when the path, after resolving symlinks, is not a readable regular file inside the root.
    func file(_ path: String, param: String) throws -> URL {
        guard let root else {
            throw APIError(status: 403, message: "Server-side file paths are disabled. Upload the file as base64, or start ane-serve with --media-root <folder>.",
                           type: "permission_error", param: param, code: "path_inputs_disabled")
        }
        // Missing files and files outside the root share one error, so a client cannot
        // use it to probe for files elsewhere on the Mac.
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix("/"), let resolved = Self.canonicalPath(path), resolved.hasPrefix(prefix) else {
            throw APIError(message: "'\(param)' must be an absolute path to a file inside the server's media root.", param: param, code: "invalid_path")
        }
        let url = URL(fileURLWithPath: resolved)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              FileManager.default.isReadableFile(atPath: resolved) else {
            throw APIError(message: "'\(param)' must name a readable regular file.", param: param, code: "invalid_path")
        }
        return url
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

struct MediaInput {
    /// Extensions accepted for base64 uploads. ffmpeg chooses some demuxers by extension,
    /// so playlist and text extensions such as m3u8 or asc are never written to disk.
    static let uploadFormats: Set<String> = ["3gp", "aac", "aif", "aiff", "avi", "caf", "flac", "m4a", "m4v", "mkv", "mov",
                                             "mp3", "mp4", "mpeg", "mpg", "oga", "ogg", "opus", "ts", "wav", "webm"]

    let url: URL
    private let temporary: Bool

    init(_ object: [String: Any], paths: [String], base64: String, defaultFormat: String, pathPolicy: PathPolicy) throws {
        let keys = paths + [base64]
        let supplied = keys.filter { RequestJSON.value(object, $0) != nil }
        guard supplied.count == 1, let key = supplied.first else {
            throw APIError(message: "Provide exactly one of: \(keys.joined(separator: ", ")).", param: base64)
        }
        guard let value = try RequestJSON.string(object, key), !value.isEmpty else {
            throw APIError(message: "'\(key)' must be a nonempty string.", param: key)
        }
        if key == base64 {
            let format = (try RequestJSON.string(object, "format") ?? defaultFormat).lowercased()
            guard Self.uploadFormats.contains(format) else {
                throw APIError(message: "'format' must be one of: \(Self.uploadFormats.sorted().joined(separator: ", ")).", param: "format")
            }
            let encoded = value.hasPrefix("data:") ? String(value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).last ?? "") : value
            guard let data = Data(base64Encoded: encoded.filter { !" \t\r\n".contains($0) }), !data.isEmpty else {
                throw APIError(message: "'\(base64)' must contain valid base64 media data.", param: base64, code: "invalid_base64")
            }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("ane_media_\(UUID().uuidString).\(format)")
            try data.write(to: target)
            url = target
            temporary = true
        } else {
            url = try pathPolicy.file(value, param: key)
            temporary = false
        }
    }

    func cleanup() { if temporary { try? FileManager.default.removeItem(at: url) } }
}
