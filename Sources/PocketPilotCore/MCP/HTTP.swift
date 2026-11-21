import Foundation

/// Owner: mcp. A minimal HTTP/1.1 request parser and response writer (enough for local MCP clients):
/// Content-Length and chunked bodies, keep-alive, Expect: 100-continue, size limits.

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    /// Raw request target, e.g. "/mcp?x=1".
    public var target: String
    public var version: String
    /// Header names keep their original case; look them up with `header(_:)`.
    public var headers: [HTTPHeader]
    public var body: Data

    public init(method: String, target: String, version: String = "HTTP/1.1", headers: [HTTPHeader] = [], body: Data = Data()) {
        self.method = method; self.target = target; self.version = version; self.headers = headers; self.body = body
    }

    /// Path without query string, e.g. "/mcp".
    public var path: String {
        let p = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        if let r = p.range(of: "://") {
            // Absolute-form target: strip scheme and authority.
            let rest = p[r.upperBound...]
            return rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        }
        return p.isEmpty ? "/" : p
    }

    /// Case-insensitive header lookup (first match).
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// HTTP/1.1 keeps the connection open unless "Connection: close"; HTTP/1.0 only with "keep-alive".
    public var keepAlive: Bool {
        let tokens = (header("Connection") ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if version == "HTTP/1.0" { return tokens.contains("keep-alive") }
        return !tokens.contains("close")
    }
}

public struct HTTPHeader: Equatable, Sendable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [HTTPHeader]
    public var body: Data

    public init(status: Int, headers: [HTTPHeader] = [], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public static func json(_ status: Int, _ value: JSONValue, headers: [HTTPHeader] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [HTTPHeader("Content-Type", "application/json")] + headers, body: value.serialized())
    }

    public static func empty(_ status: Int, headers: [HTTPHeader] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers)
    }

    /// The JSON body, if any (handy in tests).
    public var json: JSONValue? { body.isEmpty ? nil : try? JSONValue.parse(body) }

    public static func reason(for status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 408: return "Request Timeout"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        case 505: return "HTTP Version Not Supported"
        default: return "Status \(status)"
        }
    }

    /// Wire bytes. Adds Content-Length and Connection; drops a body for 204.
    public func serialized(keepAlive: Bool, includeBody: Bool = true) -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(for: status))\r\n"
        let reserved: Set<String> = ["content-length", "connection", "transfer-encoding"]
        for h in headers where !reserved.contains(h.name.lowercased()) {
            head += "\(h.name): \(h.value)\r\n"
        }
        let sendBody = includeBody && status != 204 && status != 304
        if status != 204 { head += "Content-Length: \(sendBody ? body.count : 0)\r\n" }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var out = Data(head.utf8)
        if sendBody { out.append(body) }
        return out
    }

    public static let continueBytes = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
}

public enum HTTPParseError: Error, Equatable {
    case malformed(String)
    case headersTooLarge
    case bodyTooLarge(limit: Int)
    case unsupportedVersion(String)
    case unsupportedTransferEncoding(String)

    public var status: Int {
        switch self {
        case .malformed: return 400
        case .headersTooLarge: return 431
        case .bodyTooLarge: return 413
        case .unsupportedVersion: return 505
        case .unsupportedTransferEncoding: return 501
        }
    }

    /// What / why / fix, for the error body.
    public var pocketPilotError: PocketPilotError {
        switch self {
        case .malformed(let why):
            return PocketPilotError(.network, what: "The HTTP request to PocketPilot could not be read", why: why,
                                fix: "Send a standard HTTP/1.1 POST with a JSON body to \(MCPDefaults.path)")
        case .headersTooLarge:
            return PocketPilotError(.network, what: "The HTTP request headers are too large",
                                why: "PocketPilot accepts at most \(HTTPRequestParser.defaultMaxHeaderBytes / 1024) KB of headers",
                                fix: "Send fewer or shorter headers")
        case .bodyTooLarge(let limit):
            return PocketPilotError(.network, what: "The HTTP request body is too large",
                                why: "PocketPilot accepts at most \(limit / (1024 * 1024)) MB per request",
                                fix: "Split the work into smaller requests (for example several batch calls)")
        case .unsupportedVersion(let v):
            return PocketPilotError(.network, what: "Unsupported HTTP version", why: "The request used \(v)",
                                fix: "Use HTTP/1.1")
        case .unsupportedTransferEncoding(let te):
            return PocketPilotError(.network, what: "Unsupported Transfer-Encoding", why: "The request used \"\(te)\"",
                                fix: "Send the body with Content-Length or Transfer-Encoding: chunked")
        }
    }
}

/// Incremental parser: `append` bytes as they arrive, then call `next()` until it returns nil.
public struct HTTPRequestParser {
    public static let defaultMaxHeaderBytes = 64 * 1024
    public static let defaultMaxBodyBytes = 16 * 1024 * 1024

    public let maxHeaderBytes: Int
    public let maxBodyBytes: Int
    private var buffer: [UInt8] = []
    /// True when the current request's headers asked for "Expect: 100-continue" and its body hasn't fully arrived.
    public private(set) var wantsContinue = false

    public init(maxHeaderBytes: Int = HTTPRequestParser.defaultMaxHeaderBytes,
                maxBodyBytes: Int = HTTPRequestParser.defaultMaxBodyBytes) {
        self.maxHeaderBytes = maxHeaderBytes; self.maxBodyBytes = maxBodyBytes
    }

    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ data: Data) { buffer.append(contentsOf: data) }
    public mutating func append(_ string: String) { buffer.append(contentsOf: Array(string.utf8)) }

    /// Returns the next complete request, nil if more bytes are needed, or throws if the stream is unusable.
    public mutating func next() throws -> HTTPRequest? {
        wantsContinue = false
        // Tolerate stray CRLFs between requests (RFC 9112 2.2).
        var skip = 0
        while skip + 1 < buffer.count, buffer[skip] == 13, buffer[skip + 1] == 10 { skip += 2 }
        if skip > 0 { buffer.removeFirst(skip) }

        guard let headEnd = HTTPRequestParser.find([13, 10, 13, 10], in: buffer, from: 0) else {
            if buffer.count > maxHeaderBytes { throw HTTPParseError.headersTooLarge }
            return nil
        }
        if headEnd > maxHeaderBytes { throw HTTPParseError.headersTooLarge }
        guard let headText = String(bytes: buffer[0..<headEnd], encoding: .utf8)
                ?? String(bytes: buffer[0..<headEnd], encoding: .isoLatin1) else {
            throw HTTPParseError.malformed("The request headers are not text")
        }
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3 else { throw HTTPParseError.malformed("The request line \"\(requestLine.prefix(80))\" is not \"METHOD /path HTTP/1.1\"") }
        let (method, target, version) = (parts[0], parts[1], parts[2])
        guard version.hasPrefix("HTTP/") else { throw HTTPParseError.malformed("\"\(version.prefix(20))\" is not an HTTP version") }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { throw HTTPParseError.unsupportedVersion(version) }

        var headers: [HTTPHeader] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw HTTPParseError.malformed("The header line \"\(line.prefix(80))\" has no colon")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { throw HTTPParseError.malformed("Invalid header name \"\(name.prefix(40))\"") }
            headers.append(HTTPHeader(name, value))
        }
        let head = HTTPRequest(method: method, target: target, version: version, headers: headers)
        let bodyStart = headEnd + 4

        let body: [UInt8]
        let consumed: Int
        if let te = head.header("Transfer-Encoding") {
            let codings = te.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard codings.last == "chunked", codings.allSatisfy({ $0 == "chunked" || $0 == "identity" }) else {
                throw HTTPParseError.unsupportedTransferEncoding(te)
            }
            guard let (b, end) = try decodeChunked(from: bodyStart) else {
                wantsContinue = expectsContinue(head)
                return nil
            }
            body = b; consumed = end
        } else if let cl = contentLength(head) {
            let length = try cl.get()
            if length > maxBodyBytes { throw HTTPParseError.bodyTooLarge(limit: maxBodyBytes) }
            guard buffer.count - bodyStart >= length else {
                wantsContinue = expectsContinue(head)
                return nil
            }
            body = Array(buffer[bodyStart..<(bodyStart + length)]); consumed = bodyStart + length
        } else {
            body = []; consumed = bodyStart
        }
        buffer.removeFirst(consumed)
        var request = head
        request.body = Data(body)
        return request
    }

    private func expectsContinue(_ r: HTTPRequest) -> Bool {
        r.version == "HTTP/1.1" && (r.header("Expect")?.lowercased() == "100-continue")
    }

    private func contentLength(_ r: HTTPRequest) -> Result<Int, HTTPParseError>? {
        let values = r.headers.filter { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { $0.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        guard let first = values.first else { return nil }
        guard values.allSatisfy({ $0 == first }), !first.isEmpty, first.allSatisfy(\.isASCII), first.allSatisfy(\.isNumber),
              let n = Int(first) else {
            return .failure(.malformed("Content-Length \"\(values.joined(separator: ", ").prefix(40))\" is not a single number"))
        }
        return .success(n)
    }

    /// Decodes a chunked body starting at `start`. Returns (body, index just past the message) or nil if incomplete.
    private func decodeChunked(from start: Int) throws -> ([UInt8], Int)? {
        var body: [UInt8] = []
        var pos = start
        while true {
            guard let lineEnd = HTTPRequestParser.find([13, 10], in: buffer, from: pos) else {
                if buffer.count - pos > 1024 { throw HTTPParseError.malformed("A chunk size line is too long") }
                return nil
            }
            let sizeLine = String(decoding: buffer[pos..<lineEnd], as: UTF8.self)
            let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !sizeText.isEmpty, let size = Int(sizeText, radix: 16), size >= 0 else {
                throw HTTPParseError.malformed("\"\(sizeLine.prefix(20))\" is not a valid chunk size")
            }
            pos = lineEnd + 2
            if size == 0 {
                // Trailer section: zero or more header lines, then an empty line.
                while true {
                    guard let end = HTTPRequestParser.find([13, 10], in: buffer, from: pos) else { return nil }
                    if end == pos { return (body, end + 2) }
                    pos = end + 2
                }
            }
            if body.count + size > maxBodyBytes { throw HTTPParseError.bodyTooLarge(limit: maxBodyBytes) }
            guard buffer.count >= pos + size + 2 else { return nil }
            body.append(contentsOf: buffer[pos..<(pos + size)])
            pos += size
            guard buffer[pos] == 13, buffer[pos + 1] == 10 else { throw HTTPParseError.malformed("A chunk is not followed by CRLF") }
            pos += 2
        }
    }

    static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard needle.count > 0, hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        var i = from
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == needle[0] {
                var match = true
                for j in 1..<needle.count where hay[i + j] != needle[j] { match = false; break }
                if match { return i }
            }
            i += 1
        }
        return nil
    }
}
