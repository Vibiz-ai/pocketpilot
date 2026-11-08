import Foundation
import OpenTapCore

/// Owner: mcp. Headless MCP server against MockDevice so QA can curl it.
/// Usage: opentap-mock [--port 47900]
var port = MCPDefaults.port
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    if a == "--port", let v = args.popFirst(), let p = UInt16(v) { port = p }
}

let log = Log(echoToStderr: true)
let env = OpenTapEnvironment.mock(log: log, port: port)

Task {
    do {
        await env.device.start()
        try await env.hid.start()
        try await env.frames.start()
    } catch {
        log.warning("mock", "Mock hardware not fully started: \(error)")
    }
    do {
        try await env.mcp.start()
        log.info("mock", "opentap-mock listening on http://\(MCPDefaults.host):\(port)\(MCPDefaults.path)")
    } catch {
        log.error("mock", OpenTapError.wrap(error, what: "Couldn't start the mock MCP server"))
        exit(1)
    }
}
dispatchMain()
