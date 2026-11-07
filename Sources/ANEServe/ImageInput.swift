import Foundation
import ImageIO
import CoreGraphics

struct ValidatedImage {
    let cgImage: CGImage
}

enum ImageInput {
    static let maximumBytes = 20 * 1024 * 1024
    static let maximumPixels = 64_000_000
    static let maximumImages = 4
    static let fields: Set<String> = ["image_base64", "image_path", "image_url"]

    // ImageIO reports these identifiers directly. Avoid LaunchServices UTI
    // conformance/tag queries, which may be unavailable to a headless process.
    private static let mimeTypes: [String: Set<String>] = [
        "public.jpeg": ["image/jpeg", "image/jpg"],
        "public.png": ["image/png"],
        "public.tiff": ["image/tiff"],
        "com.compuserve.gif": ["image/gif"],
        "org.webmproject.webp": ["image/webp"],
        "public.heic": ["image/heic", "image/heif"],
        "public.heif": ["image/heif"],
        "com.microsoft.bmp": ["image/bmp", "image/x-ms-bmp"],
        "public.avif": ["image/avif"]
    ]

    static func fromObject(_ object: [String: Any], pathPolicy: PathPolicy) throws -> ValidatedImage? {
        let supplied = fields.sorted().filter { RequestJSON.value(object, $0) != nil }
        guard supplied.count <= 1 else {
            throw APIError(message: "Provide only one of 'image_base64', 'image_path', or 'image_url'.", param: supplied[0])
        }
        guard let field = supplied.first else { return nil }
        if field == "image_url" {
            return try fromURLValue(object[field]!, param: field)
        }
        guard let input = try RequestJSON.string(object, field), !input.isEmpty else {
            throw APIError(message: "'\(field)' must not be empty.", param: field)
        }
        if field == "image_path" { return try fromPath(input, param: field, pathPolicy: pathPolicy) }
        return try fromBase64(input, param: field, requireDataURL: false)
    }

    static func fromURLValue(_ value: Any, param: String) throws -> ValidatedImage {
        let reference: String
        var longestSide = 4096
        if let string = value as? String {
            reference = string
        } else if let object = value as? [String: Any], let url = object["url"] as? String {
            reference = url
            if let detail = RequestJSON.value(object, "detail") {
                guard let detail = detail as? String, ["auto", "low", "high"].contains(detail) else {
                    throw APIError(message: "Image detail must be 'auto', 'low', or 'high'.", param: param + ".detail")
                }
                if detail == "low" { longestSide = 512 }
            }
            try RequestJSON.validateKeys(object, allowed: ["url", "detail"])
        } else {
            throw APIError(message: "An image_url must contain a base64 image data URL.", param: param)
        }
        return try fromBase64(reference, param: param, requireDataURL: true, longestSide: longestSide)
    }

    private static func fromPath(_ path: String, param: String, pathPolicy: PathPolicy) throws -> ValidatedImage {
        let url = try pathPolicy.file(path, param: param)
        let data: Data
        do {
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumBytes { throw tooLarge(param) }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError(message: "The image file could not be read on the server Mac.", param: param, code: "invalid_image")
        }
        return try validate(data, declaredMIME: nil, param: param, longestSide: 4096)
    }

    static func fromBase64(_ input: String, param: String, requireDataURL: Bool, longestSide: Int = 4096) throws -> ValidatedImage {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var encoded = input
        var mime: String?
        if input.lowercased().hasPrefix("data:") {
            guard let comma = input.firstIndex(of: ",") else { throw invalidBase64(param) }
            let header = input[input.index(input.startIndex, offsetBy: 5)..<comma].lowercased()
            let parts = header.split(separator: ";", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].hasPrefix("image/"), parts[1] == "base64" else {
                throw APIError(message: "Expected data:image/<type>;base64,<data>.", param: param, code: "invalid_image")
            }
            mime = String(parts[0])
            encoded = String(input[input.index(after: comma)...])
        } else if requireDataURL {
            throw APIError(message: "Use a base64 image data URL. Remote URLs and file paths are not accepted in image_url; use image_path for a server-local file.", param: param, code: "invalid_image_url")
        }
        guard encoded.utf8.count <= ((maximumBytes + 2) / 3) * 4 + 4096 else { throw tooLarge(param) }
        let clean = encoded.filter { !" \t\r\n".contains($0) }
        guard !clean.isEmpty, let data = Data(base64Encoded: clean) else { throw invalidBase64(param) }
        return try validate(data, declaredMIME: mime, param: param, longestSide: longestSide)
    }

    private static func validate(_ data: Data, declaredMIME: String?, param: String, longestSide: Int) throws -> ValidatedImage {
        guard data.count <= maximumBytes else { throw tooLarge(param) }
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source),
              let acceptedMIMEs = mimeTypes[identifier as String],
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw APIError(message: "Provide a complete JPEG, PNG, GIF, WebP, HEIC/HEIF, TIFF, BMP, or AVIF image supported by ImageIO.", param: param, code: "invalid_image")
        }
        if let declaredMIME {
            guard acceptedMIMEs.contains(declaredMIME) else {
                throw APIError(message: "The image bytes do not match the data URL's MIME type.", param: param, code: "image_mime_mismatch")
            }
        }
        let pixels = width.doubleValue * height.doubleValue
        guard width.doubleValue > 0, height.doubleValue > 0, pixels.isFinite, pixels <= Double(maximumPixels) else {
            throw APIError(status: 413, message: "Images must contain at most 64 million pixels.", param: param, code: "image_too_large")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw APIError(message: "The image could not be decoded.", param: param, code: "invalid_image")
        }
        return ValidatedImage(cgImage: image)
    }

    private static func invalidBase64(_ param: String) -> APIError {
        APIError(message: "The image must contain valid base64 data.", param: param, code: "invalid_base64")
    }

    private static func tooLarge(_ param: String) -> APIError {
        APIError(status: 413, message: "Each decoded image must be at most 20 MiB.", param: param, code: "image_too_large")
    }
}
