import CoreGraphics
import XCTest
@testable import OpenTapCore

/// Owner: qa. The simulated iPhone itself: rendering, acceleration, gestures, keyboard, faults, Mock* components.
/// These need nothing from other modules and must always pass.
final class MockDeviceTests: XCTestCase {

    // MARK: helpers

    private func click(_ phone: MockPhone, at p: CGPoint, holdMs: Int = 0) {
        let t0 = Date()
        var now = t0
        phone.clock = { now }
        phone.setPointer(p)
        phone.receive(.mouse(MouseReport(buttons: .left)))
        now = t0.addingTimeInterval(Double(holdMs) / 1000)
        phone.receive(.mouse(MouseReport(buttons: [])))
    }

    private func drag(_ phone: MockPhone, from a: CGPoint, by d: CGPoint, steps: Int = 10) {
        phone.setPointer(a)
        phone.receive(.mouse(MouseReport(buttons: .left)))
        // Move with small reports; unit size chosen from the inverse of the linear term.
        var moved = CGPoint.zero
        for i in 1...steps {
            let target = CGPoint(x: d.x * CGFloat(i) / CGFloat(steps), y: d.y * CGFloat(i) / CGFloat(steps))
            let ux = units(for: target.x - moved.x, phone), uy = units(for: target.y - moved.y, phone)
            phone.receive(.mouse(MouseReport(buttons: .left, dx: ux, dy: uy)))
            moved.x += CGFloat(phone.pixels(forUnits: Int(ux))); moved.y += CGFloat(phone.pixels(forUnits: Int(uy)))
        }
        phone.receive(.mouse(MouseReport(buttons: [])))
    }

    /// Smallest unit count whose movement is closest to `px` (search, since the curve is nonlinear).
    private func units(for px: CGFloat, _ phone: MockPhone) -> Int8 {
        let sign: Int = px < 0 ? -1 : 1
        var best = 0
        for u in 0...127 where abs(phone.pixels(forUnits: u) - Double(abs(px))) < abs(phone.pixels(forUnits: best) - Double(abs(px))) { best = u }
        return Int8(sign * best)
    }

    private func type(_ phone: MockPhone, _ text: String) throws {
        for s in try USKeyboardLayout.strokes(for: text) {
            phone.receive(.keyboard(KeyboardReport(modifiers: s.modifiers, keys: [s.usage])))
            phone.receive(.keyboard(.released))
        }
    }

    private func press(_ phone: MockPhone, _ combo: String) throws {
        let c = try KeyCombo.parse(combo)
        switch c.target {
        case .key(let u):
            phone.receive(.keyboard(KeyboardReport(modifiers: c.modifiers, keys: [u])))
            phone.receive(.keyboard(.released))
        case .consumer(let u):
            phone.receive(.consumer(ConsumerReport(usage: u)))
            phone.receive(.consumer(.released))
        }
    }

    private func element(_ phone: MockPhone, _ text: String) -> MockPhone.Element? { phone.elements.first { $0.text == text } }

    private func pixel(_ img: CGImage, _ p: CGPoint) -> (r: Int, g: Int, b: Int) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var buf = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw so that image pixel (p.x, p.y) [top-left origin] lands on the single destination pixel.
        ctx.draw(img, in: CGRect(x: -p.x, y: -(CGFloat(img.height) - 1 - p.y), width: CGFloat(img.width), height: CGFloat(img.height)))
        return (Int(buf[0]), Int(buf[1]), Int(buf[2]))
    }

    // MARK: rendering

    func testRendersFullResolutionHomeScreen() throws {
        let phone = MockPhone()
        let img = try XCTUnwrap(phone.render())
        XCTAssertEqual(img.width, 1206)
        XCTAssertEqual(img.height, 2622)
        XCTAssertEqual(phone.screen, .home)
        for app in MockPhone.homeApps { XCTAssertNotNil(element(phone, app), app) }
        XCTAssertTrue(phone.render() === img, "render should be cached while nothing changes")
    }

    func testPointerDrawnOnlyWithAssistiveTouchAndHID() throws {
        let phone = MockPhone()
        let spot = CGPoint(x: 600, y: 1900) // plain wallpaper area
        phone.setPointer(spot)
        let bg = pixel(try XCTUnwrap(phone.render()), spot)
        phone.hidConnected = true
        let withPointer = pixel(try XCTUnwrap(phone.render()), spot)
        XCTAssertGreaterThan(abs(withPointer.r - bg.r) + abs(withPointer.g - bg.g) + abs(withPointer.b - bg.b), 60,
                             "pointer should be visibly different from the wallpaper")
        XCTAssertLessThan(abs(withPointer.r - withPointer.g) + abs(withPointer.g - withPointer.b), 60, "pointer should be grey-ish")
        phone.assistiveTouchEnabled = false
        XCTAssertEqual(pixel(try XCTUnwrap(phone.render()), spot).r, bg.r)
    }

    // MARK: pointer motion

    func testAccelerationIsNonlinearAndMonotonic() {
        let phone = MockPhone()
        var last = 0.0
        for u in 1...127 {
            let px = phone.pixels(forUnits: u)
            XCTAssertGreaterThan(px, last); last = px
            XCTAssertEqual(phone.pixels(forUnits: -u), -px)
        }
        XCTAssertGreaterThan(phone.pixels(forUnits: 100) / 100, 1.5 * phone.pixels(forUnits: 2) / 2, "per-unit gain should grow with speed")
    }

    func testPointerMovesAndClampsToEdges() {
        let phone = MockPhone()
        phone.hidConnected = true
        phone.setPointer(CGPoint(x: 500, y: 500))
        phone.receive(.mouse(MouseReport(dx: 10, dy: -10)))
        XCTAssertEqual(phone.pointer.x, 500 + CGFloat(phone.pixels(forUnits: 10)), accuracy: 0.001)
        XCTAssertEqual(phone.pointer.y, 500 - CGFloat(phone.pixels(forUnits: 10)), accuracy: 0.001)
        for _ in 0..<30 { phone.receive(.mouse(MouseReport(dx: -127, dy: -127))) }
        XCTAssertEqual(phone.pointer, .zero, "parking in the top-left corner")
        for _ in 0..<30 { phone.receive(.mouse(MouseReport(dx: 127, dy: 127))) }
        XCTAssertEqual(phone.pointer, CGPoint(x: 1205, y: 2621))
    }

    func testMouseIgnoredWhenAssistiveTouchOff() {
        let phone = MockPhone()
        phone.apply([.assistiveTouchOff])
        let p = phone.pointer
        phone.receive(.mouse(MouseReport(dx: 50)))
        XCTAssertEqual(phone.pointer, p)
        XCTAssertEqual(phone.ignoredMouseReports, 1)
    }

    func testGroundTruthCalibrationMatchesCurve() {
        let phone = MockPhone()
        let cal = phone.groundTruthCalibration()
        XCTAssertTrue(cal.x.isUsable)
        XCTAssertEqual(cal.screenshotSize.width, 590)
        XCTAssertEqual(cal.x.pixels(forStep: 64), phone.pixels(forUnits: 64) * 590 / 1206, accuracy: 0.01)
    }

    // MARK: gestures

    func testTapOpensAppAndRecordsGesture() throws {
        let phone = MockPhone()
        let settings = try XCTUnwrap(element(phone, "Settings"))
        click(phone, at: settings.center)
        XCTAssertEqual(phone.screen, .app("Settings"))
        XCTAssertEqual(phone.lastTapped, "Settings")
        XCTAssertEqual(phone.gestures, [.tap(settings.center)])
        XCTAssertNotNil(element(phone, "Airplane Mode"))
    }

    func testTapOnIconImageAlsoOpensApp() throws {
        let phone = MockPhone()
        let icon = phone.homeIconRect(MockPhone.homeApps.firstIndex(of: "Safari")!)
        click(phone, at: CGPoint(x: icon.midX, y: icon.midY))
        XCTAssertEqual(phone.screen, .app("Safari"))
        XCTAssertNotNil(element(phone, "Safari is open"))
    }

    func testLongPressShowsContextMenu() throws {
        let phone = MockPhone()
        let mail = try XCTUnwrap(element(phone, "Mail"))
        click(phone, at: mail.center, holdMs: 800)
        guard case .longPress(_, let ms)? = phone.gestures.last else { return XCTFail("no long press: \(phone.gestures)") }
        XCTAssertEqual(ms, 800)
        XCTAssertEqual(phone.contextMenuApp, "Mail")
        XCTAssertNotNil(element(phone, "Edit Home Screen"))
        click(phone, at: CGPoint(x: 600, y: 2400)) // empty area dismisses
        XCTAssertNil(phone.contextMenuApp)
        XCTAssertEqual(phone.screen, .home)
    }

    func testSettingsScrollsByDragAndWheel() throws {
        let phone = MockPhone()
        phone.show(.app("Settings"))
        XCTAssertNil(element(phone, "Developer"))
        drag(phone, from: CGPoint(x: 600, y: 2200), by: CGPoint(x: 0, y: -1500))
        guard case .swipe? = phone.gestures.last else { return XCTFail("drag should be a swipe: \(phone.gestures)") }
        XCTAssertGreaterThan(phone.settingsScroll, 1000)
        XCTAssertNil(element(phone, "Airplane Mode"))
        for _ in 0..<200 { phone.receive(.mouse(MouseReport(wheel: -5))) }
        XCTAssertEqual(phone.settingsScroll, phone.maxSettingsScroll)
        XCTAssertNotNil(element(phone, "Developer"))
        for _ in 0..<200 { phone.receive(.mouse(MouseReport(wheel: 5))) }
        XCTAssertEqual(phone.settingsScroll, 0)
        XCTAssertNotNil(element(phone, "Airplane Mode"))
    }

    func testSettingsRowAndBack() throws {
        let phone = MockPhone()
        phone.show(.app("Settings"))
        click(phone, at: try XCTUnwrap(element(phone, "General")).center)
        XCTAssertEqual(phone.screen, .settingsDetail("General"))
        click(phone, at: try XCTUnwrap(element(phone, "< Settings")).center)
        XCTAssertEqual(phone.screen, .app("Settings"))
        phone.show(.settingsDetail("Wi-Fi"))
        drag(phone, from: CGPoint(x: 10, y: 1300), by: CGPoint(x: 600, y: 0))
        XCTAssertEqual(phone.screen, .app("Settings"), "left-edge swipe goes back")
    }

    func testSwipeUpFromBottomGoesHome() {
        let phone = MockPhone()
        phone.show(.app("Maps"))
        drag(phone, from: CGPoint(x: 600, y: 2615), by: CGPoint(x: 0, y: -1200))
        XCTAssertEqual(phone.screen, .home)
    }

    func testSwipeDownOnHomeOpensSpotlight() {
        let phone = MockPhone()
        drag(phone, from: CGPoint(x: 600, y: 1300), by: CGPoint(x: 0, y: 600))
        XCTAssertEqual(phone.screen, .spotlight)
    }

    // MARK: keyboard

    func testSpotlightTypeAndReturnOpensApp() throws {
        let phone = MockPhone()
        try press(phone, "cmd+space")
        XCTAssertEqual(phone.screen, .spotlight)
        XCTAssertTrue(phone.isTextFieldFocused)
        try type(phone, "Wea")
        XCTAssertEqual(phone.spotlightQuery, "Wea")
        XCTAssertNotNil(element(phone, "Weather"))
        try press(phone, "backspace")
        XCTAssertEqual(phone.spotlightQuery, "We")
        try press(phone, "return")
        XCTAssertEqual(phone.screen, .app("Weather"))
    }

    func testSpotlightEscapeReturnsToPreviousScreen() throws {
        let phone = MockPhone()
        phone.show(.app("Clock"))
        try press(phone, "cmd+space")
        try press(phone, "escape")
        XCTAssertEqual(phone.screen, .app("Clock"))
    }

    func testHomeKeysGoHome() throws {
        let phone = MockPhone()
        phone.show(.app("Music"))
        try press(phone, "home")
        XCTAssertEqual(phone.screen, .home)
        phone.show(.app("Music"))
        try press(phone, "cmd+h")
        XCTAssertEqual(phone.screen, .home)
    }

    func testNotesTypingNeedsFocusAndSubmitSaves() throws {
        let phone = MockPhone()
        phone.show(.app("Notes"))
        try type(phone, "lost")
        XCTAssertEqual(phone.droppedKeystrokes, 4, "typing with no focused field goes nowhere")
        click(phone, at: try XCTUnwrap(element(phone, MockPhone.notesPlaceholder)).center)
        XCTAssertTrue(phone.isTextFieldFocused)
        try type(phone, "Hi there! #1 (ok?)")
        XCTAssertEqual(phone.notesDraft, "Hi there! #1 (ok?)")
        XCTAssertNotNil(element(phone, "Hi there! #1 (ok?)"))
        try press(phone, "return")
        XCTAssertEqual(phone.notesSaved, ["Hi there! #1 (ok?)"])
        XCTAssertEqual(phone.notesDraft, "")
    }

    func testRepeatedLettersNeedRelease() {
        let phone = MockPhone()
        phone.show(.spotlight)
        let l = KeyboardReport(keys: [KeyUsage.a + 11]) // "l"
        phone.receive(.keyboard(l)); phone.receive(.keyboard(l)) // held: one keydown
        phone.receive(.keyboard(.released)); phone.receive(.keyboard(l))
        XCTAssertEqual(phone.spotlightQuery, "ll")
    }

    func testLockedPhoneIgnoresInput() throws {
        let phone = MockPhone()
        phone.apply([.locked])
        XCTAssertNotNil(element(phone, "Swipe up to open"))
        XCTAssertNil(element(phone, "Settings"))
        try press(phone, "cmd+space")
        click(phone, at: CGPoint(x: 150, y: 600))
        XCTAssertEqual(phone.screen, .home)
        phone.isLocked = false
        XCTAssertNotNil(element(phone, "Settings"))
    }

    // MARK: faults

    func testFaultParsing() throws {
        XCTAssertEqual(try MockPhone.Fault.parse("locked, at-off"), [.locked, .assistiveTouchOff])
        XCTAssertEqual(try MockPhone.Fault.parse(""), [])
        XCTAssertThrowsError(try MockPhone.Fault.parse("locked,explode")) { e in
            let err = e as? OpenTapError
            XCTAssertEqual(err?.code, .invalidArgument)
            XCTAssertTrue(err?.fix.contains("at-off") ?? false, "fix should list the valid faults")
        }
    }

    // MARK: Mock components

    func testFrameSourceTicksAndFollowsFaults() async throws {
        let phone = MockPhone()
        let frames = MockFrameSource(phone: phone)
        XCTAssertNil(frames.latestFrame)
        try await frames.start()
        XCTAssertEqual(frames.state.value, .running(deviceName: "Mock iPhone"))
        let n = frames.frameCount
        let img = try await frames.waitForFrame(after: n, timeout: 1)
        XCTAssertEqual(img.width, 1206)
        XCTAssertEqual(frames.frameSize, CGSize(width: 1206, height: 2622))

        phone.framesEnabled = false
        XCTAssertEqual(frames.state.value, .waitingForDevice)
        XCTAssertNil(frames.latestFrame)
        phone.framesEnabled = true
        XCTAssertEqual(frames.state.value, .running(deviceName: "Mock iPhone"))

        phone.framesFrozen = true
        try? await Task.sleep(nanoseconds: 50_000_000)
        do {
            _ = try await frames.waitForFrame(after: frames.frameCount, timeout: 0.2)
            XCTFail("frozen stream should time out")
        } catch let e as OpenTapError { XCTAssertEqual(e.code, .timeout) }
        frames.stop()
        XCTAssertEqual(frames.state.value, .idle)
    }

    func testFrameSourceCaptureFailure() async {
        let phone = MockPhone()
        phone.apply([.captureFails])
        let frames = MockFrameSource(phone: phone)
        do { try await frames.start(); XCTFail("should throw") } catch let e as OpenTapError {
            XCTAssertEqual(e.code, .captureFailed)
            guard case .failed = frames.state.value else { return XCTFail("state \(frames.state.value)") }
        } catch { XCTFail("\(error)") }
    }

    func testHIDTransportConnectsAndDelivers() async throws {
        let phone = MockPhone()
        let hid = MockHIDTransport(phone: phone)
        do { try await hid.send(.mouse(MouseReport(dx: 1))); XCTFail("not started") } catch let e as OpenTapError {
            XCTAssertEqual(e.code, .hidNotConnected)
            XCTAssertTrue(e.fix.contains("Bluetooth"))
        }
        try await hid.start()
        XCTAssertTrue(hid.state.value.isConnected)
        XCTAssertTrue(phone.hidConnected)
        try await hid.send(.consumer(ConsumerReport(usage: ConsumerUsage.acHome)))
        XCTAssertEqual(phone.receivedReports.count, 1)

        phone.bluetoothAccepts = false // iPhone walks away
        XCTAssertEqual(hid.state.value, .advertising(name: "OpenTap"))
        XCTAssertFalse(phone.hidConnected)
        phone.bluetoothAccepts = true
        XCTAssertTrue(hid.state.value.isConnected)
        hid.stop()
        XCTAssertEqual(hid.state.value, .off)
    }

    func testHIDTransportNoBluetoothAndOff() async throws {
        let phone = MockPhone()
        phone.apply([.noBluetooth])
        let hid = MockHIDTransport(phone: phone)
        try await hid.start()
        XCTAssertEqual(hid.state.value, .advertising(name: "OpenTap"))

        let phone2 = MockPhone()
        phone2.apply([.bluetoothOff])
        let hid2 = MockHIDTransport(phone: phone2)
        do { try await hid2.start(); XCTFail("should throw") } catch let e as OpenTapError {
            XCTAssertEqual(e.code, .bluetoothUnavailable)
            guard case .unavailable = hid2.state.value else { return XCTFail("state \(hid2.state.value)") }
        }
    }

    func testDeviceLinkPairingFlows() async throws {
        // Locked + untrusted: pairing must say "unlock".
        let phone = MockPhone()
        phone.apply([.untrusted, .locked])
        let link = MockDeviceLink(phone: phone, trustDelay: 0)
        await link.start()
        XCTAssertEqual(link.state.value, .attached(phone.deviceInfo, trust: .locked))
        do { try await link.pair(); XCTFail("locked") } catch let e as OpenTapError { XCTAssertEqual(e.code, .deviceLocked) }
        phone.isLocked = false
        phone.trust = .notPaired
        let before = try await link.isPaired()
        XCTAssertFalse(before)
        try await link.pair()
        let after = try await link.isPaired()
        XCTAssertTrue(after)
        XCTAssertEqual(link.state.value, .attached(phone.deviceInfo, trust: .paired))

        // Don't Trust.
        let p2 = MockPhone()
        p2.apply([.denyTrust])
        let l2 = MockDeviceLink(phone: p2, trustDelay: 0)
        await l2.start()
        do { try await l2.pair(); XCTFail("denied") } catch let e as OpenTapError { XCTAssertEqual(e.code, .notPaired) }
        XCTAssertEqual(l2.state.value, .attached(p2.deviceInfo, trust: .denied))
    }

    func testDeviceLinkAttachDetachAndFramework() async throws {
        let phone = MockPhone()
        phone.apply([.noUSB])
        let link = MockDeviceLink(phone: phone)
        await link.start()
        XCTAssertEqual(link.state.value, .noDevice)
        do { _ = try await link.isPaired(); XCTFail("no device") } catch let e as OpenTapError { XCTAssertEqual(e.code, .noDevice) }
        phone.usbAttached = true
        XCTAssertEqual(link.state.value.device, phone.deviceInfo)
        phone.mobileDeviceAvailable = false
        guard case .unavailable(let e) = link.state.value else { return XCTFail("state \(link.state.value)") }
        XCTAssertTrue(e.fix.contains("AssistiveTouch"), "unavailable must give the manual steps")
    }

    func testDeviceLinkAssistiveTouch() async throws {
        let phone = MockPhone()
        phone.apply([.assistiveTouchOff])
        let link = MockDeviceLink(phone: phone)
        await link.start()
        let at = try await link.assistiveTouchEnabled()
        XCTAssertFalse(at)
        try await link.setAssistiveTouch(true)
        XCTAssertTrue(phone.assistiveTouchEnabled)

        phone.assistiveTouchSettableOverUSB = false
        do { try await link.setAssistiveTouch(false); XCTFail("blocked") } catch let e as OpenTapError {
            XCTAssertEqual(e.code, .frameworkUnavailable)
            XCTAssertTrue(e.fix.contains("Settings > Accessibility > Touch > AssistiveTouch"))
        }
        phone.trust = .notPaired
        do { _ = try await link.assistiveTouchEnabled(); XCTFail("untrusted") } catch let e as OpenTapError {
            XCTAssertEqual(e.code, .notPaired)
        }
    }

    func testMockTextRecognizerScalesToImage() async throws {
        let phone = MockPhone()
        let img = try XCTUnwrap(phone.render())
        let small = try ImageScreenshotRenderer.scale(img, to: CGSize(width: 590, height: 1283))
        let items = try await MockTextRecognizer(phone: phone).recognize(in: small)
        let settings = try XCTUnwrap(items.find("settings"))
        let e = try XCTUnwrap(element(phone, "Settings"))
        XCTAssertEqual(settings.x, Double(e.center.x) * 590 / 1206, accuracy: 0.5)
        XCTAssertEqual(settings.y, Double(e.center.y) * 1283 / 2622, accuracy: 0.5)
        XCTAssertGreaterThan(settings.width, 10)
    }

    func testMockPermissions() async {
        let perms = MockPermissions([.camera: .notDetermined, .bluetooth: .denied])
        let cam = await perms.request(.camera), bt = await perms.request(.bluetooth)
        XCTAssertEqual(cam, .granted)
        XCTAssertEqual(bt, .denied)
        perms.openSettings(.bluetooth)
        XCTAssertEqual(perms.openedSettings, [.bluetooth])
    }

    func testEnvironmentStatusFollowsMockFaults() async throws {
        let env = OpenTapEnvironment.mock(port: 0)
        let phone = try XCTUnwrap(env.mockPhone)
        await env.device.start()
        try await env.hid.start()
        try await env.frames.start()
        let s = env.status.snapshot.value
        XCTAssertEqual(s[.usb].health, .ok)
        XCTAssertEqual(s[.screen].health, .ok)
        XCTAssertEqual(s[.bluetooth].health, .ok)
        XCTAssertEqual(s.device?.name, "Mock iPhone")

        phone.usbAttached = false
        XCTAssertEqual(env.status.snapshot.value[.usb].health, .pending)
        XCTAssertEqual(env.status.snapshot.value[.screen].health, .pending)
        phone.usbAttached = true
        phone.bluetoothAccepts = false
        XCTAssertEqual(env.status.snapshot.value[.bluetooth].health, .pending)
        XCTAssertTrue(env.status.snapshot.value[.bluetooth].detail.contains("OpenTap"))
        env.frames.stop(); env.hid.stop(); env.device.stop()
    }
}
