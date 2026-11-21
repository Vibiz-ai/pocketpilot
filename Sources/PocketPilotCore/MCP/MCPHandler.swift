import Foundation

/// Owner: mcp. Transport-independent Streamable-HTTP MCP logic: HTTP routing, Mcp-Session-Id sessions,
/// JSON-RPC 2.0 (single + batch), and tool dispatch to a PhoneController. No sockets here, so it's unit-testable.
public final class MCPHandler: @unchecked Sendable {
    public static let serverVersion = "0.1.0"
    public static let supportedProtocolVersions = [MCPDefaults.protocolVersion, "2025-03-26", "2024-11-05"]
    public static let sessionHeader = "Mcp-Session-Id"
    public static let protocolHeader = "MCP-Protocol-Version"
    public static let maxSessions = 64

    public enum RPCCode {
        public static let parseError = -32700
        public static let invalidRequest = -32600
        public static let methodNotFound = -32601
        public static let invalidParams = -32602
        public static let internalError = -32603
        /// Implementation-defined: no / unknown session.
        public static let sessionError = -32001
    }

    public struct Session: Sendable {
        public var id: String
        public var createdAt: Date
        public var lastUsed: Date
        public var protocolVersion: String
        public var clientName: String?
        public var initialized: Bool
    }

    private let controller: PhoneController
    private let statusModel: StatusModel
    private let log: Log
    /// Port shown in /health and status (set by MCPServer once bound).
    public var publicURL: String
    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private let gate = SerialGate()
    /// The input tool currently holding the gate, for status ("Busy: calibrate 57%").
    private var busy: (tool: String, since: Date, progress: Double?)?

    public init(controller: PhoneController, status: StatusModel, log: Log, publicURL: String = MCPDefaults.url) {
        self.controller = controller; self.statusModel = status; self.log = log; self.publicURL = publicURL
    }

    public var sessionCount: Int { lock.withLock { sessions.count } }
    public func session(_ id: String) -> Session? { lock.withLock { sessions[id] } }
    public func removeAllSessions() { lock.withLock { sessions.removeAll() } }

    // MARK: HTTP

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if let origin = request.header("Origin"), !MCPHandler.isLocalOrigin(origin) {
            log.warning("mcp", "Rejected request from origin \(origin)")
            return httpError(403, PocketPilotError(.network, what: "Request refused for origin \(origin)",
                why: "PocketPilot only accepts requests from this Mac, to stop websites from driving your iPhone",
                fix: "Connect from a local MCP client (Claude Code, Cursor, Codex) at \(publicURL)"))
        }
        let path = request.path
        if path == "/health" || path == "/health/" {
            guard request.method == "GET" || request.method == "HEAD" else {
                return httpError(405, methodNotAllowed(request.method, path: "/health", allowed: "GET"), headers: [HTTPHeader("Allow", "GET, HEAD")])
            }
            return .json(200, await health())
        }
        guard path == MCPDefaults.path || path == MCPDefaults.path + "/" else {
            return httpError(404, PocketPilotError(.network, what: "Nothing at \(path)",
                why: "PocketPilot serves MCP at \(MCPDefaults.path) and health at /health",
                fix: "Point your MCP client at \(publicURL)"))
        }
        switch request.method {
        case "POST": return await handlePost(request)
        case "DELETE": return handleDelete(request)
        case "GET":
            return httpError(405, PocketPilotError(.network, what: "GET \(MCPDefaults.path) is not supported",
                why: "PocketPilot doesn't open server-to-client event streams; every response comes back on its POST",
                fix: "Send JSON-RPC messages with POST \(MCPDefaults.path)"), headers: [HTTPHeader("Allow", "POST, DELETE")])
        default:
            return httpError(405, methodNotAllowed(request.method, path: MCPDefaults.path, allowed: "POST or DELETE"),
                             headers: [HTTPHeader("Allow", "POST, DELETE")])
        }
    }

    private func methodNotAllowed(_ method: String, path: String, allowed: String) -> PocketPilotError {
        PocketPilotError(.network, what: "\(method) \(path) is not supported", why: "\(path) only accepts \(allowed)",
                     fix: "Use \(allowed)")
    }

    private func handleDelete(_ request: HTTPRequest) -> HTTPResponse {
        guard let id = request.header(MCPHandler.sessionHeader), !id.isEmpty else {
            return httpError(400, missingSessionError(), code: RPCCode.sessionError)
        }
        let removed = lock.withLock { sessions.removeValue(forKey: id) }
        guard removed != nil else { return httpError(404, unknownSessionError(id), code: RPCCode.sessionError) }
        log.info("mcp", "Session \(id.prefix(8)) ended by the client")
        return .empty(204)
    }

    private func handlePost(_ request: HTTPRequest) async -> HTTPResponse {
        let message: JSONValue
        do {
            guard !request.body.isEmpty else { throw JSONValue.ParseError(message: "The body is empty") }
            message = try JSONValue.parse(request.body)
        } catch {
            let e = PocketPilotError(.invalidArgument, what: "The request body is not valid JSON", why: "\(error)",
                                 fix: "Send one JSON-RPC 2.0 message (or an array of them) as the POST body")
            return .json(400, rpcError(id: .null, code: RPCCode.parseError, e))
        }

        let isBatch: Bool
        let messages: [JSONValue]
        switch message {
        case .array(let a):
            guard !a.isEmpty else {
                let e = PocketPilotError(.invalidArgument, what: "The JSON-RPC batch is empty", why: "The body is []",
                                     fix: "Send at least one JSON-RPC message")
                return .json(400, rpcError(id: .null, code: RPCCode.invalidRequest, e))
            }
            isBatch = true; messages = a
        default:
            isBatch = false; messages = [message]
        }

        var responseHeaders: [HTTPHeader] = []
        var sessionID = request.header(MCPHandler.sessionHeader).flatMap { $0.isEmpty ? nil : $0 }
        let hasInitialize = messages.contains { $0["method"]?.stringValue == "initialize" && $0["id"] != nil }

        if hasInitialize {
            // initialize always starts a fresh session (the header, if any, is ignored).
            let initMsg = messages.first { $0["method"]?.stringValue == "initialize" }
            let requested = initMsg?["params"]?["protocolVersion"]?.stringValue
            let version = requested.flatMap { MCPHandler.supportedProtocolVersions.contains($0) ? $0 : nil } ?? MCPDefaults.protocolVersion
            let clientName = initMsg?["params"]?["clientInfo"]?["name"]?.stringValue
            let id = createSession(protocolVersion: version, clientName: clientName)
            sessionID = id
            responseHeaders.append(HTTPHeader(MCPHandler.sessionHeader, id))
            log.info("mcp", "New session \(id.prefix(8)) for \(clientName ?? "an unnamed client") (protocol \(version))")
        } else {
            guard let id = sessionID else { return httpError(400, missingSessionError(), code: RPCCode.sessionError) }
            guard touchSession(id) else { return httpError(404, unknownSessionError(id), code: RPCCode.sessionError) }
            if let v = request.header(MCPHandler.protocolHeader), !MCPHandler.supportedProtocolVersions.contains(v) {
                let e = PocketPilotError(.invalidArgument, what: "Unsupported MCP protocol version \(v)",
                                     why: "PocketPilot speaks \(MCPHandler.supportedProtocolVersions.joined(separator: ", "))",
                                     fix: "Update your MCP client, or reconnect so it negotiates \(MCPDefaults.protocolVersion)")
                return httpError(400, e)
            }
        }

        var responses: [JSONValue] = []
        for m in messages {
            if let r = await handleMessage(m, sessionID: sessionID) { responses.append(r) }
        }
        if responses.isEmpty { return .empty(202, headers: responseHeaders) }
        return .json(200, isBatch ? .array(responses) : responses[0], headers: responseHeaders)
    }

    // MARK: Sessions

    private func createSession(protocolVersion: String, clientName: String?) -> String {
        let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
        let now = Date()
        lock.withLock {
            if sessions.count >= MCPHandler.maxSessions,
               let oldest = sessions.values.min(by: { $0.lastUsed < $1.lastUsed }) {
                sessions.removeValue(forKey: oldest.id)
            }
            sessions[id] = Session(id: id, createdAt: now, lastUsed: now, protocolVersion: protocolVersion,
                                   clientName: clientName, initialized: false)
        }
        return id
    }

    private func touchSession(_ id: String) -> Bool {
        lock.withLock {
            guard sessions[id] != nil else { return false }
            sessions[id]!.lastUsed = Date()
            return true
        }
    }

    private func missingSessionError() -> PocketPilotError {
        PocketPilotError(.invalidArgument, what: "The request has no \(MCPHandler.sessionHeader) header",
                     why: "PocketPilot needs the session id it returned from initialize on every later request",
                     fix: "Send initialize first, then repeat its \(MCPHandler.sessionHeader) response header on each request")
    }

    private func unknownSessionError(_ id: String) -> PocketPilotError {
        PocketPilotError(.invalidArgument, what: "Session \(id.prefix(12)) is not known",
                     why: "It ended, or PocketPilot restarted since it was created",
                     fix: "Reconnect: send initialize again to start a new session (in Claude Code run /mcp and reconnect pocketpilot)")
    }

    // MARK: JSON-RPC

    /// Handles one JSON-RPC message; nil for notifications and client responses.
    public func handleMessage(_ m: JSONValue, sessionID: String?) async -> JSONValue? {
        guard let obj = m.objectValue else {
            return rpcError(id: .null, code: RPCCode.invalidRequest,
                            PocketPilotError(.invalidArgument, what: "Invalid JSON-RPC message", why: "It is \(m.typeName), not an object",
                                         fix: "Send {\"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"...\"}"))
        }
        let id = obj["id"]
        if let id, !MCPHandler.isValidID(id) {
            let why = id.isNull ? "The id is null, and MCP forbids null request ids" : "The id is \(id.typeName)"
            return rpcError(id: .null, code: RPCCode.invalidRequest,
                            PocketPilotError(.invalidArgument, what: "Invalid JSON-RPC id", why: why,
                                         fix: "Use a string or number id (or leave id out for a notification)"))
        }
        guard obj["jsonrpc"]?.stringValue == "2.0" else {
            if id == nil { return nil }
            return rpcError(id: id ?? .null, code: RPCCode.invalidRequest,
                            PocketPilotError(.invalidArgument, what: "Invalid JSON-RPC message", why: "\"jsonrpc\" must be \"2.0\"",
                                         fix: "Add \"jsonrpc\": \"2.0\""))
        }
        guard let method = obj["method"]?.stringValue else {
            if obj["result"] != nil || obj["error"] != nil { return nil } // a response from the client; we never ask
            return rpcError(id: id ?? .null, code: RPCCode.invalidRequest,
                            PocketPilotError(.invalidArgument, what: "Invalid JSON-RPC message", why: "It has no \"method\"",
                                         fix: "Add \"method\", e.g. \"tools/list\""))
        }
        let params = obj["params"] ?? .object([:])
        guard let id else {
            handleNotification(method, params: params, sessionID: sessionID)
            return nil
        }
        if !params.isNull, params.objectValue == nil {
            return rpcError(id: id, code: RPCCode.invalidParams,
                            PocketPilotError(.invalidArgument, what: "Invalid params for \(method)", why: "params is \(params.typeName), not an object",
                                         fix: "Pass params as an object"))
        }
        let p = params.objectValue ?? [:]

        switch method {
        case "initialize":
            let requested = p["protocolVersion"]?.stringValue
            let version = sessionID.flatMap { session($0)?.protocolVersion }
                ?? requested.flatMap { MCPHandler.supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? MCPDefaults.protocolVersion
            return rpcResult(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(MCPDefaults.serverName), "title": "PocketPilot", "version": .string(MCPHandler.serverVersion)],
                "instructions": .string(MCPTools.instructions),
            ])
        case "ping":
            return rpcResult(id: id, .object([:]))
        case "tools/list":
            return rpcResult(id: id, ["tools": MCPTools.listJSON])
        case "tools/call":
            guard let name = p["name"]?.stringValue else {
                return rpcError(id: id, code: RPCCode.invalidParams,
                                PocketPilotError(.invalidArgument, what: "tools/call has no tool name", why: "params.name is missing",
                                             fix: "Pass params.name, one of: \(MCPTools.names.joined(separator: ", "))"))
            }
            guard MCPTools.definition(named: name) != nil else {
                return rpcError(id: id, code: RPCCode.invalidParams,
                                PocketPilotError(.invalidArgument, what: "Unknown tool \"\(name)\"", why: "PocketPilot has no tool with that name",
                                             fix: "Use one of: \(MCPTools.names.joined(separator: ", "))"))
            }
            let argsValue = p["arguments"] ?? .object([:])
            guard argsValue.isNull || argsValue.objectValue != nil else {
                return rpcResult(id: id, MCPHandler.errorResult(PocketPilotError.invalidArgument("arguments",
                    why: "It is \(argsValue.typeName), not an object", fix: "Pass arguments as an object, e.g. {\"x\": 100, \"y\": 200}")))
            }
            return rpcResult(id: id, await callTool(name, arguments: argsValue.objectValue ?? [:]))
        case "resources/list":
            return rpcResult(id: id, ["resources": []])
        case "resources/templates/list":
            return rpcResult(id: id, ["resourceTemplates": []])
        case "prompts/list":
            return rpcResult(id: id, ["prompts": []])
        default:
            return rpcError(id: id, code: RPCCode.methodNotFound,
                            PocketPilotError(.invalidArgument, what: "Method \"\(method)\" is not supported",
                                         why: "PocketPilot implements initialize, ping, tools/list and tools/call",
                                         fix: "Call one of those methods"))
        }
    }

    private func handleNotification(_ method: String, params: JSONValue, sessionID: String?) {
        switch method {
        case "notifications/initialized":
            if let sessionID { lock.withLock { sessions[sessionID]?.initialized = true } }
        case "notifications/cancelled":
            log.debug("mcp", "Client cancelled request \(params["requestId"]?.description ?? "?") (it will still finish on the phone)")
        default:
            log.debug("mcp", "Ignored notification \(method)")
        }
    }

    static func isValidID(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .number: return true
        default: return false
        }
    }

    func rpcResult(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    func rpcError(id: JSONValue, code: Int, _ e: PocketPilotError) -> JSONValue {
        [
            "jsonrpc": "2.0", "id": id,
            "error": [
                "code": .number(Double(code)),
                "message": .string(e.description),
                "data": ["code": .string(e.code.rawValue), "what": .string(e.what), "why": .string(e.why), "fix": .string(e.fix)],
            ],
        ]
    }

    private func httpError(_ status: Int, _ e: PocketPilotError, code: Int = RPCCode.invalidRequest,
                           headers: [HTTPHeader] = []) -> HTTPResponse {
        .json(status, rpcError(id: .null, code: code, e), headers: headers)
    }

    public static func isLocalOrigin(_ origin: String) -> Bool {
        if origin == "null" { return false }
        guard let comps = URLComponents(string: origin), let host = comps.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }

    // MARK: Tools

    /// Runs one tool and returns a CallToolResult. Tool calls are serialized: there is one phone.
    public func callTool(_ name: String, arguments: [String: JSONValue]) async -> JSONValue {
        let started = Date()
        log.info("mcp", "→ \(name) \(arguments.isEmpty ? "" : JSONValue.object(arguments).serializedString().prefix(200))")
        let result: JSONValue
        do {
            if MCPHandler.readOnlyTools.contains(name) {
                // Read-only: never queue behind a 30 s calibration or a long swipe.
                result = try await runTool(name, arguments)
            } else {
                result = try await gate.run { [self] in
                    lock.withLock { busy = (name, Date(), nil) }
                    defer { lock.withLock { busy = nil } }
                    return try await self.runTool(name, arguments)
                }
            }
            log.info("mcp", "← \(name) ok in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch {
            let e = PocketPilotError.wrap(error, what: "The \(name) tool failed")
            log.warning("mcp", "← \(name) failed: \(e.description)")
            var shot: Screenshot?
            if MCPHandler.attachScreenshotOnError(e.code) {
                shot = try? await controller.screenshot(includeText: true)
            }
            result = MCPHandler.errorResult(e, screenshot: shot)
        }
        return result
    }

    private func runTool(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        switch name {
        case "status":
            try MCPHandler.rejectArguments(args, tool: name)
            var text = MCPHandler.statusText(await controller.status(), url: publicURL)
            if let b = lock.withLock({ busy }) {
                let pct = b.progress.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
                text = "Busy: running \(b.tool)\(pct) for \(Int(Date().timeIntervalSince(b.since))) s; other actions wait for it.\n" + text
            }
            return MCPHandler.textResult(text)
        case "screenshot":
            if let extra = args.keys.first(where: { $0 != "include_text" }) {
                throw PocketPilotError.invalidArgument(extra, why: "screenshot has no argument named \"\(extra)\"", fix: "Pass only include_text")
            }
            let include = try MCPTools.Args(args, context: "").bool("include_text", default: true)
            let shot = try await controller.screenshot(includeText: include)
            return MCPHandler.screenshotResult(summary: "Screenshot", shot)
        case "calibrate":
            try MCPHandler.rejectArguments(args, tool: name)
            let log = self.log
            let data = try await controller.calibrate { [weak self] p in
                log.info("mcp", "Calibrating \(Int(p.fraction * 100))%: \(p.message)")
                guard let self else { return }
                self.lock.withLock { if self.busy != nil { self.busy?.progress = p.fraction } }
            }
            let summary = "Calibrated for a \(Int(data.screenshotSize.width))x\(Int(data.screenshotSize.height)) screenshot "
                + "(\(data.x.samples.count) x samples, \(data.y.samples.count) y samples, parked \(data.park.rawValue)). Taps now use this curve."
            if let shot = try? await controller.screenshot(includeText: true) {
                return MCPHandler.screenshotResult(summary: summary, shot)
            }
            return MCPHandler.textResult(summary)
        case "batch":
            let actions = try MCPTools.parseBatch(args)
            let r = try await controller.performBatch(actions)
            return MCPHandler.screenshotResult(summary: r.summary, r.screenshot)
        default:
            let action = try MCPTools.parseAction(name, args)
            let r = try await controller.perform(action)
            return MCPHandler.screenshotResult(summary: r.summary, r.screenshot)
        }
    }

    static func rejectArguments(_ args: [String: JSONValue], tool: String) throws {
        if let extra = args.keys.sorted().first {
            throw PocketPilotError.invalidArgument(extra, why: "\(tool) takes no arguments", fix: "Call \(tool) with {}")
        }
    }

    /// Tools that only read state; they run outside the gate.
    static let readOnlyTools: Set<String> = ["status", "screenshot"]

    /// Every error gets the live screen attached when there is one ("every action returns image + text");
    /// only the errors that mean there is no screen to show skip it.
    static func attachScreenshotOnError(_ code: PocketPilotError.Code) -> Bool {
        switch code {
        case .noFrame, .captureFailed, .noDevice: return false
        default: return true
        }
    }

    // MARK: Result formatting

    public static func textResult(_ text: String) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": false]
    }

    public static func errorResult(_ e: PocketPilotError, screenshot: Screenshot? = nil) -> JSONValue {
        var text = "\(e.what)\nWhy: \(e.why)\nFix: \(e.fix)\n(error code: \(e.code.rawValue))"
        var content: [JSONValue] = []
        if let s = screenshot {
            content.append(imageContent(s))
            text += "\n\n" + screenshotText(s)
        }
        content.append(["type": "text", "text": .string(text)])
        return ["content": .array(content), "isError": true]
    }

    static func imageContent(_ s: Screenshot) -> JSONValue {
        ["type": "image", "data": .string(s.base64), "mimeType": .string(s.mimeType)]
    }

    public static func screenshotResult(summary: String, _ s: Screenshot) -> JSONValue {
        ["content": [imageContent(s), ["type": "text", "text": .string(summary + "\n" + screenshotText(s))]], "isError": false]
    }

    /// Screenshot size and the OCR list, one item per line: "Settings" at (295, 120).
    public static func screenshotText(_ s: Screenshot) -> String {
        var lines = ["Screenshot \(s.width)x\(s.height) px (frame \(s.frameNumber)); tap coordinates use this space, origin top-left."]
        if let text = s.text {
            if text.isEmpty {
                lines.append("No text recognized on screen.")
            } else {
                lines.append("Text on screen (centre x, y):")
                let ordered = text.sorted { abs($0.y - $1.y) > 8 ? $0.y < $1.y : $0.x < $1.x }
                for t in ordered {
                    var esc = ""
                    JSONValue.writeString(t.text, into: &esc)
                    lines.append("\(esc) (\(Int(t.x.rounded())), \(Int(t.y.rounded())))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func statusText(_ s: StatusSnapshot, url: String) -> String {
        var lines: [String] = []
        lines.append(statusHeadline(s))
        if let d = s.device {
            lines.append("iPhone: \(d.name) (\(d.productType), iOS \(d.iosVersion))")
        } else {
            lines.append("iPhone: none detected")
        }
        if let w = s.screenshotWidth, let h = s.screenshotHeight { lines.append("Screenshot size: \(w)x\(h) px") }
        for c in Component.allCases {
            let st = s[c]
            var line = "- \(c.title): \(st.health.rawValue.uppercased()) - \(st.detail)"
            if let e = st.error { line += "\n    Why: \(e.why)\n    Fix: \(e.fix)" }
            lines.append(line)
        }
        lines.append("MCP endpoint: \(url)")
        return lines.joined(separator: "\n")
    }

    static func statusHeadline(_ s: StatusSnapshot) -> String {
        if s.canControl { return "Ready: PocketPilot can control the iPhone." }
        let needed: [Component] = [.screen, .bluetooth, .assistiveTouch, .calibration]
        let blocking = needed.filter { [.failed, .pending].contains(s[$0].health) }
        if blocking.isEmpty {
            let unverified = needed.filter { s[$0].health == .unknown }.map(\.title)
            return "Probably ready: \(unverified.joined(separator: ", ")) not verified yet (UNKNOWN below). The first tap or calibrate checks it; act and read the result."
        }
        return "Not ready: fix \(blocking.map(\.title).joined(separator: ", ")) (marked FAILED or PENDING below)."
    }

    func health() async -> JSONValue {
        let s = await controller.status()
        var comps: [String: JSONValue] = [:]
        for c in Component.allCases {
            var o: [String: JSONValue] = ["health": .string(s[c].health.rawValue), "detail": .string(s[c].detail)]
            if let e = s[c].error { o["error"] = ["code": .string(e.code.rawValue), "what": .string(e.what), "why": .string(e.why), "fix": .string(e.fix)] }
            comps[c.rawValue] = .object(o)
        }
        var o: [String: JSONValue] = [
            "ok": true,
            "name": .string(MCPDefaults.serverName),
            "version": .string(MCPHandler.serverVersion),
            "protocolVersion": .string(MCPDefaults.protocolVersion),
            "url": .string(publicURL),
            "sessions": .number(Double(sessionCount)),
            "canControl": .bool(s.canControl),
            "components": .object(comps),
        ]
        if let d = s.device {
            o["device"] = ["name": .string(d.name), "model": .string(d.model), "productType": .string(d.productType), "iosVersion": .string(d.iosVersion)]
        }
        return .object(o)
    }
}

/// Runs async operations one at a time, in arrival order.
final class SerialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func run<T>(_ op: @escaping () async throws -> T) async throws -> T {
        let task: Task<T, Error> = lock.withLock {
            let previous = tail
            let t = Task<T, Error> {
                await previous?.value
                return try await op()
            }
            tail = Task { _ = try? await t.value }
            return t
        }
        return try await task.value
    }
}
