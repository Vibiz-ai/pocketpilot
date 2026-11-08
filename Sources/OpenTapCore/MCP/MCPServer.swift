import Foundation
import Network

/// Owner: mcp. Streamable-HTTP MCP (JSON-RPC 2.0 over POST /mcp, Mcp-Session-Id, protocol 2025-06-18)
/// on Network.framework. Tools: status, screenshot, tap, tap_text, long_press, swipe, scroll, type_text,
/// press_key, open_app, calibrate, batch.
public final class MCPServer {
    public let state = StateChannel<MCPServerState>(.stopped)
    public let host: String
    public let port: UInt16
    private let controller: PhoneController
    private let statusModel: StatusModel
    private let log: Log

    public init(controller: PhoneController, status: StatusModel, log: Log,
                host: String = MCPDefaults.host, port: UInt16 = MCPDefaults.port) {
        self.controller = controller; self.statusModel = status; self.log = log; self.host = host; self.port = port
    }

    public func start() async throws {
        let e = OpenTapError.notImplemented("The MCP server", module: "MCP")
        state.send(.failed(e))
        throw e
    }

    public func stop() { state.send(.stopped) }
}
