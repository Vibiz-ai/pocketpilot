import CoreGraphics
import XCTest
@testable import PocketPilotCore

/// Owner: control. Curve fitting/inversion, move/swipe/scroll planning, text matching, key combos.
final class ControlMathTests: XCTestCase {
    /// Accelerating curve similar to iOS: px per report grows faster than linearly.
    static let accel = CurveFitter.fit([1, 2, 4, 8, 16, 32, 64, 127].map {
        CurveSample(step: $0, pixelsPerStep: Double($0) * (0.6 + 0.02 * Double($0)))
    })

    // MARK: Fitting

    func testFitEnforcesMonotonicAndDropsBadSamples() {
        let raw = [CurveSample(step: 1, pixelsPerStep: 1), CurveSample(step: 2, pixelsPerStep: 3),
                   CurveSample(step: 4, pixelsPerStep: 2),            // violates
                   CurveSample(step: 8, pixelsPerStep: -1),           // dropped
                   CurveSample(step: 8, pixelsPerStep: .nan),         // dropped
                   CurveSample(step: 16, pixelsPerStep: 10), CurveSample(step: 16, pixelsPerStep: 14)] // averaged
        let c = CurveFitter.fit(raw)
        XCTAssertEqual(c.samples.map(\.step), [1, 2, 4, 16])
        for (a, b) in zip(c.samples, c.samples.dropFirst()) { XCTAssertLessThan(a.pixelsPerStep, b.pixelsPerStep) }
        XCTAssertEqual(c.samples[1].pixelsPerStep, 2.5, accuracy: 0.01) // pooled 3 and 2
        XCTAssertEqual(c.samples.last!.pixelsPerStep, 12, accuracy: 0.01)
        XCTAssertTrue(c.isUsable)
    }

    func testProblemExplainsTooFewSamples() {
        let c = CurveFitter.fit([CurveSample(step: 4, pixelsPerStep: 3)])
        let e = CurveFitter.problem(with: c, axis: "X", screenExtent: 590)
        XCTAssertEqual(e?.code, .calibrationFailed)
        XCTAssertTrue(e?.why.contains("at least 3") ?? false)
        XCTAssertNil(CurveFitter.problem(with: Self.accel, axis: "X", screenExtent: 590))
    }

    // MARK: Inversion and planning

    func testInverseRoundTripsEveryStep() {
        let c = Self.accel
        for s in 1...127 { XCTAssertEqual(c.step(forPixels: c.pixels(forStep: s)), s, "step \(s)") }
        XCTAssertEqual(c.step(forPixels: 0), 0)
        XCTAssertEqual(c.step(forPixels: 0.1), 0)                  // smaller than half of a 1-unit move
        XCTAssertEqual(c.step(forPixels: 1e6), 127)                // clamps
        XCTAssertEqual(c.step(forPixels: 1e6, maxStep: 20), 20)
    }

    func testPlanMoveHitsDistance() {
        let c = Self.accel
        for d in [-480.0, -37, -3, 0.7, 5, 63.5, 250, 900] {
            let plan = c.planMove(distance: d)
            XCTAssertEqual(c.displacement(of: plan), d, accuracy: c.pixels(forStep: 1), "distance \(d)")
            XCTAssertTrue(plan.allSatisfy { d < 0 ? $0 < 0 : $0 > 0 })
            XCTAssertTrue(plan.allSatisfy { abs($0) <= 127 })
        }
        XCTAssertTrue(c.planMove(distance: 0).isEmpty)
    }

    func testMovePlannerSeparatesAxesAndParks() {
        let plan = MovePlanner.plan(dx: 100, dy: -50, x: Self.accel, y: Self.accel)
        let xs = plan.prefix { $0.dy == 0 }, ys = plan.drop { $0.dy == 0 }
        XCTAssertTrue(xs.allSatisfy { $0.dx > 0 }); XCTAssertTrue(ys.allSatisfy { $0.dx == 0 && $0.dy < 0 })
        XCTAssertEqual(Self.accel.displacement(of: xs.map(\.dx)), 100, accuracy: 1)
        XCTAssertEqual(MovePlanner.park(.topLeft, reports: 3), Array(repeating: MouseStep(-127, -127), count: 3))
        XCTAssertEqual(MovePlanner.park(.bottomRight, reports: 1), [MouseStep(127, 127)])
        let cal = CalibrationData(deviceUDID: nil, screenshotSize: CGSize(width: 590, height: 1280), x: Self.accel, y: Self.accel)
        let n = MovePlanner.parkReportCount(screen: cal.screenshotSize, calibration: cal)
        XCTAssertGreaterThanOrEqual(Double(n) * Self.accel.pixels(forStep: 127), 1.5 * 1280)
        XCTAssertEqual(MovePlanner.parkReportCount(screen: cal.screenshotSize, calibration: nil), 60)
    }

    // MARK: Swipe interpolation

    func testSwipeInterpolatesOverDuration() {
        let c = Self.accel
        let from = CGPoint(x: 100, y: 900), to = CGPoint(x: 300, y: 200)
        let plan = SwipePlanner.plan(from: from, to: to, durationMs: 600, intervalMs: 8, x: c, y: c)
        XCTAssertGreaterThanOrEqual(plan.count, 600 / 8)
        XCTAssertEqual(c.displacement(of: plan.map(\.dx)), 200, accuracy: c.pixels(forStep: 1))
        XCTAssertEqual(c.displacement(of: plan.map(\.dy)), -700, accuracy: c.pixels(forStep: 1))
        // Never moves backwards, and progress is spread (no single huge jump).
        XCTAssertTrue(plan.allSatisfy { $0.dx >= 0 && $0.dy <= 0 })
        var cum = 0.0
        for (i, s) in plan.prefix(75).enumerated() {
            cum += c.pixels(forStep: s.dy)
            let expected = 700 * Double(i + 1) / 75
            XCTAssertEqual(cum, expected, accuracy: 0.6 * c.pixels(forStep: 127) / 4 + 10)
        }
    }

    func testFastSwipeAppendsCatchUpReports() {
        let c = CurveFitter.fit([CurveSample(step: 1, pixelsPerStep: 1), CurveSample(step: 127, pixelsPerStep: 20)])
        let plan = SwipePlanner.plan(from: .zero, to: CGPoint(x: 1000, y: 0), durationMs: 100, intervalMs: 10, x: c, y: c)
        XCTAssertGreaterThan(plan.count, 10)
        XCTAssertEqual(c.displacement(of: plan.map(\.dx)), 1000, accuracy: 1)
    }

    // MARK: Scroll

    func testScrollAvoidsEdgesAndMovesFingerOpposite() {
        let s = CGSize(width: 590, height: 1280)
        let down = ScrollPlanner.path(direction: .down, amount: 0.5, screen: s)
        XCTAssertGreaterThan(down.from.y, down.to.y)                   // finger moves up to reveal content below
        XCTAssertEqual(down.from.x, down.to.x)
        let up = ScrollPlanner.path(direction: .up, amount: 1, screen: s)
        XCTAssertLessThan(up.from.y, up.to.y)
        let right = ScrollPlanner.path(direction: .right, amount: 1, screen: s)
        XCTAssertGreaterThan(right.from.x, right.to.x)
        for p in [down.from, down.to, up.from, up.to, right.from, right.to] {
            XCTAssertGreaterThanOrEqual(p.x, 0.2 * 590 - 0.001); XCTAssertLessThanOrEqual(p.x, 0.8 * 590 + 0.001)   // no left back-edge
            XCTAssertGreaterThanOrEqual(p.y, 0.22 * 1280 - 0.001); XCTAssertLessThanOrEqual(p.y, 0.78 * 1280 + 0.001) // no home indicator
        }
        let small = ScrollPlanner.path(direction: .down, amount: 0.2, screen: s)
        XCTAssertLessThan(small.from.y - small.to.y, down.from.y - down.to.y)
        XCTAssertGreaterThanOrEqual(ScrollPlanner.durationMs, 500)
    }

    // MARK: Text matching

    func testTextMatchingTiersAndOccurrence() {
        let items = [
            RecognizedText(text: "Settings for Wi-Fi", x: 200, y: 100, width: 100, height: 20, confidence: 1),
            RecognizedText(text: "settings", x: 300, y: 400, width: 60, height: 20, confidence: 1),
            RecognizedText(text: "General Settings", x: 100, y: 50, width: 80, height: 20, confidence: 1),
            RecognizedText(text: "Settings", x: 50, y: 400, width: 60, height: 20, confidence: 1),
        ]
        // Exact (both, reading order: same line -> left first), then prefix, then contains.
        XCTAssertEqual(TextMatcher.find("Settings", in: items)?.x, 50)
        XCTAssertEqual(TextMatcher.find("SETTINGS", in: items, occurrence: 2)?.x, 300)
        XCTAssertEqual(TextMatcher.find("settings", in: items, occurrence: 3)?.text, "Settings for Wi-Fi")
        XCTAssertEqual(TextMatcher.find("settings", in: items, occurrence: 4)?.text, "General Settings")
        XCTAssertNil(TextMatcher.find("settings", in: items, occurrence: 5))
        XCTAssertNil(TextMatcher.find("settings", in: items, occurrence: 0))
        XCTAssertEqual(TextMatcher.find("  wi-fi ", in: items)?.text, "Settings for Wi-Fi")
        // Normalization: case, accents, whitespace, curly quotes.
        let more = [RecognizedText(text: "Don\u{2019}t  Allow", x: 1, y: 1, width: 1, height: 1, confidence: 1),
                    RecognizedText(text: "Café", x: 1, y: 30, width: 1, height: 1, confidence: 1)]
        XCTAssertNotNil(TextMatcher.find("don't allow", in: more))
        XCTAssertNotNil(TextMatcher.find("cafe", in: more))
    }

    func testTextNotFoundErrorListsVisibleText() {
        let items = [RecognizedText(text: "Wi-Fi", x: 1, y: 1, width: 1, height: 1, confidence: 1)]
        let e = TextMatcher.notFoundError("Bluetooth", occurrence: 1, in: items)
        XCTAssertEqual(e.code, .textNotFound)
        XCTAssertTrue(e.why.contains("\"Wi-Fi\""))
        let e2 = TextMatcher.notFoundError("wi", occurrence: 3, in: items)
        XCTAssertTrue(e2.fix.contains("1...1"))
    }

    // MARK: Key combos (as used by press_key)

    func testKeyComboParsing() throws {
        XCTAssertEqual(try KeyCombo.parse("cmd+space"), KeyCombo(modifiers: .command, target: .key(KeyUsage.space)))
        XCTAssertEqual(try KeyCombo.parse("Shift + Tab"), KeyCombo(modifiers: .shift, target: .key(KeyUsage.tab)))
        XCTAssertEqual(try KeyCombo.parse("ctrl+option+a"), KeyCombo(modifiers: [.control, .option], target: .key(KeyUsage.a)))
        XCTAssertEqual(try KeyCombo.parse("HOME"), KeyCombo(target: .consumer(ConsumerUsage.acHome)))
        XCTAssertEqual(try KeyCombo.parse("return").target, .key(KeyUsage.returnKey))
        XCTAssertEqual(try KeyCombo.parse("cmd+?"), KeyCombo(modifiers: [.command, .shift], target: .key(0x38)))
        XCTAssertThrowsError(try KeyCombo.parse("")) { XCTAssertEqual(($0 as? PocketPilotError)?.code, .invalidArgument) }
        XCTAssertThrowsError(try KeyCombo.parse("cmd+")) { XCTAssertEqual(($0 as? PocketPilotError)?.code, .invalidArgument) }
        XCTAssertThrowsError(try KeyCombo.parse("f13"))
    }
}
