import CoreGraphics
import Foundation
import XCTest
@testable import PocketPilotCore

/// Regression tests for the QA findings fixed in the "fixer" pass. One test (or a few) per finding.
final class FixRegressionTests: XCTestCase {

    struct Rig {
        let env: PocketPilotEnvironment
        let phone: MockPhone
        var controller: HIDPhoneController { env.controller as! HIDPhoneController }
    }

    func makeRig(calibrated: Bool = true, faults: [MockPhone.Fault] = [],
                 calibration: CalibrationData? = nil) async throws -> Rig {
        let phone = MockPhone()
        phone.apply(faults)
        let store = InMemoryCalibrationStore(calibration ?? (calibrated ? phone.groundTruthCalibration() : nil))
        let env = PocketPilotEnvironment.mock(phone: phone, port: 0, calibrationStore: store)
        let c = env.controller as! HIDPhoneController
        c.timing = .fast
        c.reportIntervalOverrideMs = 0
        await env.device.start()
        try? await env.hid.start()
        try? await env.frames.start()
        addTeardownBlock { env.mcp.stop(); env.frames.stop(); env.hid.stop(); env.device.stop() }
        return Rig(env: env, phone: phone)
    }

    // MARK: critical: huge coordinates crashed the process

    func testFmtNeverTraps() {
        XCTAssertEqual(HIDPhoneController.fmt(12), "12")
        XCTAssertEqual(HIDPhoneController.fmt(12.25), "12.2")
        XCTAssertEqual(HIDPhoneController.fmt(1e300), "1e+300")
        XCTAssertEqual(HIDPhoneController.fmt(-1e20), "-1e+20")
        XCTAssertEqual(HIDPhoneController.fmt(.infinity), "infinity")
        XCTAssertEqual(HIDPhoneController.fmt(.nan), "NaN")
    }

    func testHugeTapCoordinateIsAnErrorNotACrash() async throws {
        let rig = try await makeRig()
        // Straight to the controller (no MCP cap): must throw invalidArgument, not trap in Int(v).
        for (x, y) in [(1e300, 5.0), (5.0, 1e20), (1e19, 1e19)] {
            do {
                _ = try await rig.env.controller.perform(.tap(x: x, y: y))
                XCTFail("should throw for (\(x), \(y))")
            } catch let e as PocketPilotError {
                XCTAssertEqual(e.code, .invalidArgument)
            }
        }
        // And MCP rejects it before it reaches the controller.
        XCTAssertThrowsError(try MCPTools.parseAction("tap", ["x": .number(1e300), "y": .number(5)])) { err in
            let e = err as! PocketPilotError
            XCTAssertEqual(e.what, "Invalid value for 'x'")
            XCTAssertTrue(e.why.contains("far outside"), e.why)
        }
    }

    // MARK: medium: stale frame after unplug / capture error

    func testScreenshotRefusesStaleFrameWhenCaptureIsNotRunning() async throws {
        let rig = try await makeRig()
        _ = try await rig.env.controller.screenshot(includeText: false)
        rig.env.frames.state.send(.waitingForDevice)   // unplugged; a source may still hold the last picture
        do {
            _ = try await rig.env.controller.screenshot(includeText: false)
            XCTFail("a stale frame must not be served as live")
        } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .noFrame)
            XCTAssertTrue(e.fix.contains("Plug"), e.fix)
        }
        let failure = PocketPilotError(.captureFailed, what: "The iPhone screen capture stopped", why: "x", fix: "Replug")
        rig.env.frames.state.send(.failed(failure))
        do {
            _ = try await rig.env.controller.perform(.tap(x: 10, y: 10))
            XCTFail("should throw")
        } catch let e as PocketPilotError {
            XCTAssertEqual(e, failure)
        }
    }

    // MARK: medium: open_app reported success for a missing app

    func testOpenAppFailsWhenSpotlightFindsNothing() async throws {
        let rig = try await makeRig()
        do {
            _ = try await rig.env.controller.perform(.openApp(name: "NoSuchAppXYZ"))
            XCTFail("should throw")
        } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .appNotOpened)
            XCTAssertEqual(e.what, "Couldn't open \"NoSuchAppXYZ\"")
            XCTAssertTrue(e.fix.contains("exact name"), e.fix)
        }
        // A real app still opens fine.
        let r = try await rig.env.controller.perform(.openApp(name: "Weather"))
        XCTAssertEqual(rig.phone.screen, .app("Weather"))
        XCTAssertTrue(r.summary.contains("Opened"))
    }

    func testOpenAppFailureInsideBatchStopsAtThatStep() async throws {
        let rig = try await makeRig()
        do {
            _ = try await rig.env.controller.performBatch([.openApp(name: "NoSuchAppXYZ"), .typeText(text: "hi", submit: false)])
            XCTFail("should throw")
        } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .appNotOpened)
            XCTAssertTrue(e.what.hasPrefix("Step 1 (open_app) failed"), e.what)
        }
    }

    // MARK: medium: locked iPhone, input reported as success

    func testLockedPhoneFailsKeyboardAndTapsWithUnlockFix() async throws {
        let rig = try await makeRig(faults: [.locked])
        for action in [PhoneAction.typeText(text: "hi", submit: false), .pressKey(key: "home"), .tap(x: 100, y: 200)] {
            do {
                _ = try await rig.env.controller.perform(action)
                XCTFail("\(action.name) should fail on the Lock Screen")
            } catch let e as PocketPilotError {
                XCTAssertEqual(e.code, .deviceLocked, "\(action.name): \(e)")
                XCTAssertTrue(e.fix.contains("Unlock the iPhone"), e.fix)
            }
        }
        // status says so (Screen pill), and recovers once unlocked.
        XCTAssertEqual(rig.env.status.snapshot.value[.screen].error?.code, .deviceLocked)
        XCTAssertTrue(MCPHandler.statusText(rig.env.status.snapshot.value, url: "u").contains("locked"))
        rig.phone.isLocked = false
        _ = try await rig.env.controller.screenshot(includeText: true)
        XCTAssertEqual(rig.env.status.snapshot.value[.screen].health, .ok)
        _ = try await rig.env.controller.perform(.typeText(text: "", submit: true))
    }

    func testLockHeuristics() {
        func t(_ s: String, y: Double = 100, h: Double = 20) -> RecognizedText {
            RecognizedText(text: s, x: 295, y: y, width: 100, height: h, confidence: 1)
        }
        XCTAssertEqual(ScreenHeuristics.lockSignal([t("9:41"), t("Swipe up to open", y: 1200)], screenHeight: 1280), .certain)
        XCTAssertEqual(ScreenHeuristics.lockSignal([t("Sunday, November 8", y: 120), t("9:41", y: 230, h: 110)], screenHeight: 1280), .likely)
        // Home screen: small status-bar clock, no date line.
        XCTAssertEqual(ScreenHeuristics.lockSignal([t("9:41", y: 20, h: 14), t("Settings"), t("Weather")], screenHeight: 1280), .none)
        // Timer app: big digits but no weekday.
        XCTAssertEqual(ScreenHeuristics.lockSignal([t("4:59", y: 300, h: 120)], screenHeight: 1280), .none)
        // Passcode screen: input works there, so not "locked".
        XCTAssertEqual(ScreenHeuristics.lockSignal([t("Enter Passcode"), t("Swipe up to open")], screenHeight: 1280), .none)
        XCTAssertTrue(ScreenHeuristics.spotlightStillOpen([t("NoSuchApp"), t("Top Hits")], query: "NoSuchApp"))
        XCTAssertFalse(ScreenHeuristics.spotlightStillOpen([t("Settings"), t("General")], query: "Settings"))
    }

    // MARK: medium: read-only tools waited behind calibrate

    func testStatusAndScreenshotDoNotWaitForALongAction() async throws {
        let slow = SlowController()
        let handler = MCPHandler(controller: slow, status: StatusModel(), log: Log())
        let long = Task { await handler.callTool("calibrate", arguments: [:]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = Date()
        let status = await handler.callTool("status", arguments: [:])
        let shot = await handler.callTool("screenshot", arguments: ["include_text": false])
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "status/screenshot queued behind calibrate")
        XCTAssertEqual(status["isError"], false)
        XCTAssertTrue(status.resultText?.hasPrefix("Busy: running calibrate") ?? false, status.resultText ?? "")
        XCTAssertEqual(shot["isError"], false)
        slow.release()
        _ = await long.value
    }

    // MARK: low: status header

    func testStatusHeadlineWithOnlyUnverifiedAssistiveTouch() {
        var s = StatusSnapshot()
        s[.screen] = .ok("Live"); s[.bluetooth] = .ok("Connected"); s[.calibration] = .ok("Calibrated")
        XCTAssertTrue(MCPHandler.statusHeadline(s).hasPrefix("Probably ready: AssistiveTouch not verified yet"), MCPHandler.statusHeadline(s))
        s[.bluetooth] = .pending("Pair")
        XCTAssertEqual(MCPHandler.statusHeadline(s), "Not ready: fix Bluetooth (marked FAILED or PENDING below).")
        s[.bluetooth] = .ok("Connected"); s[.assistiveTouch] = .ok("Pointer visible")
        XCTAssertEqual(MCPHandler.statusHeadline(s), "Ready: PocketPilot can control the iPhone.")
    }

    // MARK: low: batch press_key validation lost the step

    func testBatchKeyErrorNamesTheStep() throws {
        let args: [String: JSONValue] = ["actions": [["action": "tap_text", "text": "Settings"], ["action": "wait", "ms": 300],
                                                     ["action": "press_key", "key": "bogus"]]]
        XCTAssertThrowsError(try MCPTools.parseBatch(args)) { err in
            let e = err as! PocketPilotError
            XCTAssertEqual(e.what, "Invalid value for 'actions[2].key'")
            XCTAssertTrue(e.why.hasPrefix("Step 3 (no steps were run): "), e.why)
        }
        XCTAssertThrowsError(try MCPTools.parseAction("press_key", ["key": "bogus"])) { err in
            XCTAssertEqual((err as! PocketPilotError).what, "Invalid value for 'key'")
        }
    }

    // MARK: low: id null accepted

    func testNullIDIsRejected() async throws {
        let handler = MCPHandler(controller: StubPhoneController(), status: StatusModel(), log: Log())
        let msg = await handler.handleMessage(["jsonrpc": "2.0", "id": .null, "method": "ping"], sessionID: nil)
        let r = try XCTUnwrap(msg)
        XCTAssertEqual(r["error"]?["code"], .number(-32600))
        XCTAssertTrue(r["error"]?["data"]?["why"]?.stringValue?.contains("null") ?? false)
    }

    // MARK: medium: calibration from another iPhone counted as done

    func testCalibrationForAnotherIPhoneIsPending() async throws {
        let phone = MockPhone()
        var cal = phone.groundTruthCalibration()
        cal.deviceUDID = "some-other-iphone"
        let rig = try await makeRig(calibration: cal)
        try await waitUntil { rig.env.status.snapshot.value.device != nil }
        let st = rig.env.status.snapshot.value[.calibration]
        XCTAssertEqual(st.health, .pending)
        XCTAssertTrue(st.detail.contains("another iPhone"), st.detail)
    }

    func testMatchingCalibrationIsOk() async throws {
        let rig = try await makeRig()
        try await waitUntil { rig.env.status.snapshot.value.device != nil }
        XCTAssertEqual(rig.env.status.snapshot.value[.calibration].health, .ok)
    }

    // MARK: high: pointer probe runs through the gate; no new frame = no pointer

    func testProbePointer() async throws {
        let rig = try await makeRig()
        rig.phone.show(.app("Settings"))
        let found = try await rig.env.controller.probePointer(dx: 24)
        XCTAssertNotNil(found)
        XCTAssertEqual(rig.env.status.snapshot.value[.assistiveTouch].health, .ok)

        let off = try await makeRig(faults: [.assistiveTouchOff])
        let none = try await off.env.controller.probePointer(dx: 24)
        XCTAssertNil(none)

        // Frames stop after the move (a still iPhone screen only sends frames on change): nil, not a USB error.
        let frozen = try await makeRig()
        _ = try await frozen.env.controller.screenshot(includeText: false)
        frozen.phone.framesFrozen = true
        let still = try await frozen.env.controller.probePointer(dx: 24)
        XCTAssertNil(still)
    }

    // MARK: low: claude mcp get parsing (AgentSetup's replace-on-different-URL)

    func testParseClaudeGet() {
        let out = """
        pocketpilot:
          Scope: User config (available in all your projects)
          Status: ✘ Failed to connect
          Type: http
          URL: http://127.0.0.1:9999/mcp

        To remove this server, run: claude mcp remove pocketpilot -s user
        """
        let r = MCPClientConfig.parseClaudeGet(out)
        XCTAssertEqual(r, MCPClientConfig.ClaudeRegistration(url: "http://127.0.0.1:9999/mcp", scope: "user"))
        XCTAssertNil(MCPClientConfig.parseClaudeGet("No MCP server named \"pocketpilot\". Run `claude mcp add` to add one."))
        XCTAssertFalse(MCPClientConfig.sameEndpoint("http://127.0.0.1:9999/mcp", MCPDefaults.url))
        XCTAssertTrue(MCPClientConfig.sameEndpoint("http://localhost:47900/mcp/", "http://127.0.0.1:47900/mcp"))
    }

    // MARK: helpers

    func waitUntil(timeout: TimeInterval = 2, _ cond: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            guard Date() < deadline else { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// calibrate blocks until released; everything else is instant.
private final class SlowController: PhoneController, @unchecked Sendable {
    private let stub = StubPhoneController()
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func release() {
        lock.lock(); released = true; let w = waiter; waiter = nil; lock.unlock()
        w?.resume()
    }

    func screenshot(includeText: Bool) async throws -> Screenshot { try await stub.screenshot(includeText: includeText) }
    func perform(_ action: PhoneAction) async throws -> ActionResult { try await stub.perform(action) }
    func performBatch(_ actions: [PhoneAction]) async throws -> ActionResult { try await stub.performBatch(actions) }
    func calibrate(progress: @escaping (CalibrationProgress) -> Void) async throws -> CalibrationData {
        progress(CalibrationProgress(fraction: 0.57, message: "Measuring"))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released { lock.unlock(); c.resume(); return }
            waiter = c
            lock.unlock()
        }
        return try await stub.calibrate(progress: { _ in })
    }
    func status() async -> StatusSnapshot { await stub.status() }
}
