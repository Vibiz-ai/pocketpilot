import Foundation
import XCTest
@testable import OpenTapCore

/// Owner: mcp. One real round trip over 127.0.0.1 on an ephemeral port.
final class MCPServerLoopbackTests: XCTestCase {
    func testLoopbackSessionAndToolCall() async throws {
        let controller = StubPhoneController()
        let server = MCPServer(controller: controller, status: StatusModel(), log: Log(), port: 0)
        try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.boundPort)
        XCTAssertNotEqual(port, 0)
        XCTAssertEqual(server.state.value, .listening(host: "127.0.0.1", port: port))
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!

        let session = URLSession(configuration: .ephemeral)
        func post(_ body: String, sessionID: String?) async throws -> (Data, HTTPURLResponse) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            req.httpBody = Data(body.utf8)
            let (data, resp) = try await session.data(for: req)
            return (data, resp as! HTTPURLResponse)
        }

        let (initData, initResp) = try await post(MCPTestRequests.initialize, sessionID: nil)
        XCTAssertEqual(initResp.statusCode, 200)
        let sid = try XCTUnwrap(initResp.value(forHTTPHeaderField: "Mcp-Session-Id"))
        XCTAssertEqual(try JSONValue.parse(initData)["result"]?["protocolVersion"], "2025-06-18")

        let (_, notif) = try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, sessionID: sid)
        XCTAssertEqual(notif.statusCode, 202)

        let (callData, callResp) = try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"tap_text","arguments":{"text":"Settings"}}}"#, sessionID: sid)
        XCTAssertEqual(callResp.statusCode, 200)
        let result = try JSONValue.parse(callData)["result"]
        XCTAssertEqual(result?["isError"], false)
        XCTAssertEqual(result?["content"]?.arrayValue?.first?["type"], "image")
        XCTAssertEqual(controller.performed, [.tapText(text: "Settings", occurrence: 1)])

        let (healthData, healthResp) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((healthResp as! HTTPURLResponse).statusCode, 200)
        XCTAssertEqual(try JSONValue.parse(healthData)["sessions"], 1)

        var get = URLRequest(url: url)
        get.httpMethod = "GET"
        let (_, getResp) = try await session.data(for: get)
        XCTAssertEqual((getResp as! HTTPURLResponse).statusCode, 405)

        session.invalidateAndCancel()
    }

    func testPortInUseExplainsFix() async throws {
        let a = MCPServer(controller: StubPhoneController(), status: StatusModel(), log: Log(), port: 0)
        try await a.start()
        defer { a.stop() }
        let port = try XCTUnwrap(a.boundPort)
        let b = MCPServer(controller: StubPhoneController(), status: StatusModel(), log: Log(), port: port)
        do {
            try await b.start()
            b.stop()
            // SO_REUSEADDR may let some systems bind twice; nothing more to check then.
        } catch let e as OpenTapError {
            XCTAssertEqual(e.code, .network)
            XCTAssertTrue(e.what.contains("\(port)"))
            XCTAssertFalse(e.fix.isEmpty)
            if case .failed = b.state.value {} else { XCTFail("state should be failed") }
        }
    }
}
