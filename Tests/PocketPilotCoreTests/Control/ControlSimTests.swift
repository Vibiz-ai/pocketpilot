import CoreGraphics
import XCTest
@testable import PocketPilotCore

/// Owner: control. A self-contained simulated iPhone (accelerating relative pointer, drawn dot, AssistiveTouch
/// button, labels) used to test the pointer locator, calibration and closed-loop taps end to end.
final class SimPhone: @unchecked Sendable {
    let size: CGSize
    var pointer: CGPoint
    var buttons: MouseButtons = []
    var clicks: [CGPoint] = []
    var releases: [CGPoint] = []
    var reports: [HIDReport] = []
    var dark = false
    var showPointer = true
    var labels: [(String, CGPoint)] = []
    /// Multiplies the acceleration, e.g. to simulate "Tracking Speed changed".
    var gain = 1.0
    private let lock = NSLock()

    init(size: CGSize = CGSize(width: 1179, height: 2556)) {
        self.size = size
        pointer = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Frame px per report for `units`: accelerating, like iOS.
    func pixels(_ units: Int) -> Double {
        let u = Double(abs(units))
        return (units < 0 ? -1 : 1) * u * (1.1 + 0.025 * u) * Double(size.width) / 590 * gain
    }

    func receive(_ r: HIDReport) {
        lock.withLock {
            reports.append(r)
            guard case .mouse(let m) = r else { return }
            pointer.x = min(size.width - 1, max(0, pointer.x + pixels(Int(m.dx))))
            pointer.y = min(size.height - 1, max(0, pointer.y + pixels(Int(m.dy))))
            if m.buttons.contains(.left) && !buttons.contains(.left) { clicks.append(pointer) }
            if !m.buttons.contains(.left) && buttons.contains(.left) { releases.append(pointer) }
            buttons = m.buttons
        }
    }

    func render() -> CGImage {
        let (p, isDark, show) = lock.withLock { (pointer, dark, showPointer) }
        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Flip so drawing uses top-left origin.
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(gray: isDark ? 0.02 : 0.97, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let u = size.width / 393   // 1 pt
        // Text-like bars (thin, wide: must not be mistaken for the dot).
        ctx.setFillColor(gray: isDark ? 0.9 : 0.15, alpha: 1)
        for i in 0..<8 { ctx.fill(CGRect(x: 20 * u, y: (120 + CGFloat(i) * 70) * u, width: 200 * u, height: 3 * u)) }
        // A big translucent AssistiveTouch button (~60 pt).
        ctx.setFillColor(gray: 0.1, alpha: 0.55)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 320 * u, y: 600 * u, width: 60 * u, height: 60 * u), cornerWidth: 14 * u, cornerHeight: 14 * u, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(gray: 0.95, alpha: 0.8)
        ctx.fillEllipse(in: CGRect(x: 332 * u, y: 612 * u, width: 36 * u, height: 36 * u))
        // Pointer: ~18 pt grey dot.
        if show {
            let r = 9 * u
            ctx.setFillColor(gray: 0.45, alpha: 0.85)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        return ctx.makeImage()!
    }
}

final class SimFrames: FrameSource {
    let phone: SimPhone
    let state = StateChannel<FrameSourceState>(.running(deviceName: "Sim"))
    private var count = 0
    init(_ phone: SimPhone) { self.phone = phone }
    var latestFrame: CGImage? { phone.render() }
    var frameSize: CGSize? { phone.size }
    /// Every read sees a "new" frame, so waitForFrame never blocks.
    var frameCount: Int { count += 1; return count }
    func start() async throws {}
    func stop() {}
}

final class SimHID: HIDTransport {
    let phone: SimPhone
    let state = StateChannel<HIDConnectionState>(.connected(hostName: "Sim"))
    init(_ phone: SimPhone) { self.phone = phone }
    func start() async throws {}
    func stop() {}
    func send(_ report: HIDReport) async throws {
        guard state.value.isConnected else {
            throw PocketPilotError(.hidNotConnected, what: "Not connected", why: "test", fix: "test")
        }
        phone.receive(report)
    }
}

final class SimOCR: TextRecognizer {
    let phone: SimPhone
    init(_ phone: SimPhone) { self.phone = phone }
    func recognize(in image: CGImage) async throws -> [RecognizedText] {
        let s = Double(image.width) / Double(phone.size.width)
        return phone.labels.map { RecognizedText(text: $0.0, x: Double($0.1.x) * s, y: Double($0.1.y) * s, width: 80, height: 20, confidence: 1) }
    }
}

final class ControlSimTests: XCTestCase {
    func makeController(_ phone: SimPhone, store: CalibrationStore = InMemoryCalibrationStore()) -> (HIDPhoneController, StatusModel) {
        let status = StatusModel()
        let c = HIDPhoneController(frames: SimFrames(phone), renderer: ImageScreenshotRenderer(format: .png), recognizer: SimOCR(phone),
                                   hid: SimHID(phone), pointer: DotPointerLocator(), calibrationStore: store, status: status, log: Log())
        c.timing = .fast
        c.reportIntervalOverrideMs = 0
        return (c, status)
    }

    // MARK: Pointer locator

    func testLocatorFindsDotIgnoringAssistiveTouchButton() {
        let phone = SimPhone()
        let loc = DotPointerLocator()
        for (p, dark) in [(CGPoint(x: 600, y: 1400), false), (CGPoint(x: 150, y: 2300), false),
                          (CGPoint(x: 900, y: 300), true), (CGPoint(x: 400, y: 1000), true)] {
            phone.pointer = p; phone.dark = dark
            let d = loc.locate(in: phone.render(), hint: nil, previous: nil)
            XCTAssertNotNil(d, "\(p) dark=\(dark)")
            if let d { XCTAssertLessThan(hypot(d.point.x - p.x, d.point.y - p.y), 6, "\(p) dark=\(dark) got \(d.point)") }
        }
    }

    func testLocatorDiffModeAndMissingPointer() {
        let phone = SimPhone()
        let loc = DotPointerLocator()
        phone.pointer = CGPoint(x: 500, y: 900)
        let before = phone.render()
        phone.pointer = CGPoint(x: 540, y: 915)    // small jiggle: overlapping dots
        let d = loc.locate(in: phone.render(), hint: CGPoint(x: 530, y: 910), previous: before)
        XCTAssertNotNil(d)
        if let d { XCTAssertLessThan(hypot(d.point.x - 540, d.point.y - 915), 6, "got \(d.point)") }

        phone.showPointer = false
        let none = loc.locate(in: phone.render(), hint: nil, previous: nil)
        XCTAssertNil(none, "found a pointer that isn't there: \(String(describing: none))")
    }

    // MARK: End to end

    func testCalibrateThenTapLandsOnTarget() async throws {
        let phone = SimPhone()
        let store = InMemoryCalibrationStore()
        let (c, status) = makeController(phone, store: store)
        var fractions: [Double] = []
        let cal = try await c.calibrate { fractions.append($0.fraction) }
        XCTAssertEqual(fractions.last, 1)
        XCTAssertNotNil(try store.load())
        XCTAssertEqual(status.snapshot.value[.calibration].health, .ok)
        XCTAssertEqual(status.snapshot.value[.assistiveTouch].health, .ok)
        XCTAssertGreaterThanOrEqual(cal.x.samples.count, 3)
        XCTAssertGreaterThanOrEqual(cal.y.samples.count, 3)
        // Measured curve vs. the simulator's truth (in screenshot px; frame/screenshot = 1179/590).
        let s = 590.0 / 1179.0
        for sample in cal.x.samples {
            XCTAssertEqual(sample.pixelsPerStep, phone.pixels(sample.step) * s, accuracy: max(1.5, 0.08 * phone.pixels(sample.step) * s), "x step \(sample.step)")
        }

        for target in [CGPoint(x: 295, y: 640), CGPoint(x: 40, y: 1200), CGPoint(x: 560, y: 90)] {
            phone.clicks = []
            let r = try await c.perform(.tap(x: Double(target.x), y: Double(target.y)))
            XCTAssertEqual(phone.clicks.count, 1)
            let hit = CGPoint(x: phone.clicks[0].x * s, y: phone.clicks[0].y * s)
            XCTAssertLessThan(hypot(hit.x - target.x, hit.y - target.y), 4, "target \(target) hit \(hit); \(r.summary)")
            XCTAssertTrue(r.summary.contains("pointer landed within"), r.summary)
            XCTAssertNotNil(r.screenshot.text)
            XCTAssertEqual(r.screenshot.width, 590)
        }
    }

    func testTapTextSwipeTypeKeysAndBatch() async throws {
        let phone = SimPhone(size: CGSize(width: 1179, height: 2556))
        phone.labels = [("General", CGPoint(x: 400, y: 800)), ("Wi-Fi", CGPoint(x: 300, y: 1600))]
        let (c, _) = makeController(phone)
        _ = try await c.calibrate { _ in }
        let s = 590.0 / 1179.0

        phone.clicks = []
        let r = try await c.perform(.tapText(text: "wi-fi", occurrence: 1))
        XCTAssertEqual(phone.clicks.count, 1)
        XCTAssertLessThan(hypot(phone.clicks[0].x - 300, phone.clicks[0].y - 1600) * s, 4, r.summary)

        do { _ = try await c.perform(.tapText(text: "Bluetooth", occurrence: 1)); XCTFail("expected textNotFound") }
        catch let e as PocketPilotError { XCTAssertEqual(e.code, .textNotFound); XCTAssertTrue(e.why.contains("General")) }

        // Swipe: button goes down at the start and comes up at the end.
        phone.clicks = []; phone.releases = []
        _ = try await c.perform(.swipe(fromX: 300, fromY: 900, toX: 300, toY: 300, durationMs: 600))
        XCTAssertEqual(phone.clicks.count, 1); XCTAssertEqual(phone.releases.count, 1)
        XCTAssertLessThan(hypot(phone.clicks[0].x * s - 300, phone.clicks[0].y * s - 900), 4)
        XCTAssertLessThan(hypot(phone.releases[0].x * s - 300, phone.releases[0].y * s - 300), 8, "\(phone.releases[0])")

        // Scroll down: finger moves up, inside the safe band.
        phone.clicks = []; phone.releases = []
        _ = try await c.perform(.scroll(direction: .down, amount: 0.5))
        XCTAssertGreaterThan(phone.clicks[0].y, phone.releases[0].y)

        // Typing: "Hi" + Return -> H with shift, i, return; each followed by a release.
        phone.reports = []
        _ = try await c.perform(.typeText(text: "Hi", submit: true))
        let keys = phone.reports.compactMap { r -> KeyboardReport? in if case .keyboard(let k) = r { return k }; return nil }
        let pressed = keys.filter { !$0.keys.isEmpty }
        XCTAssertEqual(pressed.map(\.keys), [[0x0B], [0x0C], [KeyUsage.returnKey]])
        XCTAssertEqual(pressed[0].modifiers, .shift)
        XCTAssertEqual(keys.last, .released)

        // Home -> consumer AC Home press + release.
        phone.reports = []
        _ = try await c.perform(.pressKey(key: "home"))
        XCTAssertEqual(phone.reports.prefix(2), [.consumer(ConsumerReport(usage: ConsumerUsage.acHome)), .consumer(.released)])

        // open_app: home, cmd+space, typed name, return.
        phone.reports = []
        _ = try await c.perform(.openApp(name: "Maps"))
        let kb = phone.reports.compactMap { r -> KeyboardReport? in if case .keyboard(let k) = r, !k.keys.isEmpty { return k }; return nil }
        XCTAssertTrue(kb.contains(KeyboardReport(modifiers: .command, keys: [KeyUsage.space])))
        XCTAssertEqual(kb.last?.keys, [KeyUsage.returnKey])

        // Batch stops at the first failure and names the step.
        do {
            _ = try await c.performBatch([.wait(ms: 1), .tapText(text: "Nope", occurrence: 1), .tap(x: 10, y: 10)])
            XCTFail("expected failure")
        } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .textNotFound)
            XCTAssertTrue(e.what.hasPrefix("Step 2 (tap_text) failed:"), e.what)
        }
        let ok = try await c.performBatch([.tap(x: 100, y: 100), .wait(ms: 1), .pressKey(key: "cmd+space")])
        XCTAssertTrue(ok.summary.hasPrefix("Ran 3 actions"), ok.summary)
    }

    func testErrorsSayWhyAndFix() async throws {
        let phone = SimPhone()
        let (c, _) = makeController(phone)
        // Not calibrated.
        do { _ = try await c.perform(.tap(x: 10, y: 10)); XCTFail() }
        catch let e as PocketPilotError { XCTAssertEqual(e.code, .notCalibrated); XCTAssertTrue(e.fix.contains("calibrate")) }
        _ = try await c.calibrate { _ in }
        // Out-of-range coordinates.
        do { _ = try await c.perform(.tap(x: 5000, y: 10)); XCTFail() }
        catch let e as PocketPilotError { XCTAssertEqual(e.code, .invalidArgument); XCTAssertTrue(e.why.contains("0...590")) }
        // Untypeable text is rejected before anything is sent.
        phone.reports = []
        do { _ = try await c.perform(.typeText(text: "héllo", submit: false)); XCTFail() }
        catch let e as PocketPilotError { XCTAssertEqual(e.code, .invalidArgument) }
        XCTAssertTrue(phone.reports.isEmpty)
        // Tracking speed changed a lot: closed loop either corrects or refuses to click.
        phone.gain = 1.6; phone.clicks = []
        do {
            let r = try await c.perform(.tap(x: 295, y: 640))
            let s = 590.0 / 1179.0
            XCTAssertLessThan(hypot(phone.clicks[0].x * s - 295, phone.clicks[0].y * s - 640), 4, r.summary)
        } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .calibrationFailed); XCTAssertTrue(phone.clicks.isEmpty)
        }
        phone.gain = 1
        // Bluetooth not connected.
        (c.hid as! SimHID).state.send(.advertising(name: "PocketPilot"))
        do { _ = try await c.perform(.pressKey(key: "return")); XCTFail() }
        catch let e as PocketPilotError { XCTAssertEqual(e.code, .hidNotConnected); XCTAssertTrue(e.fix.contains("Settings > Bluetooth")) }
        // No pointer visible -> calibration explains AssistiveTouch.
        (c.hid as! SimHID).state.send(.connected(hostName: nil))
        phone.showPointer = false
        do { _ = try await c.calibrate { _ in }; XCTFail() }
        catch let e as PocketPilotError { XCTAssertEqual(e.code, .assistiveTouchOff); XCTAssertTrue(e.fix.contains("AssistiveTouch")) }
    }
}
