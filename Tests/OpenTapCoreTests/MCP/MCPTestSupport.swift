import CoreGraphics
import Foundation
@testable import OpenTapCore

/// Owner: mcp. A scriptable PhoneController for MCP tests (no hardware, no mock rendering).
final class StubPhoneController: PhoneController, @unchecked Sendable {
    let lock = NSLock()
    private(set) var performed: [PhoneAction] = []
    private(set) var batches: [[PhoneAction]] = []
    var failure: OpenTapError?
    var snapshot = StatusSnapshot()
    var screenshotCalls = 0

    func shot(includeText: Bool) -> Screenshot {
        Screenshot(imageData: Data([0xFF, 0xD8, 0xFF, 0xD9]), format: .jpeg, width: 590, height: 1280, frameNumber: 7,
                   text: includeText ? [RecognizedText(text: "Settings", x: 100.4, y: 200.6, width: 80, height: 20, confidence: 1),
                                        RecognizedText(text: "Say \"hi\"", x: 50, y: 40, width: 80, height: 20, confidence: 1)] : nil)
    }

    func screenshot(includeText: Bool) async throws -> Screenshot {
        lock.withLock { screenshotCalls += 1 }
        return shot(includeText: includeText)
    }

    func perform(_ action: PhoneAction) async throws -> ActionResult {
        lock.withLock { performed.append(action) }
        if let failure { throw failure }
        return ActionResult(summary: "Did \(action.name)", screenshot: shot(includeText: true))
    }

    func performBatch(_ actions: [PhoneAction]) async throws -> ActionResult {
        lock.withLock { batches.append(actions) }
        if let failure { throw failure }
        return ActionResult(summary: "Ran \(actions.count) steps", screenshot: shot(includeText: true))
    }

    func calibrate(progress: @escaping (CalibrationProgress) -> Void) async throws -> CalibrationData {
        progress(CalibrationProgress(fraction: 0.5, message: "Halfway"))
        if let failure { throw failure }
        let c = AxisCurve(samples: [CurveSample(step: 1, pixelsPerStep: 1), CurveSample(step: 10, pixelsPerStep: 2)])
        return CalibrationData(deviceUDID: nil, screenshotSize: CGSize(width: 590, height: 1280), x: c, y: c)
    }

    func status() async -> StatusSnapshot { snapshot }
}

extension JSONValue {
    /// Convenience for tests: text of the last text content item of a CallToolResult.
    var resultText: String? {
        self["content"]?.arrayValue?.last(where: { $0["type"]?.stringValue == "text" })?["text"]?.stringValue
    }
}

enum MCPTestRequests {
    static func post(_ body: String, session: String? = nil, headers: [HTTPHeader] = []) -> HTTPRequest {
        var h = [HTTPHeader("Content-Type", "application/json"), HTTPHeader("Accept", "application/json, text/event-stream")] + headers
        if let session { h.append(HTTPHeader("Mcp-Session-Id", session)) }
        return HTTPRequest(method: "POST", target: "/mcp", headers: h, body: Data(body.utf8))
    }

    static let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
}
