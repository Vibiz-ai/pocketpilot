import Foundation
import XCTest
@testable import PocketPilotCore

/// Owner: mcp. Session handling, JSON-RPC routing, error codes and tool results (no network).
final class MCPHandlerTests: XCTestCase {
    var controller: StubPhoneController!
    var handler: MCPHandler!

    override func setUp() {
        controller = StubPhoneController()
        handler = MCPHandler(controller: controller, status: StatusModel(), log: Log())
    }

    private func initialize() async throws -> String {
        let r = await handler.handle(MCPTestRequests.post(MCPTestRequests.initialize))
        XCTAssertEqual(r.status, 200)
        return try XCTUnwrap(r.header("Mcp-Session-Id"))
    }

    private func call(_ body: String, session: String) async -> HTTPResponse {
        await handler.handle(MCPTestRequests.post(body, session: session))
    }

    private func callTool(_ name: String, _ args: String = "{}", session: String) async throws -> JSONValue {
        let r = await call(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#, session: session)
        XCTAssertEqual(r.status, 200)
        return try XCTUnwrap(r.json?["result"])
    }

    func testInitializeIssuesSession() async throws {
        let r = await handler.handle(MCPTestRequests.post(MCPTestRequests.initialize))
        XCTAssertEqual(r.status, 200)
        let id = try XCTUnwrap(r.header("Mcp-Session-Id"))
        XCTAssertGreaterThanOrEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { $0.isASCII && !$0.isWhitespace })
        let result = try XCTUnwrap(r.json?["result"])
        XCTAssertEqual(r.json?["id"], 1)
        XCTAssertEqual(result["protocolVersion"], "2025-06-18")
        XCTAssertEqual(result["serverInfo"]?["name"], "pocketpilot")
        XCTAssertNotNil(result["capabilities"]?["tools"])
        XCTAssertTrue(result["instructions"]?.stringValue?.contains("AssistiveTouch") ?? false)
        XCTAssertEqual(handler.sessionCount, 1)
    }

    func testOlderProtocolVersionIsEchoedUnknownGetsLatest() async throws {
        let old = await handler.handle(MCPTestRequests.post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#))
        XCTAssertEqual(old.json?["result"]?["protocolVersion"], "2025-03-26")
        let future = await handler.handle(MCPTestRequests.post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#))
        XCTAssertEqual(future.json?["result"]?["protocolVersion"], "2025-06-18")
    }

    func testSessionRequiredAndValidated() async throws {
        let list = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let missing = await handler.handle(MCPTestRequests.post(list))
        XCTAssertEqual(missing.status, 400)
        XCTAssertEqual(missing.json?["error"]?["code"], .number(Double(MCPHandler.RPCCode.sessionError)))
        XCTAssertNotNil(missing.json?["error"]?["data"]?["fix"]?.stringValue)

        let unknown = await call(list, session: "nope")
        XCTAssertEqual(unknown.status, 404)

        let id = try await initialize()
        let ok = await call(list, session: id)
        XCTAssertEqual(ok.status, 200)

        let badVersion = await handler.handle(MCPTestRequests.post(list, session: id, headers: [HTTPHeader("MCP-Protocol-Version", "1999-01-01")]))
        XCTAssertEqual(badVersion.status, 400)
    }

    func testNotificationsGet202() async throws {
        let id = try await initialize()
        let r = await call(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, session: id)
        XCTAssertEqual(r.status, 202)
        XCTAssertTrue(r.body.isEmpty)
        XCTAssertEqual(handler.session(id)?.initialized, true)
        // A client response (to a request we never sent) is also accepted with 202.
        let resp = await call(#"{"jsonrpc":"2.0","id":5,"result":{}}"#, session: id)
        XCTAssertEqual(resp.status, 202)
    }

    func testDeleteEndsSession() async throws {
        let id = try await initialize()
        var del = HTTPRequest(method: "DELETE", target: "/mcp", headers: [HTTPHeader("Mcp-Session-Id", id)])
        let r = await handler.handle(del)
        XCTAssertEqual(r.status, 204)
        XCTAssertEqual(handler.sessionCount, 0)
        let again = await handler.handle(del)
        XCTAssertEqual(again.status, 404)
        del.headers = []
        let none = await handler.handle(del)
        XCTAssertEqual(none.status, 400)
        let after = await call(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, session: id)
        XCTAssertEqual(after.status, 404)
    }

    func testHTTPRouting() async throws {
        let get = await handler.handle(HTTPRequest(method: "GET", target: "/mcp"))
        XCTAssertEqual(get.status, 405)
        XCTAssertEqual(get.header("Allow"), "POST, DELETE")
        let put = await handler.handle(HTTPRequest(method: "PUT", target: "/mcp"))
        XCTAssertEqual(put.status, 405)
        let missing = await handler.handle(HTTPRequest(method: "POST", target: "/nope"))
        XCTAssertEqual(missing.status, 404)
        let health = await handler.handle(HTTPRequest(method: "GET", target: "/health"))
        XCTAssertEqual(health.status, 200)
        XCTAssertEqual(health.json?["ok"], true)
        XCTAssertEqual(health.json?["name"], "pocketpilot")
        XCTAssertEqual(health.json?["components"]?["usb"]?["health"], "unknown")
        let foreign = await handler.handle(MCPTestRequests.post(MCPTestRequests.initialize, headers: [HTTPHeader("Origin", "https://evil.example")]))
        XCTAssertEqual(foreign.status, 403)
        let local = await handler.handle(MCPTestRequests.post(MCPTestRequests.initialize, headers: [HTTPHeader("Origin", "http://localhost:3000")]))
        XCTAssertEqual(local.status, 200)
    }

    func testJSONRPCErrorCodes() async throws {
        let id = try await initialize()
        let parse = await call("{not json", session: id)
        XCTAssertEqual(parse.status, 400)
        XCTAssertEqual(parse.json?["error"]?["code"], -32700)
        XCTAssertEqual(parse.json?["id"], .null)

        let emptyBatch = await call("[]", session: id)
        XCTAssertEqual(emptyBatch.json?["error"]?["code"], -32600)

        let noVersion = await call(#"{"id":3,"method":"ping"}"#, session: id)
        XCTAssertEqual(noVersion.json?["error"]?["code"], -32600)

        let unknownMethod = await call(#"{"jsonrpc":"2.0","id":"abc","method":"sampling/createMessage"}"#, session: id)
        XCTAssertEqual(unknownMethod.json?["error"]?["code"], -32601)
        XCTAssertEqual(unknownMethod.json?["id"], "abc")

        let unknownTool = await call(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fly"}}"#, session: id)
        XCTAssertEqual(unknownTool.json?["error"]?["code"], -32602)
        XCTAssertTrue(unknownTool.json?["error"]?["message"]?.stringValue?.contains("tap_text") ?? false)

        let badParams = await call(#"{"jsonrpc":"2.0","id":5,"method":"tools/list","params":[1]}"#, session: id)
        XCTAssertEqual(badParams.json?["error"]?["code"], -32602)

        let ping = await call(#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#, session: id)
        XCTAssertEqual(ping.json?["result"], .object([:]))
    }

    func testBatchRequests() async throws {
        let id = try await initialize()
        let r = await call(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"tools/list"},5]"#, session: id)
        XCTAssertEqual(r.status, 200)
        let arr = try XCTUnwrap(r.json?.arrayValue)
        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr[0]["id"], 1)
        XCTAssertEqual(arr[1]["result"]?["tools"]?.arrayValue?.count, 12)
        XCTAssertEqual(arr[2]["error"]?["code"], -32600)
    }

    func testToolsList() async throws {
        let id = try await initialize()
        let r = await call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, session: id)
        let tools = try XCTUnwrap(r.json?["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, MCPTools.names)
        let tap = try XCTUnwrap(tools.first { $0["name"] == "tap" })
        XCTAssertEqual(tap["inputSchema"]?["required"], ["x", "y"])
        XCTAssertEqual(tap["inputSchema"]?["properties"]?["x"]?["type"], "number")
    }

    func testActionToolReturnsImageAndOCR() async throws {
        let id = try await initialize()
        let result = try await callTool("tap", #"{"x":100,"y":200}"#, session: id)
        XCTAssertEqual(result["isError"], false)
        let content = try XCTUnwrap(result["content"]?.arrayValue)
        XCTAssertEqual(content[0]["type"], "image")
        XCTAssertEqual(content[0]["mimeType"], "image/jpeg")
        XCTAssertEqual(content[0]["data"]?.stringValue, Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString())
        let text = try XCTUnwrap(result.resultText)
        XCTAssertTrue(text.hasPrefix("Did tap"))
        XCTAssertTrue(text.contains("590x1280"))
        XCTAssertTrue(text.contains(#""Settings" (100, 201)"#))
        XCTAssertTrue(text.contains(#""Say \"hi\"" (50, 40)"#))
        // Reading order: y=40 before y=200.
        XCTAssertLessThan(text.range(of: "Say")!.lowerBound, text.range(of: "Settings")!.lowerBound)
        XCTAssertEqual(controller.performed, [.tap(x: 100, y: 200)])
    }

    func testScreenshotWithoutText() async throws {
        let id = try await initialize()
        let result = try await callTool("screenshot", #"{"include_text":false}"#, session: id)
        XCTAssertEqual(result["content"]?.arrayValue?.count, 2)
        XCTAssertFalse(result.resultText?.contains("Text on screen") ?? true)
    }

    func testInvalidArgumentsAreToolErrorsWithFix() async throws {
        let id = try await initialize()
        let result = try await callTool("swipe", #"{"from_x":1}"#, session: id)
        XCTAssertEqual(result["isError"], true)
        let text = try XCTUnwrap(result.resultText)
        XCTAssertTrue(text.contains("Invalid value for 'from_y'"))
        XCTAssertTrue(text.contains("Why: "))
        XCTAssertTrue(text.contains("Fix: "))
        XCTAssertTrue(controller.performed.isEmpty)
    }

    func testControllerErrorsBecomeIsErrorWithScreenshotWhenUseful() async throws {
        let id = try await initialize()
        controller.failure = PocketPilotError(.textNotFound, what: "Couldn't find \"Wifi\" on screen", why: "OCR saw 12 other items",
                                          fix: "Check the screenshot and try a different spelling")
        let r = try await callTool("tap_text", #"{"text":"Wifi"}"#, session: id)
        XCTAssertEqual(r["isError"], true)
        XCTAssertEqual(r["content"]?.arrayValue?.first?["type"], "image")
        XCTAssertTrue(r.resultText?.contains("Fix: Check the screenshot") ?? false)
        XCTAssertTrue(r.resultText?.contains("textNotFound") ?? false)

        controller.failure = PocketPilotError(.hidNotConnected, what: "Bluetooth isn't connected", why: "No HID host", fix: "Pair PocketPilot")
        let r2 = try await callTool("tap", #"{"x":1,"y":1}"#, session: id)
        XCTAssertEqual(r2["isError"], true)
        // QA: the screen is live, so the agent sees it even when input can't be sent.
        XCTAssertEqual(r2["content"]?.arrayValue?.count, 2)
        XCTAssertEqual(r2["content"]?.arrayValue?.first?["type"], "image")

        controller.failure = PocketPilotError(.noFrame, what: "No iPhone screen yet", why: "Unplugged", fix: "Plug it in")
        let r3 = try await callTool("tap", #"{"x":1,"y":1}"#, session: id)
        XCTAssertEqual(r3["content"]?.arrayValue?.count, 1) // no screen to show
    }

    func testBatchAndCalibrateAndStatus() async throws {
        let id = try await initialize()
        let b = try await callTool("batch", #"{"actions":[{"action":"tap","x":1,"y":2},{"action":"wait","ms":10}]}"#, session: id)
        XCTAssertEqual(b["isError"], false)
        XCTAssertEqual(controller.batches, [[.tap(x: 1, y: 2), .wait(ms: 10)]])

        let c = try await callTool("calibrate", session: id)
        XCTAssertEqual(c["isError"], false)
        XCTAssertTrue(c.resultText?.contains("Calibrated") ?? false)

        controller.snapshot[.bluetooth] = .failed(PocketPilotError(.bluetoothUnavailable, what: "Bluetooth is off", why: "The Mac's Bluetooth is off", fix: "Turn on Bluetooth"))
        let s = try await callTool("status", session: id)
        let text = try XCTUnwrap(s.resultText)
        XCTAssertTrue(text.contains("Not ready"))
        XCTAssertTrue(text.contains("Bluetooth: FAILED - Bluetooth is off"))
        XCTAssertTrue(text.contains("Fix: Turn on Bluetooth"))

        let extra = try await callTool("status", #"{"verbose":true}"#, session: id)
        XCTAssertEqual(extra["isError"], true)
    }
}
