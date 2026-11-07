import Foundation
import Network

/// The request line and headers of an HTTP/1.1 request.
struct HTTPRequestHead {
    let method: String
    /// The request target without its query string.
    let path: String
    /// Header lines, excluding the request line.
    let headerLines: [String]
    let contentLength: Int

    static func parse(_ text: String) throws -> HTTPRequestHead {
        let lines = text.components(separatedBy: "\r\n")
        let tokens = (lines.first ?? "").split(separator: " ")
        guard tokens.count == 3 else {
            throw APIError(message: "Malformed HTTP request line.", code: "invalid_http_request")
        }
        let contentLength = try ANEServeServer.parseContentLength(from: text)
        let path = tokens[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return HTTPRequestHead(method: String(tokens[0]), path: String(path), headerLines: Array(lines.dropFirst()), contentLength: contentLength)
    }

    var hasOrigin: Bool {
        headerLines.contains { $0.lowercased().hasPrefix("origin:") }
    }
}

/// State for one connection while its request arrives. Every member is used only on `queue`.
final class ConnectionReader: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    var buffer = Data()
    var body = Data()
    var requestTask: Task<Void, Never>?
    private(set) var isClosed = false
    private var timer: DispatchWorkItem?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Answers 408 and closes unless the timer is restarted or cancelled within `seconds`.
    func startTimer(seconds: TimeInterval) {
        timer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.finish(with: ANEServeServer.errorResponse(APIError(status: 408, message: "The request did not arrive in time.", code: "request_timeout")))
        }
        timer = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    /// Sends the final response to a request that was never dispatched, then closes.
    func finish(with response: Data) {
        guard !isClosed else { return }
        isClosed = true
        cancelTimer()
        ANEServeServer.sendResponse(response, on: connection)
    }

    /// Stops reading, and cancels any running request, once the connection fails or closes.
    func close() {
        isClosed = true
        cancelTimer()
        requestTask?.cancel()
    }
}
