import Foundation
import XCTest
@testable import PocketPilotCore

/// Owner: mcp. JSON, HTTP parsing and tool-argument parsing (no network).
final class MCPParsingTests: XCTestCase {
    // MARK: JSON

    func testJSONRoundTripAndBools() throws {
        let v = try JSONValue.parse(#"{"a":1,"b":true,"c":[null,1.5,"x\"y\n"],"d":{"e":0}}"#)
        XCTAssertEqual(v["a"], .number(1))
        XCTAssertEqual(v["b"], .bool(true))
        XCTAssertEqual(v["d"]?["e"], .number(0)) // 0 must stay a number, not false
        XCTAssertEqual(v.serializedString(), #"{"a":1,"b":true,"c":[null,1.5,"x\"y\n"],"d":{"e":0}}"#)
        XCTAssertEqual(try JSONValue.parse(v.serialized()), v)
        XCTAssertEqual(JSONValue.string("\u{01}").serializedString(), #""\u0001""#)
        XCTAssertThrowsError(try JSONValue.parse("{nope"))
    }

    // MARK: HTTP

    func testParsesContentLengthRequestInPieces() throws {
        var p = HTTPRequestParser()
        let body = #"{"jsonrpc":"2.0"}"#
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\ncontent-length: \(body.utf8.count)\r\n\r\n\(body)"
        let bytes = Array(raw.utf8)
        for (i, b) in bytes.enumerated() {
            p.append(Data([b]))
            let r = try p.next()
            if i < bytes.count - 1 { XCTAssertNil(r) } else {
                let req = try XCTUnwrap(r)
                XCTAssertEqual(req.method, "POST")
                XCTAssertEqual(req.path, "/mcp")
                XCTAssertEqual(req.header("Content-Length"), "\(body.utf8.count)")
                XCTAssertEqual(String(decoding: req.body, as: UTF8.self), body)
                XCTAssertTrue(req.keepAlive)
            }
        }
        XCTAssertEqual(p.bufferedByteCount, 0)
    }

    func testParsesPipelinedRequests() throws {
        var p = HTTPRequestParser()
        p.append("GET /health HTTP/1.1\r\nHost: x\r\n\r\nPOST /mcp HTTP/1.1\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        let a = try XCTUnwrap(p.next())
        let b = try XCTUnwrap(p.next())
        XCTAssertEqual(a.path, "/health")
        XCTAssertEqual(b.body, Data("{}".utf8))
        XCTAssertFalse(b.keepAlive)
        XCTAssertNil(try p.next())
    }

    func testParsesChunkedBody() throws {
        var p = HTTPRequestParser()
        p.append("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n")
        XCTAssertNil(try p.next())
        p.append("3;ext=1\r\n:1}\r\n0\r\n\r\n")
        let r = try XCTUnwrap(p.next())
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), #"{"a":1}"#)
    }

    func testExpectContinue() throws {
        var p = HTTPRequestParser()
        p.append("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n")
        XCTAssertNil(try p.next())
        XCTAssertTrue(p.wantsContinue)
        p.append("hello")
        XCTAssertNotNil(try p.next())
        XCTAssertFalse(p.wantsContinue)
    }

    func testHTTPErrors() {
        var a = HTTPRequestParser()
        a.append("garbage\r\n\r\n")
        XCTAssertThrowsError(try a.next()) { XCTAssertEqual(($0 as? HTTPParseError)?.status, 400) }

        var b = HTTPRequestParser(maxBodyBytes: 10)
        b.append("POST /mcp HTTP/1.1\r\nContent-Length: 11\r\n\r\n")
        XCTAssertThrowsError(try b.next()) { XCTAssertEqual(($0 as? HTTPParseError)?.status, 413) }

        var c = HTTPRequestParser()
        c.append("POST /mcp HTTP/1.1\r\nContent-Length: abc\r\n\r\n")
        XCTAssertThrowsError(try c.next()) { XCTAssertEqual(($0 as? HTTPParseError)?.status, 400) }

        var d = HTTPRequestParser()
        d.append("POST /mcp HTTP/2.0\r\n\r\n")
        XCTAssertThrowsError(try d.next()) { XCTAssertEqual(($0 as? HTTPParseError)?.status, 505) }

        var e = HTTPRequestParser(maxHeaderBytes: 32)
        e.append("GET / HTTP/1.1\r\nX-Long: " + String(repeating: "a", count: 64))
        XCTAssertThrowsError(try e.next()) { XCTAssertEqual(($0 as? HTTPParseError)?.status, 431) }
    }

    func testResponseSerialization() {
        let r = HTTPResponse.json(200, ["ok": true], headers: [HTTPHeader("Mcp-Session-Id", "abc")])
        let text = String(decoding: r.serialized(keepAlive: true), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(text.contains("Mcp-Session-Id: abc\r\n"))
        XCTAssertTrue(text.contains("Connection: keep-alive\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
        let noContent = String(decoding: HTTPResponse.empty(204).serialized(keepAlive: false), as: UTF8.self)
        XCTAssertFalse(noContent.contains("Content-Length"))
        XCTAssertTrue(noContent.contains("Connection: close"))
    }

    // MARK: Tool arguments

    func testParseActions() throws {
        XCTAssertEqual(try MCPTools.parseAction("tap", ["x": 10, "y": "20.5"]), .tap(x: 10, y: 20.5))
        XCTAssertEqual(try MCPTools.parseAction("tap_text", ["text": " Settings "]), .tapText(text: "Settings", occurrence: 1))
        XCTAssertEqual(try MCPTools.parseAction("long_press", ["x": 1, "y": 2]), .longPress(x: 1, y: 2, durationMs: 800))
        XCTAssertEqual(try MCPTools.parseAction("swipe", ["from_x": 1, "from_y": 2, "to_x": 3, "to_y": 4, "duration_ms": 600]),
                       .swipe(fromX: 1, fromY: 2, toX: 3, toY: 4, durationMs: 600))
        XCTAssertEqual(try MCPTools.parseAction("scroll", ["direction": "DOWN"]), .scroll(direction: .down, amount: 0.5))
        XCTAssertEqual(try MCPTools.parseAction("type_text", ["text": "hi there", "submit": true]), .typeText(text: "hi there", submit: true))
        XCTAssertEqual(try MCPTools.parseAction("press_key", ["key": "cmd+space"]), .pressKey(key: "cmd+space"))
        XCTAssertEqual(try MCPTools.parseAction("open_app", ["name": "Settings"]), .openApp(name: "Settings"))
    }

    func testParseActionErrorsSayWhatWhyFix() {
        func error(_ tool: String, _ args: [String: JSONValue]) -> PocketPilotError? {
            do { _ = try MCPTools.parseAction(tool, args); return nil } catch { return error as? PocketPilotError }
        }
        let missing = error("tap", ["x": 1])
        XCTAssertEqual(missing?.code, .invalidArgument)
        XCTAssertEqual(missing?.what, "Invalid value for 'y'")
        XCTAssertFalse(missing?.fix.isEmpty ?? true)
        XCTAssertEqual(error("tap", ["x": -1, "y": 1])?.what, "Invalid value for 'x'")
        XCTAssertEqual(error("tap", ["x": true, "y": 1])?.why, "It is a boolean, not a number")
        XCTAssertEqual(error("tap", ["x": 1, "y": 1, "z": 1])?.what, "Invalid value for 'z'")
        XCTAssertNotNil(error("scroll", ["direction": "sideways"]))
        XCTAssertNotNil(error("scroll", ["direction": "up", "amount": 5]))
        XCTAssertNotNil(error("long_press", ["x": 1, "y": 1, "duration_ms": 1.5]))
        XCTAssertNotNil(error("press_key", ["key": "hyper+x"]))
        XCTAssertNotNil(error("type_text", ["text": ""]))
    }

    func testParseBatch() throws {
        let actions = try MCPTools.parseBatch(["actions": [
            ["action": "tap", "x": 1, "y": 2],
            ["tool": "type_text", "arguments": ["text": "abc"]],
            ["name": "press_key", "args": ["key": "return"]],
            ["action": "open_app", "name": "Maps"],
            ["action": "wait", "ms": 250],
        ]])
        XCTAssertEqual(actions, [.tap(x: 1, y: 2), .typeText(text: "abc", submit: false), .pressKey(key: "return"),
                                 .openApp(name: "Maps"), .wait(ms: 250)])

        XCTAssertThrowsError(try MCPTools.parseBatch(["actions": []]))
        XCTAssertThrowsError(try MCPTools.parseBatch(["actions": [["action": "screenshot"]]]))
        XCTAssertThrowsError(try MCPTools.parseBatch(["actions": [["action": "tap", "x": 1]]])) {
            XCTAssertEqual(($0 as? PocketPilotError)?.what, "Invalid value for 'actions[0].y'")
        }
    }

    func testToolSchemasAreComplete() {
        let expected = ["status", "screenshot", "tap", "tap_text", "long_press", "swipe", "scroll", "type_text",
                        "press_key", "open_app", "calibrate", "batch"]
        XCTAssertEqual(MCPTools.names, expected)
        for d in MCPTools.definitions {
            XCTAssertEqual(d.inputSchema["type"], "object", d.name)
            XCTAssertNotNil(d.inputSchema["properties"]?.objectValue, d.name)
            XCTAssertFalse(d.description.isEmpty)
            for req in d.inputSchema["required"]?.arrayValue ?? [] {
                XCTAssertNotNil(d.inputSchema["properties"]?[req.stringValue ?? ""], "\(d.name) requires undeclared \(req)")
            }
        }
        XCTAssertEqual(MCPTools.definition(named: "batch")?.inputSchema["properties"]?["actions"]?["items"]?["oneOf"]?.arrayValue?.count, 9)
    }

    func testClientConfig() {
        XCTAssertEqual(MCPClientConfig.claudeCommand(), MCPDefaults.claudeAddCommand)
        XCTAssertEqual(MCPClientConfig.claudeCommand(),
                       "claude mcp add --transport http --scope user pocketpilot http://127.0.0.1:47900/mcp")
        for s in MCPClientConfig.snippets() where s.kind == "json" {
            XCTAssertNoThrow(try JSONValue.parse(s.content), s.title)
            XCTAssertTrue(s.content.contains(MCPDefaults.url))
        }
        XCTAssertEqual(MCPClientConfig.claudeArguments().last, MCPDefaults.url)
    }
}
