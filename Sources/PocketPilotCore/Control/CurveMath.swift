import CoreGraphics
import Foundation

/// Owner: control. Pure math for iOS pointer acceleration: fitting measured samples into a monotonic curve,
/// inverting it (pixels -> HID units) and planning moves, swipes and scrolls. No hardware, fully unit-tested.

public enum CurveFitter {
    /// Builds a monotonic piecewise-linear curve from raw measurements.
    ///
    /// - Drops non-positive / non-finite samples and averages duplicates of the same step.
    /// - Enforces "a bigger report never moves the pointer less" with pool-adjacent-violators (isotonic regression),
    ///   then makes it strictly increasing so the inverse is unique.
    public static func fit(_ raw: [CurveSample]) -> AxisCurve {
        var byStep: [Int: [Double]] = [:]
        for s in raw where s.step > 0 && s.pixelsPerStep.isFinite && s.pixelsPerStep > 0 {
            byStep[s.step, default: []].append(s.pixelsPerStep)
        }
        let steps = byStep.keys.sorted()
        // Pool adjacent violators: blocks of (sum, count, firstIndex).
        var blocks: [(sum: Double, count: Int, steps: [Int])] = []
        for st in steps {
            let vals = byStep[st]!
            blocks.append((vals.reduce(0, +), vals.count, [st]))
            while blocks.count >= 2 {
                let b = blocks[blocks.count - 1], a = blocks[blocks.count - 2]
                if a.sum / Double(a.count) <= b.sum / Double(b.count) { break }
                blocks.removeLast(2)
                blocks.append((a.sum + b.sum, a.count + b.count, a.steps + b.steps))
            }
        }
        var samples: [CurveSample] = []
        for b in blocks {
            let mean = b.sum / Double(b.count)
            for st in b.steps { samples.append(CurveSample(step: st, pixelsPerStep: mean)) }
        }
        // Strictly increasing: nudge ties up by a tiny amount (keeps the shape, makes inversion unique).
        for i in samples.indices.dropFirst() where samples[i].pixelsPerStep <= samples[i - 1].pixelsPerStep {
            samples[i].pixelsPerStep = samples[i - 1].pixelsPerStep * 1.0005 + 1e-6
        }
        return AxisCurve(samples: samples)
    }

    /// Checks a fitted curve and explains what is wrong (nil when fine).
    public static func problem(with curve: AxisCurve, axis: String, screenExtent: Double) -> PocketPilotError? {
        guard curve.samples.count >= 3, curve.isUsable else {
            return PocketPilotError(.calibrationFailed, what: "Calibration of the \(axis) axis failed",
                                why: "Only \(curve.samples.count) usable pointer measurements (need at least 3); the pointer was often not seen or hit the screen edge",
                                fix: "Keep the iPhone unlocked on a plain screen (e.g. Settings), don't touch it, and run Calibrate again")
        }
        let maxPx = curve.pixels(forStep: curve.maxStep)
        if maxPx < 1.5 {
            return PocketPilotError(.calibrationFailed, what: "Calibration of the \(axis) axis failed",
                                why: "Even the largest report moved the pointer only \(String(format: "%.1f", maxPx)) px, so the pointer barely moves",
                                fix: "In Settings > Accessibility > Touch > AssistiveTouch, raise Tracking Speed to the middle, then run Calibrate again")
        }
        if maxPx > screenExtent * 1.5 {
            return PocketPilotError(.calibrationFailed, what: "Calibration of the \(axis) axis failed",
                                why: "One report moved the pointer \(Int(maxPx)) px, more than the screen is wide/tall; the measurements are inconsistent",
                                fix: "Lower Tracking Speed in Settings > Accessibility > Touch > AssistiveTouch, then run Calibrate again")
        }
        return nil
    }
}

public extension AxisCurve {
    /// Largest step that was actually measured (we never extrapolate beyond it when planning), capped to 127.
    var maxStep: Int { min(127, max(1, samples.last?.step ?? 1)) }

    /// Inverse of `pixels(forStep:)`: the step (0...maxStep) whose displacement is closest to `pixels` (unsigned).
    /// Returns 0 when even a 1-unit report would overshoot by more than it helps.
    func step(forPixels pixels: Double, maxStep cap: Int? = nil) -> Int {
        let target = abs(pixels)
        let hi = max(1, min(cap ?? maxStep, maxStep))
        if target <= 0 { return 0 }
        // Binary search the first step whose displacement >= target (curve is monotonic).
        var lo = 1, up = hi
        while lo < up {
            let mid = (lo + up) / 2
            if self.pixels(forStep: mid) < target { lo = mid + 1 } else { up = mid }
        }
        var best = 0, bestErr = target
        for s in [lo - 1, lo] where s >= 1 && s <= hi {
            let err = abs(self.pixels(forStep: s) - target)
            if err < bestErr { best = s; bestErr = err }
        }
        return best
    }

    /// Signed HID units per report that move the pointer `distance` px (signed) as accurately as possible:
    /// cruise at `cruiseStep` (default the largest measured step), then one or two tail reports for the rest.
    func planMove(distance: Double, cruiseStep: Int? = nil, maxReports: Int = 400) -> [Int] {
        let sign = distance < 0 ? -1 : 1
        var remaining = abs(distance)
        let cruise = max(1, min(cruiseStep ?? maxStep, maxStep))
        let cruisePx = pixels(forStep: cruise)
        var out: [Int] = []
        guard cruisePx > 0 else { return [] }
        while remaining > cruisePx && out.count < maxReports {
            out.append(cruise); remaining -= cruisePx
        }
        // Tail: up to two reports, each picked by the inverse curve.
        for _ in 0..<2 where out.count < maxReports {
            let s = step(forPixels: remaining, maxStep: cruise)
            if s == 0 { break }
            out.append(s); remaining -= pixels(forStep: s)
            if abs(remaining) < pixels(forStep: 1) / 2 { break }
            if remaining < 0 { break }
        }
        return out.map { $0 * sign }
    }

    /// Predicted pixels for a list of signed steps.
    func displacement(of steps: [Int]) -> Double {
        steps.reduce(0) { $0 + (($1 < 0) ? -1 : 1) * pixels(forStep: $1) }
    }
}

/// A single relative report's movement.
public struct MouseStep: Equatable, Sendable {
    public var dx: Int
    public var dy: Int
    public init(_ dx: Int, _ dy: Int) { self.dx = dx; self.dy = dy }
}

public enum MovePlanner {
    /// Reports to move by (dx, dy) px: all X reports first, then all Y reports (iOS accelerates on the vector
    /// magnitude, and the curves were measured one axis at a time).
    public static func plan(dx: Double, dy: Double, x: AxisCurve, y: AxisCurve) -> [MouseStep] {
        x.planMove(distance: dx).map { MouseStep($0, 0) } + y.planMove(distance: dy).map { MouseStep(0, $0) }
    }

    /// Reports that drive the pointer into a corner whatever its current position.
    public static func park(_ corner: ParkCorner, reports: Int) -> [MouseStep] {
        let sx = (corner == .topLeft || corner == .bottomLeft) ? -127 : 127
        let sy = (corner == .topLeft || corner == .topRight) ? -127 : 127
        return Array(repeating: MouseStep(sx, sy), count: max(1, reports))
    }

    /// Enough parking reports to cross the whole screen at least 1.5x (at least 12, at most 120).
    public static func parkReportCount(screen: CGSize, calibration: CalibrationData?) -> Int {
        guard let c = calibration else { return 60 }
        let px = min(c.x.pixels(forStep: 127), c.y.pixels(forStep: 127))
        guard px > 0 else { return 60 }
        let need = Int((1.5 * Double(max(screen.width, screen.height)) / px).rounded(.up)) + 4
        return min(120, max(12, need))
    }
}

public enum SwipePlanner {
    /// Reports for a held-button drag from `from` to `to` (px, calibration space) spread over `durationMs`,
    /// one report every `intervalMs`. Positions are linearly interpolated; each report's units come from the
    /// inverse curve with error feedback, so rounding never accumulates. Extra reports are appended if the
    /// path could not keep up (very fast swipes).
    public static func plan(from: CGPoint, to: CGPoint, durationMs: Int, intervalMs: Int,
                            x: AxisCurve, y: AxisCurve, maxExtraReports: Int = 200) -> [MouseStep] {
        let n = max(2, durationMs / max(1, intervalMs))
        let total = (dx: Double(to.x - from.x), dy: Double(to.y - from.y))
        var done = (x: 0.0, y: 0.0)
        var out: [MouseStep] = []
        func next(_ need: Double, _ curve: AxisCurve) -> (Int, Double) {
            let s = curve.step(forPixels: need)
            let signed = need < 0 ? -s : s
            return (signed, (need < 0 ? -1 : 1) * curve.pixels(forStep: s))
        }
        for i in 1...n {
            let t = Double(i) / Double(n)
            let (ux, px) = next(total.dx * t - done.x, x)
            let (uy, py) = next(total.dy * t - done.y, y)
            done.x += px; done.y += py
            out.append(MouseStep(ux, uy))
        }
        var extra = 0
        while extra < maxExtraReports {
            let (ux, px) = next(total.dx - done.x, x)
            let (uy, py) = next(total.dy - done.y, y)
            if ux == 0 && uy == 0 { break }
            done.x += px; done.y += py
            out.append(MouseStep(ux, uy)); extra += 1
        }
        return out
    }
}

public enum ScrollPlanner {
    /// Safe area for scroll gestures, as fractions of the screen: away from the left back-swipe edge, the right
    /// edge, the status bar / Notification Centre at the top and the Home indicator at the bottom.
    public static let safeX: ClosedRange<Double> = 0.2...0.8
    public static let safeY: ClosedRange<Double> = 0.22...0.78
    /// >= 500 ms so the content does not keep coasting after the finger lifts.
    public static let durationMs = 600

    /// Finger path for a scroll. "down" reveals content below (finger moves up), "right" reveals content on the
    /// right (finger moves left). `amount` is the fraction (0.05...1) of the safe band to travel.
    public static func path(direction: ScrollDirection, amount: Double, screen: CGSize) -> (from: CGPoint, to: CGPoint) {
        let a = min(1, max(0.05, amount))
        let w = Double(screen.width), h = Double(screen.height)
        let cx = w * (safeX.lowerBound + safeX.upperBound) / 2
        let cy = h * (safeY.lowerBound + safeY.upperBound) / 2
        let lenY = a * h * (safeY.upperBound - safeY.lowerBound)
        let lenX = a * w * (safeX.upperBound - safeX.lowerBound)
        switch direction {
        case .down:  return (CGPoint(x: cx, y: cy + lenY / 2), CGPoint(x: cx, y: cy - lenY / 2))
        case .up:    return (CGPoint(x: cx, y: cy - lenY / 2), CGPoint(x: cx, y: cy + lenY / 2))
        case .right: return (CGPoint(x: cx + lenX / 2, y: cy), CGPoint(x: cx - lenX / 2, y: cy))
        case .left:  return (CGPoint(x: cx - lenX / 2, y: cy), CGPoint(x: cx + lenX / 2, y: cy))
        }
    }
}
