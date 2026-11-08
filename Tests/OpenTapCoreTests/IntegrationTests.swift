import CoreGraphics
import Foundation
import XCTest
@testable import OpenTapCore

/// Owner: qa. End-to-end tests: the real Control (HIDPhoneController + DotPointerLocator), Capture renderer,
/// Vision OCR and MCP server, all driven against the simulated iPhone (MockPhone).
///
/// When a module is still a scaffold stub (throws `.notImplemented`), its tests are skipped instead of failing,
/// unless OPENTAP_STRICT_INTEGRATION=1 (scripts/qa.sh --strict), which is what the integrator runs.
final class IntegrationTests: XCTestCase {

    static var strict: Bool { ProcessInfo.processInfo.environment["OPENTAP_STRICT_INTEGRATION"] == "1" }

    /// Runs `body`; a `.notImplemented` error becomes a skip (or a failure in strict mode).
    func pending<T>(_ module: String, _ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as OpenTapError where e.code == .notImplemented {
            if Self.strict { throw e }
            throw XCTSkip("\(module) not implemented yet: \(e.what)")
        }
    }

    struct Rig {
        let env: OpenTapEnvironment
        let phone: MockPhone
        var controller: HIDPhoneController { env.controller as! HIDPhoneController }
        var geometry: ScreenGeometry { ScreenGeometry(frameSize: phone.screenSize) }
        func screenshotPoint(_ e: MockPhone.Element) -> CGPoint { geometry.toScreenshot(e.center) }
        func element(_ text: String) -> MockPhone.Element? { phone.elements.first { $0.text == text } }
    }

    /// A started mock environment. `calibrated` seeds the exact curve so action tests don't depend on calibrate().
    func makeRig(calibrated: Bool = true, faults: [MockPhone.Fault] = [], fast: Bool = true) async throws -> Rig {
        let phone = MockPhone()
        phone.apply(faults)
        let store = InMemoryCalibrationStore(calibrated ? phone.groundTruthCalibration() : nil)
        let env = OpenTapEnvironment.mock(phone: phone, port: 0, calibrationStore: store)
        if fast, let c = env.controller as? HIDPhoneController {
            c.timing = .fast
            c.reportIntervalOverrideMs = 0
        }
        await env.device.start()
        try? await env.hid.start()
        try? await env.frames.start()
        addTeardownBlock { env.mcp.stop(); env.frames.stop(); env.hid.stop(); env.device.stop() }
        return Rig(env: env, phone: phone)
    }

    // MARK: - Pointer detection on mock frames (Control's DotPointerLocator)

    func testLocatorFindsMockPointerEverywhere() throws {
        let phone = MockPhone()
        phone.hidConnected = true
        let locator = DotPointerLocator()
        let spots = [CGPoint(x: 600, y: 1900), CGPoint(x: 40, y: 40), CGPoint(x: 200, y: 700), CGPoint(x: 1000, y: 2400),
                     CGPoint(x: 603, y: 1311)]
        for screen in [MockPhone.Screen.home, .app("Settings"), .app("Notes"), .spotlight] {
            phone.show(screen)
            for p in spots {
                phone.setPointer(p)
                let img = try XCTUnwrap(phone.render())
                let d = locator.locate(in: img, hint: nil, previous: nil)
                XCTAssertNotNil(d, "pointer not found at \(p) on \(screen)")
                if let d { XCTAssertLessThan(hypot(d.point.x - p.x, d.point.y - p.y), 8, "pointer at \(p) on \(screen) found at \(d.point)") }
            }
        }
    }

    func testLocatorWithPreviousFrameAndHint() throws {
        let phone = MockPhone()
        phone.hidConnected = true
        phone.show(.app("Settings"))
        let locator = DotPointerLocator()
        phone.setPointer(CGPoint(x: 38, y: 38))
        let before = try XCTUnwrap(phone.render())
        XCTAssertNotNil(locator.locate(in: before, hint: CGPoint(x: 72, y: 72), previous: nil), "near the corner")
        phone.setPointer(CGPoint(x: 38 + 116, y: 38))
        let after = try XCTUnwrap(phone.render())
        let d = try XCTUnwrap(locator.locate(in: after, hint: nil, previous: before), "after a 116 px move")
        XCTAssertEqual(d.point.x, 154, accuracy: 6)
        XCTAssertEqual(d.point.y, 38, accuracy: 6)
    }

    func testLocatorIgnoresAssistiveTouchButtonWhenNoPointer() throws {
        let phone = MockPhone() // hidConnected false: AT button drawn, no pointer
        let img = try XCTUnwrap(phone.render())
        let d = DotPointerLocator().locate(in: img, hint: nil, previous: nil)
        if let d {
            XCTAssertGreaterThan(hypot(d.point.x - phone.assistiveTouchButtonCenter.x, d.point.y - phone.assistiveTouchButtonCenter.y), 0,
                                 "found something; at least it must not claim high confidence on the AT button")
            XCTAssertLessThan(d.confidence, 0.5, "the AssistiveTouch button / icons were taken for the pointer at \(d.point)")
        }
    }

    // MARK: - Vision OCR on the mock render (Vision module)

    func testVisionReadsMockHomeScreen() async throws {
        let phone = MockPhone()
        let frame = try XCTUnwrap(phone.render())
        let shot = try ImageScreenshotRenderer().render(frame)
        let items = try await pending("Vision") { try await VisionTextRecognizer().recognize(in: shot.image) }
        let geo = ScreenGeometry(frameSize: phone.screenSize)
        for app in ["Settings", "Notes", "Safari", "Weather"] {
            let hit = try XCTUnwrap(items.find(app), "Vision didn't read \(app): \(items.map(\.text))")
            let e = try XCTUnwrap(phone.elements.first { $0.text == app })
            let expected = geo.toScreenshot(e.center)
            XCTAssertLessThan(hypot(hit.x - expected.x, hit.y - expected.y), 12, "\(app) at \(hit.x),\(hit.y) expected \(expected)")
        }
    }

    // MARK: - Controller against the mock

    func testScreenshotWithText() async throws {
        let rig = try await makeRig()
        let shot = try await pending("Control") { try await rig.env.controller.screenshot(includeText: true) }
        XCTAssertEqual(shot.width, 590)
        XCTAssertEqual(shot.height, 1283)
        XCTAssertNotNil(shot.text?.find("Settings"))
        XCTAssertEqual(rig.env.status.snapshot.value.screenshotWidth, 590)
    }

    func testCalibrationMatchesGroundTruth() async throws {
        let rig = try await makeRig(calibrated: false)
        var progress: [CalibrationProgress] = []
        let data = try await pending("Control") { try await rig.env.controller.calibrate { progress.append($0) } }
        XCTAssertTrue(data.x.isUsable && data.y.isUsable)
        XCTAssertEqual(try rig.env.calibrationStore.load(), data, "calibration must be saved")
        XCTAssertEqual(progress.last?.fraction ?? 0, 1, accuracy: 0.001)
        let truth = rig.phone.groundTruthCalibration()
        for step in [4, 16, 64] {
            let got = data.x.pixels(forStep: step), want = truth.x.pixels(forStep: step)
            XCTAssertEqual(got, want, accuracy: max(0.6, want * 0.15), "x curve at step \(step)")
            let gy = data.y.pixels(forStep: step)
            XCTAssertEqual(gy, want, accuracy: max(0.6, want * 0.15), "y curve at step \(step)")
        }
        XCTAssertEqual(rig.env.status.snapshot.value[.calibration].health, .ok)
    }

    func testTapLandsOnTarget() async throws {
        let rig = try await makeRig()
        let e = try XCTUnwrap(rig.element("Photos"))
        let p = rig.screenshotPoint(e)
        _ = try await pending("Control") { try await rig.env.controller.perform(.tap(x: p.x, y: p.y)) }
        guard case .tap(let at)? = rig.phone.gestures.last else { return XCTFail("no tap: \(rig.phone.gestures)") }
        XCTAssertLessThan(hypot(at.x - e.center.x, at.y - e.center.y), 12, "tap landed at \(at), wanted \(e.center)")
        XCTAssertEqual(rig.phone.screen, .app("Photos"))
    }

    func testTapAccuracyAcrossScreen() async throws {
        let rig = try await makeRig()
        rig.phone.show(.app("Clock")) // plain screen: taps do nothing
        let targets = [CGPoint(x: 30, y: 60), CGPoint(x: 560, y: 80), CGPoint(x: 295, y: 640), CGPoint(x: 40, y: 1200), CGPoint(x: 550, y: 1240)]
        for t in targets {
            _ = try await pending("Control") { try await rig.env.controller.perform(.tap(x: t.x, y: t.y)) }
            guard case .tap(let at)? = rig.phone.gestures.last else { return XCTFail("no tap for \(t)") }
            let s = rig.geometry.toScreenshot(at)
            XCTAssertLessThan(hypot(s.x - t.x, s.y - t.y), 5, "tap for \(t) landed at \(s) (screenshot px)")
        }
    }

    func testTapTextOpensAppAndReturnsFreshOCR() async throws {
        let rig = try await makeRig()
        let r = try await pending("Control") { try await rig.env.controller.perform(.tapText(text: "notes", occurrence: 1)) }
        XCTAssertEqual(rig.phone.screen, .app("Notes"))
        XCTAssertNotNil(r.screenshot.text?.find(MockPhone.notesPlaceholder), "result screenshot must be taken after the tap")
        XCTAssertFalse(r.summary.isEmpty)
    }

    func testTypeTextWithSubmit() async throws {
        let rig = try await makeRig()
        rig.phone.show(.app("Notes"))
        _ = try await pending("Control") { try await rig.env.controller.perform(.tapText(text: MockPhone.notesPlaceholder, occurrence: 1)) }
        XCTAssertTrue(rig.phone.isTextFieldFocused)
        let r = try await rig.env.controller.perform(.typeText(text: "Hi, OpenTap: 1+1=2 ~ok?", submit: true))
        XCTAssertEqual(rig.phone.notesSaved, ["Hi, OpenTap: 1+1=2 ~ok?"])
        XCTAssertNotNil(r.screenshot.text?.find("Hi, OpenTap: 1+1=2 ~ok?"))
    }

    func testTypeTextRejectsNonASCII() async throws {
        let rig = try await makeRig()
        do {
            _ = try await pending("Control") { try await rig.env.controller.perform(.typeText(text: "café", submit: false)) }
            XCTFail("non-ASCII should be rejected")
        } catch let e as OpenTapError {
            XCTAssertEqual(e.code, .invalidArgument)
            XCTAssertTrue(rig.phone.typedText.isEmpty, "nothing should be typed when the text is invalid")
        }
    }

    func testPressKeysAndOpenApp() async throws {
        let rig = try await makeRig()
        rig.phone.show(.app("Maps"))
        _ = try await pending("Control") { try await rig.env.controller.perform(.pressKey(key: "home")) }
        XCTAssertEqual(rig.phone.screen, .home)
        _ = try await rig.env.controller.perform(.pressKey(key: "cmd+space"))
        XCTAssertEqual(rig.phone.screen, .spotlight)
        _ = try await rig.env.controller.perform(.pressKey(key: "escape"))
        XCTAssertEqual(rig.phone.screen, .home)
        rig.phone.show(.app("Maps"))
        let r = try await rig.env.controller.perform(.openApp(name: "Weather"))
        XCTAssertEqual(rig.phone.screen, .app("Weather"))
        XCTAssertNotNil(r.screenshot.text?.find("Weather is open"))
    }

    func testScrollMovesSettingsList() async throws {
        let rig = try await makeRig()
        rig.phone.show(.app("Settings"))
        _ = try await pending("Control") { try await rig.env.controller.perform(.scroll(direction: .down, amount: 0.5)) }
        let down = rig.phone.settingsScroll
        XCTAssertGreaterThan(down, 300, "scroll down 0.5 should move the list a good part of a screen")
        _ = try await rig.env.controller.perform(.scroll(direction: .up, amount: 1.0))
        XCTAssertLessThan(rig.phone.settingsScroll, down)
    }

    func testSwipeFromBottomGoesHome() async throws {
        let rig = try await makeRig()
        rig.phone.show(.app("Camera"))
        _ = try await pending("Control") {
            try await rig.env.controller.perform(.swipe(fromX: 295, fromY: 1280, toX: 295, toY: 500, durationMs: 300))
        }
        guard case .swipe(let from, let to, _)? = rig.phone.gestures.last else { return XCTFail("no swipe: \(rig.phone.gestures)") }
        XCTAssertGreaterThan(from.y, 2500)
        XCTAssertLessThan(to.y, 1200)
        XCTAssertEqual(rig.phone.screen, .home)
    }

    func testLongPressOpensContextMenu() async throws {
        let rig = try await makeRig()
        let mail = try XCTUnwrap(rig.element("Mail"))
        let p = rig.screenshotPoint(mail)
        _ = try await pending("Control") { try await rig.env.controller.perform(.longPress(x: p.x, y: p.y - 20, durationMs: 700)) }
        guard case .longPress(_, let ms)? = rig.phone.gestures.last else { return XCTFail("no long press: \(rig.phone.gestures)") }
        XCTAssertGreaterThanOrEqual(ms, 600)
        XCTAssertEqual(rig.phone.contextMenuApp, "Mail")
    }

    func testBatchRunsInOrderAndReportsFailingStep() async throws {
        let rig = try await makeRig()
        let r = try await pending("Control") {
            try await rig.env.controller.performBatch([.pressKey(key: "cmd+space"), .typeText(text: "cal", submit: true), .wait(ms: 10)])
        }
        XCTAssertEqual(rig.phone.screen, .app("Calendar"))
        XCTAssertNotNil(r.screenshot.text?.find("Calendar is open"))
        do {
            _ = try await rig.env.controller.performBatch([.pressKey(key: "home"), .tapText(text: "Nope Nope", occurrence: 1), .pressKey(key: "cmd+space")])
            XCTFail("should fail at step 2")
        } catch let e as OpenTapError {
            XCTAssertTrue(e.what.hasPrefix("Step 2 (tap_text) failed"), e.what)
            XCTAssertEqual(e.code, .textNotFound)
            XCTAssertNotEqual(rig.phone.screen, .spotlight, "steps after the failure must not run")
        }
    }

    // MARK: - Error paths say what/why/fix

    func testTapTextMissing() async throws {
        let rig = try await makeRig()
        do {
            _ = try await pending("Control") { try await rig.env.controller.perform(.tapText(text: "Zebra", occurrence: 1)) }
            XCTFail("should throw")
        } catch let e as OpenTapError {
            XCTAssertEqual(e.code, .textNotFound)
            XCTAssertTrue(e.what.contains("Zebra"), e.what)
            XCTAssertFalse(e.fix.isEmpty)
        }
        do {
            _ = try await rig.env.controller.perform(.tapText(text: "Settings", occurrence: 3))
            XCTFail("only one Settings on screen")
        } catch let e as OpenTapError { XCTAssertEqual(e.code, .textNotFound) }
    }

    func testNotCalibratedError() async throws {
        let rig = try await makeRig(calibrated: false)
        do {
            _ = try await pending("Control") { try await rig.env.controller.perform(.tap(x: 100, y: 100)) }
            XCTFail("should throw")
        } catch let e as OpenTapError {
            XCTAssertEqual(e.code, .notCalibrated)
            XCTAssertTrue(e.fix.lowercased().contains("calibrat"), e.fix)
        }
        XCTAssertTrue(rig.phone.gestures.isEmpty)
    }

    func testAssistiveTouchOffIsReported() async throws {
        let rig = try await makeRig(faults: [.assistiveTouchOff])
        do {
            _ = try await pending("Control") { try await rig.env.controller.perform(.tap(x: 100, y: 100)) }
            XCTFail("tap without a pointer must fail")
        } catch let e as OpenTapError {
            XCTAssertTrue([.assistiveTouchOff, .pointerNotFound].contains(e.code), "\(e.code)")
            XCTAssertTrue(e.fix.contains("AssistiveTouch"), e.fix)
        }
        XCTAssertEqual(rig.env.status.snapshot.value[.assistiveTouch].health, .failed)
    }

    func testBluetoothNotConnectedIsReported() async throws {
        let rig = try await makeRig(faults: [.noBluetooth])
        do {
            _ = try await pending("Control") { try await rig.env.controller.perform(.pressKey(key: "home")) }
            XCTFail("should throw")
        } catch let e as OpenTapError {
            XCTAssertEqual(e.code, .hidNotConnected)
            XCTAssertTrue(e.fix.contains("Bluetooth"), e.fix)
        }
    }

    func testNoFramesIsReported() async throws {
        let rig = try await makeRig(faults: [.noFrames])
        do {
            _ = try await pending("Control") { try await rig.env.controller.screenshot(includeText: true) }
            XCTFail("should throw")
        } catch let e as OpenTapError {
            XCTAssertTrue([.noFrame, .noDevice, .timeout].contains(e.code), "\(e.code)")
            XCTAssertFalse(e.fix.isEmpty)
        }
        XCTAssertEqual(rig.env.status.snapshot.value[.screen].health, .pending)
    }

    func testLockedPhoneDoesNotPretendSuccess() async throws {
        let rig = try await makeRig(faults: [.locked])
        let r = try? await pending("Control") { try await rig.env.controller.perform(.openApp(name: "Settings")) }
        XCTAssertNotEqual(rig.phone.screen, .app("Settings"))
        if let r { XCTAssertNotNil(r.screenshot.text?.find("Swipe up to open"), "the returned screenshot must show the lock screen") }
    }

    // MARK: - MCP over HTTP

    func testMCPOverHTTP() async throws {
        let phone = MockPhone()
        let port = UInt16.random(in: 48100...48900)
        let env = OpenTapEnvironment.mock(phone: phone, port: port, calibrationStore: InMemoryCalibrationStore(phone.groundTruthCalibration()))
        (env.controller as? HIDPhoneController)?.timing = .fast
        (env.controller as? HIDPhoneController)?.reportIntervalOverrideMs = 0
        await env.device.start(); try await env.hid.start(); try await env.frames.start()
        try await pending("MCP") { try await env.mcp.start() }
        defer { env.mcp.stop(); env.frames.stop() }
        XCTAssertEqual(env.status.snapshot.value[.mcp].health, .ok)

        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        func post(_ body: [String: Any], session: String?) async throws -> (HTTPURLResponse, [String: Any]?) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let session { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as! HTTPURLResponse
            var text = String(decoding: data, as: UTF8.self)
            if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
                text = text.split(separator: "\n").first { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)) } ?? ""
            }
            let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            return (http, json)
        }

        let (initResp, initJSON) = try await post(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                   "params": ["protocolVersion": MCPDefaults.protocolVersion, "capabilities": [:],
                                                              "clientInfo": ["name": "tests", "version": "1"]]], session: nil)
        XCTAssertEqual(initResp.statusCode, 200)
        let result = try XCTUnwrap(initJSON?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, MCPDefaults.protocolVersion)
        let session = try XCTUnwrap(initResp.value(forHTTPHeaderField: "Mcp-Session-Id"))

        let (_, list) = try await post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], session: session)
        let tools = ((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        for t in ["status", "screenshot", "tap", "tap_text", "long_press", "swipe", "scroll", "type_text", "press_key", "open_app", "calibrate", "batch"] {
            XCTAssertTrue(tools.contains(t), "missing tool \(t)")
        }

        let (_, call) = try await post(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                        "params": ["name": "tap_text", "arguments": ["text": "Messages"]]], session: session)
        let callResult = try XCTUnwrap(call?["result"] as? [String: Any])
        XCTAssertEqual(callResult["isError"] as? Bool, false, "\(callResult)")
        let content = callResult["content"] as? [[String: Any]] ?? []
        XCTAssertTrue(content.contains { $0["type"] as? String == "image" }, "every action returns a screenshot")
        XCTAssertEqual(phone.screen, .app("Messages"))
    }
}
