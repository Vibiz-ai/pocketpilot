import Foundation
import Network

/// Owner: mcp. Streamable-HTTP MCP (JSON-RPC 2.0 over POST /mcp, Mcp-Session-Id, protocol 2025-06-18)
/// on Network.framework, bound to 127.0.0.1 only. Tools: status, screenshot, tap, tap_text, long_press, swipe,
/// scroll, type_text, press_key, open_app, calibrate, batch. Protocol logic lives in MCPHandler.
/// Pass `port: 0` for an ephemeral port; the bound port is reported in `state` (.listening) and `boundPort`.
public final class MCPServer: @unchecked Sendable {
    public let state = StateChannel<MCPServerState>(.stopped)
    public let host: String
    public let port: UInt16
    public let handler: MCPHandler
    /// Connections idle longer than this are closed.
    public var idleTimeout: TimeInterval = 120

    private let log: Log
    private let queue = DispatchQueue(label: "pocketpilot.mcp.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    public init(controller: PhoneController, status: StatusModel, log: Log,
                host: String = MCPDefaults.host, port: UInt16 = MCPDefaults.port) {
        self.log = log; self.host = host; self.port = port
        self.handler = MCPHandler(controller: controller, status: status, log: log,
                                  publicURL: "http://\(host):\(port)\(MCPDefaults.path)")
    }

    /// The port actually bound (differs from `port` when it was 0).
    public var boundPort: UInt16? {
        if case .listening(_, let p) = state.value { return p }
        return nil
    }

    public var url: String { "http://\(host):\(boundPort ?? port)\(MCPDefaults.path)" }

    public var connectionCount: Int { lock.withLock { connections.count } }

    public func start() async throws {
        if case .listening = state.value { return }
        state.send(.starting)

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            let e = startError(error)
            state.send(.failed(e)); log.error("mcp", e)
            throw e
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [weak self, weak listener] st in
                guard let self else { return }
                switch st {
                case .ready:
                    let bound = listener?.port?.rawValue ?? self.port
                    self.handler.publicURL = "http://\(self.host):\(bound)\(MCPDefaults.path)"
                    self.state.send(.listening(host: self.host, port: bound))
                    self.log.info("mcp", "MCP server listening on \(self.handler.publicURL)")
                    once.run { cont.resume() }
                case .failed(let err), .waiting(let err):
                    let e = self.startError(err)
                    listener?.stateUpdateHandler = nil
                    listener?.cancel()
                    self.lock.withLock { if self.listener === listener { self.listener = nil } }
                    self.state.send(.failed(e)); self.log.error("mcp", e)
                    once.run { cont.resume(throwing: e) }
                case .cancelled:
                    once.run {
                        cont.resume(throwing: PocketPilotError(.network, what: "The MCP server stopped while starting",
                                                           why: "It was stopped before it finished opening its port",
                                                           fix: "Start it again"))
                    }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            lock.withLock { self.listener = listener }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        let (l, conns): (NWListener?, [HTTPConnection]) = lock.withLock {
            let l = listener; listener = nil
            let c = Array(connections.values); connections.removeAll()
            return (l, c)
        }
        l?.cancel()
        conns.forEach { $0.close() }
        handler.removeAllSessions()
        if l != nil { log.info("mcp", "MCP server stopped") }
        state.send(.stopped)
    }

    private func accept(_ nw: NWConnection) {
        let conn = HTTPConnection(nw, handler: handler, log: log, queue: queue, idleTimeout: idleTimeout)
        let key = ObjectIdentifier(conn)
        lock.withLock { connections[key] = conn }
        conn.onClose = { [weak self] in
            guard let self else { return }
            _ = self.lock.withLock { self.connections.removeValue(forKey: key) }
        }
        conn.start()
    }

    private func startError(_ error: Error) -> PocketPilotError {
        if let nwErr = error as? NWError, case .posix(let code) = nwErr {
            switch code {
            case .EADDRINUSE:
                return PocketPilotError(.network, what: "Couldn't start the MCP server on \(host):\(port)",
                                    why: "Port \(port) is already in use, probably by another PocketPilot or pocketpilot-mock",
                                    fix: "Quit the other copy (run `lsof -nP -iTCP:\(port) -sTCP:LISTEN` to see who holds it), then start PocketPilot again")
            case .EACCES, .EPERM:
                return PocketPilotError(.permissionDenied, what: "Couldn't start the MCP server on \(host):\(port)",
                                    why: "macOS refused to open the port (\(nwErr.localizedDescription))",
                                    fix: "Allow PocketPilot in System Settings > Network > Firewall, or use a port above 1024")
            case .EADDRNOTAVAIL:
                return PocketPilotError(.network, what: "Couldn't start the MCP server on \(host):\(port)",
                                    why: "\(host) is not an address of this Mac",
                                    fix: "Use \(MCPDefaults.host)")
            default: break
            }
        }
        return PocketPilotError(.network, what: "Couldn't start the MCP server on \(host):\(port)",
                            why: error.localizedDescription,
                            fix: "Restart PocketPilot; if it keeps failing, check the log in the PocketPilot window")
    }
}

/// Resume-once guard for continuations fed by state callbacks.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        let first: Bool = lock.withLock { if done { return false }; done = true; return true }
        if first { body() }
    }
}

/// One keep-alive HTTP/1.1 connection. Requests on a connection are handled one at a time, in order.
/// All mutable state is touched only on `queue`.
final class HTTPConnection: @unchecked Sendable {
    private let nw: NWConnection
    private let handler: MCPHandler
    private let log: Log
    private let queue: DispatchQueue
    private let idleTimeout: TimeInterval
    private var parser = HTTPRequestParser()
    private var busy = false
    private var closed = false
    private var peerFinished = false
    private var sentContinue = false
    private var idleTimer: DispatchWorkItem?
    var onClose: (() -> Void)?

    init(_ nw: NWConnection, handler: MCPHandler, log: Log, queue: DispatchQueue, idleTimeout: TimeInterval) {
        self.nw = nw; self.handler = handler; self.log = log; self.queue = queue; self.idleTimeout = idleTimeout
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        nw.start(queue: queue)
        queue.async { [self] in
            armIdleTimer()
            receive()
        }
    }

    func close() { queue.async { [self] in shutdown() } }

    private func shutdown() {
        nw.cancel()
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        let cb = onClose; onClose = nil
        cb?()
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.busy, !self.closed else { return }
            self.shutdown()
        }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + idleTimeout, execute: item)
    }

    private func receive() {
        guard !closed else { return }
        nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.parser.append(data)
                self.armIdleTimer()
            }
            if isComplete || error != nil { self.peerFinished = true }
            self.processBuffered()
            if !self.peerFinished { self.receive() }
        }
    }

    private func processBuffered() {
        guard !busy, !closed else { return }
        let request: HTTPRequest?
        do {
            request = try parser.next()
        } catch let e as HTTPParseError {
            log.warning("mcp", "Bad HTTP request: \(e.pocketPilotError.description)")
            let body: JSONValue = [
                "jsonrpc": "2.0", "id": .null,
                "error": ["code": .number(Double(MCPHandler.RPCCode.invalidRequest)), "message": .string(e.pocketPilotError.description)],
            ]
            send(.json(e.status, body), keepAlive: false, head: false)
            return
        } catch {
            shutdown(); return
        }
        guard let request else {
            if peerFinished { shutdown(); return }
            if parser.wantsContinue, !sentContinue {
                sentContinue = true
                nw.send(content: HTTPResponse.continueBytes, completion: .contentProcessed { _ in })
            }
            return
        }
        sentContinue = false
        busy = true
        let handler = self.handler
        Task {
            let response = await handler.handle(request)
            self.queue.async {
                self.send(response, keepAlive: request.keepAlive, head: request.method == "HEAD")
            }
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool, head: Bool) {
        guard !closed else { return }
        let keep = keepAlive && !peerFinished
        let bytes = response.serialized(keepAlive: keep, includeBody: !head)
        nw.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.busy = false
                if error != nil || !keep {
                    self.shutdown() // cancel() closes gracefully after the queued bytes
                    return
                }
                self.armIdleTimer()
                self.processBuffered()
            }
        })
    }
}
