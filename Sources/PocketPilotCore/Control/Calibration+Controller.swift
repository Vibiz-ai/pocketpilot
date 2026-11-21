import CoreGraphics
import Foundation

/// Owner: control. Measures iOS pointer acceleration.
///
/// For each axis and each step size: park in the top-left corner (big negative moves), nudge the pointer off
/// the corner, find it, send `n` reports of `step` units along the axis, find it again. px per report =
/// displacement / n. If the pointer hits the far edge, `n` is halved and the sample retried; a step that
/// overshoots the screen in a single report ends that axis. Samples are fitted into a monotonic curve, checked,
/// verified with an open-loop move to the screen centre, then saved.
public enum CalibrationPlan {
    public static let steps = [1, 2, 4, 8, 16, 32, 64, 96, 127]
    /// Reports per sample: aim for ~96 units total so small steps still move a measurable distance.
    public static func reports(forStep s: Int) -> Int { min(48, max(1, Int((96.0 / Double(max(1, s))).rounded()))) }
    public static let parkReports = 60
    public static let intervalMs = 8
    /// Small diagonal nudge that takes the pointer out of the corner so the whole dot is visible.
    public static let leadIn = MouseStep(6, 6)
    public static let leadInReports = 5
    /// One wording for "where should the iPhone be while calibrating" (the wizard uses it too).
    public static let plainScreenAdvice = "Unlock the iPhone and open Settings (a plain, light screen); busy wallpaper makes the pointer hard to see"
    public static let plainScreenFix = "Open Settings on the iPhone (a plain, light screen), don't touch it, and run calibrate again"
}

extension HIDPhoneController {
    enum Axis: String { case x, y }

    enum SampleResult {
        case sample(CurveSample)
        /// Even one report hits the far edge: larger steps are pointless.
        case saturated
        /// Pointer did not move / was not measurable for this step.
        case skipped(String)
    }

    func runCalibration(progress: @escaping (CalibrationProgress) -> Void) async throws -> CalibrationData {
        try requireHID("calibrate")
        progress(CalibrationProgress(fraction: 0, message: "Preparing: keep the iPhone unlocked and don't touch it"))
        let frame = try liveFrame()
        let geo = try geometry(for: CGSize(width: frame.width, height: frame.height), frame: frame)
        let interval = reportIntervalOverrideMs ?? CalibrationPlan.intervalMs

        let total = Double(CalibrationPlan.steps.count * 2 + 1)
        var done = 0.0
        var curves: [Axis: AxisCurve] = [:]
        for axis in [Axis.x, .y] {
            var raw: [CurveSample] = []
            for step in CalibrationPlan.steps {
                progress(CalibrationProgress(fraction: done / total, message: "Measuring \(axis.rawValue.uppercased()) axis, step \(step)"))
                let result = try await measure(axis: axis, step: step, geo: geo, intervalMs: interval, previous: raw.last)
                done += 1
                switch result {
                case .sample(let s):
                    raw.append(s)
                    log.debug("control", "Calibration \(axis.rawValue) step \(step): \(String(format: "%.2f", s.pixelsPerStep)) px/report")
                case .saturated:
                    log.debug("control", "Calibration \(axis.rawValue) step \(step): one report crosses the screen, stopping this axis")
                    done += Double(CalibrationPlan.steps.count - 1 - (CalibrationPlan.steps.firstIndex(of: step) ?? 0))
                case .skipped(let why):
                    log.debug("control", "Calibration \(axis.rawValue) step \(step) skipped: \(why)")
                }
                if case .saturated = result { break }
            }
            let curve = CurveFitter.fit(raw)
            let extent = axis == .x ? Double(geo.screenshotSize.width) : Double(geo.screenshotSize.height)
            if let problem = CurveFitter.problem(with: curve, axis: axis.rawValue.uppercased(), screenExtent: extent) { throw problem }
            curves[axis] = curve
        }

        var data = CalibrationData(deviceUDID: statusModel.snapshot.value.device?.udid, screenshotSize: geo.screenshotSize,
                                   park: .topLeft, reportIntervalMs: CalibrationPlan.intervalMs, x: curves[.x]!, y: curves[.y]!)
        data.reportIntervalMs = CalibrationPlan.intervalMs

        // Verify: open-loop move to the centre must land close.
        progress(CalibrationProgress(fraction: done / total, message: "Checking: moving to the centre of the screen"))
        let ctx = MotionContext(calibration: data, geometry: geo, k: 1, intervalMs: interval)
        let centre = CGPoint(x: geo.screenshotSize.width / 2, y: geo.screenshotSize.height / 2)
        let parkCount = MovePlanner.parkReportCount(screen: geo.screenshotSize, calibration: data)
        try await sendSteps(MovePlanner.park(.topLeft, reports: parkCount), buttons: [], intervalMs: interval)
        let parked = try await settledFrame()
        try await sendSteps(MovePlanner.plan(dx: Double(centre.x), dy: Double(centre.y), x: data.x, y: data.y), buttons: [], intervalMs: interval)
        let landedFrame = try await settledFrame()
        guard let det = pointer.locate(in: landedFrame, hint: ctx.geometry.toFrame(centre), previous: parked) else {
            throw PocketPilotError(.pointerNotFound, what: "Calibration check failed",
                               why: "After moving to the centre of the screen the pointer could not be found",
                               fix: CalibrationPlan.plainScreenFix)
        }
        pointerSeen()
        let p = geo.toScreenshot(det.point)
        let miss = Double(hypot(p.x - centre.x, p.y - centre.y))
        let allowed = max(20, 0.05 * Double(geo.screenshotSize.width))
        if miss > allowed {
            throw PocketPilotError(.calibrationFailed, what: "Calibration check failed",
                               why: "A move to the screen centre landed \(Int(miss)) px away (allowed \(Int(allowed))); the measurements were inconsistent",
                               fix: "Don't touch the iPhone while calibrating, keep it unlocked on a still screen, and set Settings > Accessibility > Touch > AssistiveTouch > Tracking Speed to the middle; then run calibrate again")
        }
        try calibrationStore.save(data)
        progress(CalibrationProgress(fraction: 1, message: "Calibrated: centre check within \(Int(miss.rounded())) px"))
        log.info("control", "Calibration saved (\(data.x.samples.count) X samples, \(data.y.samples.count) Y samples, centre check \(String(format: "%.1f", miss)) px)")
        return data
    }

    func measure(axis: Axis, step: Int, geo: ScreenGeometry, intervalMs: Int, previous: CurveSample?) async throws -> SampleResult {
        let extent = Double(axis == .x ? geo.screenshotSize.width : geo.screenshotSize.height)
        let edge = max(6, 0.02 * Double(geo.screenshotSize.width))
        var n = CalibrationPlan.reports(forStep: step)
        var retriedCross = false

        while true {
            // Park, then nudge off the corner and find the pointer.
            try await sendSteps(MovePlanner.park(.topLeft, reports: CalibrationPlan.parkReports), buttons: [], intervalMs: intervalMs)
            var before = try await settledFrame()
            var p0: CGPoint?
            for _ in 0..<3 {
                try await sendSteps(Array(repeating: CalibrationPlan.leadIn, count: CalibrationPlan.leadInReports), buttons: [], intervalMs: intervalMs)
                let f = try await settledFrame()
                let hint = geo.toFrame(CGPoint(x: 0.06 * Double(geo.screenshotSize.width), y: 0.06 * Double(geo.screenshotSize.width)))
                if let d = pointer.locate(in: f, hint: hint, previous: before) {
                    let p = geo.toScreenshot(d.point)
                    before = f
                    if Double(p.x) > edge && Double(p.y) > edge { p0 = p; break }
                } else {
                    before = f
                }
            }
            guard let start = p0 else {
                pointerMissed()
                statusModel.set(.assistiveTouch, .failed(Self.pointerNotSeenError()))
                throw Self.pointerNotSeenError()
            }
            pointerSeen()

            let move = axis == .x ? MouseStep(step, 0) : MouseStep(0, step)
            try await sendSteps(Array(repeating: move, count: n), buttons: [], intervalMs: intervalMs)
            let after = try await settledFrame()
            var hint: CGPoint?
            if let prev = previous, prev.step > 0 {
                let est = prev.pixelsPerStep * Double(step) / Double(prev.step) * Double(n)
                let a = axis == .x ? CGPoint(x: min(Double(start.x) + est, extent - 1), y: Double(start.y))
                                   : CGPoint(x: Double(start.x), y: min(Double(start.y) + est, extent - 1))
                hint = geo.toFrame(a)
            }
            guard let d1 = pointer.locate(in: after, hint: hint, previous: before) else {
                // Most likely it ran into the far edge and is half hidden.
                if n > 1 { n /= 2; continue }
                return .saturated
            }
            let p1 = geo.toScreenshot(d1.point)
            let along = Double(axis == .x ? p1.x - start.x : p1.y - start.y)
            let across = Double(axis == .x ? p1.y - start.y : p1.x - start.x)
            let end = Double(axis == .x ? p1.x : p1.y)
            if end >= extent - edge {
                if n > 1 { n /= 2; continue }
                return .saturated
            }
            if abs(across) > max(8, 0.35 * abs(along)) {
                if !retriedCross { retriedCross = true; continue }
                return .skipped("pointer moved \(Int(across)) px across the axis (mis-detection?)")
            }
            guard along > 0.3 else { return .skipped("pointer moved \(String(format: "%.1f", along)) px for \(n) reports") }
            return .sample(CurveSample(step: step, pixelsPerStep: along / Double(n)))
        }
    }
}
