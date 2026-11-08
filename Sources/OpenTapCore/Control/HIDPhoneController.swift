import CoreGraphics
import Foundation

/// Owner: control. Taps (park + curve move + closed-loop correction + click), swipes, typing, keys, open_app,
/// calibration, screenshots (+OCR).
///
/// Coordinates from agents are in the latest screenshot's space. The calibration curves are stored in the
/// calibration's own screenshot space and scaled when the renderer's width differs.
public final class HIDPhoneController: PhoneController, @unchecked Sendable {
    public let frames: FrameSource
    public let renderer: ScreenshotRenderer
    public let recognizer: TextRecognizer
    public let hid: HIDTransport
    public let pointer: PointerLocator
    public let calibrationStore: CalibrationStore
    public let statusModel: StatusModel
    public let log: Log

    /// Delays used between reports and before screenshots. Tests shrink these.
    public struct Timing: Sendable {
        /// Wait after the pointer stops before looking for it.
        public var pointerSettleMs = 120
        /// Button held for a click.
        public var clickHoldMs = 70
        /// Key held / gap between keys.
        public var keyHoldMs = 14
        public var keyGapMs = 14
        /// Wait before the result screenshot, per action kind.
        public var tapSettleMs = 400
        public var swipeSettleMs = 450
        public var flingSettleMs = 900
        public var typeSettleMs = 250
        public var keySettleMs = 450
        public var openAppSettleMs = 1200
        /// Steps inside open_app.
        public var homeSettleMs = 700
        public var spotlightSettleMs = 700
        public var spotlightTypeSettleMs = 600
        /// Max time to wait for a fresh frame.
        public var frameTimeout: TimeInterval = 0.6
        public init() {}
        /// Everything ~instant, for tests against simulated phones.
        public static var fast: Timing {
            var t = Timing()
            t.pointerSettleMs = 0; t.clickHoldMs = 0; t.keyHoldMs = 0; t.keyGapMs = 0
            t.tapSettleMs = 0; t.swipeSettleMs = 0; t.flingSettleMs = 0; t.typeSettleMs = 0; t.keySettleMs = 0
            t.openAppSettleMs = 0; t.homeSettleMs = 0; t.spotlightSettleMs = 0; t.spotlightTypeSettleMs = 0
            t.frameTimeout = 0.05
            return t
        }
    }

    public var timing = Timing()
    /// Report interval override (nil = the calibration's). Tests set 0.
    public var reportIntervalOverrideMs: Int?
    /// Pointer must land within this many screenshot px; otherwise we correct.
    public var tapTolerance: Double = 2.5
    public var maxCorrections = 2

    let gate = ActionGate()
    private let lock = NSLock()
    private var _lastScreenshotSize: CGSize?
    /// frameCount at which the source was last seen not advancing (a still screen, or a mock that never ticks).
    /// Cleared as soon as the counter moves past it, so one quiet gap never disables fresh-frame waits for good.
    private var _staticSince: Int?
    private var _pointerMisses = 0

    public init(frames: FrameSource, renderer: ScreenshotRenderer, recognizer: TextRecognizer, hid: HIDTransport,
                pointer: PointerLocator, calibrationStore: CalibrationStore, status: StatusModel, log: Log) {
        self.frames = frames; self.renderer = renderer; self.recognizer = recognizer; self.hid = hid
        self.pointer = pointer; self.calibrationStore = calibrationStore; self.statusModel = status; self.log = log
    }

    // MARK: - PhoneController

    public func screenshot(includeText: Bool) async throws -> Screenshot {
        let frame = try liveFrame()
        let number = frames.frameCount
        let rendered: RenderedScreenshot
        do { rendered = try renderer.render(frame) } catch {
            throw OpenTapError.wrap(error, what: "Couldn't make a screenshot")
        }
        var text: [RecognizedText]?
        if includeText {
            do { text = try await recognizer.recognize(in: rendered.image) } catch {
                throw OpenTapError.wrap(error, what: "Couldn't read the text on the iPhone screen",
                                        fix: "Try again; if it keeps failing, call screenshot with include_text false")
            }
        }
        if let text { noteLockState(text, screenHeight: Double(rendered.image.height)) }
        let size = CGSize(width: rendered.image.width, height: rendered.image.height)
        let changed: Bool = lock.withLock { let c = _lastScreenshotSize != size; _lastScreenshotSize = size; return c }
        if changed {
            statusModel.update { $0.screenshotWidth = rendered.image.width; $0.screenshotHeight = rendered.image.height }
        }
        return Screenshot(imageData: rendered.data, format: rendered.format, width: rendered.image.width,
                          height: rendered.image.height, frameNumber: number, capturedAt: Date(), text: text)
    }

    public func perform(_ action: PhoneAction) async throws -> ActionResult {
        try await gate.serialized {
            let before = self.frames.latestFrame
            let (summary, settle) = try await self.execute(action)
            let shot = try await self.resultScreenshot(settleMs: settle)
            let note = try self.checkOutcome(of: action, shot, before: before)
            let full = summary + note
            self.log.info("control", full)
            return ActionResult(summary: full, screenshot: shot)
        }
    }

    public func performBatch(_ actions: [PhoneAction]) async throws -> ActionResult {
        guard !actions.isEmpty else {
            throw OpenTapError.invalidArgument("actions", why: "The batch is empty",
                                               fix: "Pass at least one action, e.g. [{\"type\":\"tap\",\"x\":100,\"y\":200}]")
        }
        guard actions.count <= 100 else {
            throw OpenTapError.invalidArgument("actions", why: "A batch can hold at most 100 actions (got \(actions.count))",
                                               fix: "Split it into several batches")
        }
        return try await gate.serialized {
            var summaries: [String] = []
            var lastSettle = 0
            var lastBefore: CGImage?
            for (i, action) in actions.enumerated() {
                do {
                    if i > 0 && lastSettle > 0 { try await self.sleep(ms: min(lastSettle, 400)) }
                    lastBefore = self.frames.latestFrame
                    let (s, settle) = try await self.execute(action)
                    var note = ""
                    if case .openApp = action, i < actions.count - 1 {
                        // Later steps assume the app is open: check now rather than only at the end.
                        let shot = try await self.resultScreenshot(settleMs: settle)
                        note = try self.checkOutcome(of: action, shot, before: lastBefore)
                        lastSettle = 0
                    } else {
                        lastSettle = settle
                    }
                    summaries.append("\(i + 1). \(s)\(note)")
                } catch {
                    let e = OpenTapError.wrap(error, what: "\(action.name) failed")
                    let done = summaries.isEmpty ? "" : " (steps 1...\(i) completed)"
                    throw OpenTapError(e.code, what: "Step \(i + 1) (\(action.name)) failed: \(e.what)\(done)", why: e.why, fix: e.fix)
                }
            }
            let shot = try await self.resultScreenshot(settleMs: lastSettle)
            let last = actions[actions.count - 1]
            let note: String
            do { note = try self.checkOutcome(of: last, shot, before: lastBefore) } catch {
                let e = OpenTapError.wrap(error, what: "\(last.name) failed")
                let done = actions.count > 1 ? " (steps 1...\(actions.count - 1) completed)" : ""
                throw OpenTapError(e.code, what: "Step \(actions.count) (\(last.name)) failed: \(e.what)\(done)", why: e.why, fix: e.fix)
            }
            let summary = "Ran \(actions.count) action\(actions.count == 1 ? "" : "s"): " + summaries.joined(separator: "; ") + note
            self.log.info("control", summary)
            return ActionResult(summary: summary, screenshot: shot)
        }
    }

    public func calibrate(progress: @escaping (CalibrationProgress) -> Void) async throws -> CalibrationData {
        try await gate.serialized {
            self.statusModel.set(.calibration, .pending("Calibrating..."))
            do {
                let data = try await self.runCalibration(progress: progress)
                self.statusModel.set(.calibration, .ok("Calibrated \(data.createdAt.formatted(date: .abbreviated, time: .shortened))"))
                return data
            } catch {
                let e = OpenTapError.wrap(error, what: "Calibration failed")
                self.log.error("control", e)
                if (try? self.calibrationStore.load()) != nil {
                    self.statusModel.set(.calibration, ComponentStatus(.ok, "Previous calibration kept (recalibration failed: \(e.what))", error: e))
                } else {
                    self.statusModel.set(.calibration, .failed(e))
                }
                throw e
            }
        }
    }

    public func status() async -> StatusSnapshot { statusModel.snapshot.value }

    // MARK: - Actions

    /// Runs one action without the gate or a result screenshot. Returns the summary and how long the UI
    /// should settle before the next screenshot.
    func execute(_ action: PhoneAction) async throws -> (String, Int) {
        switch action {
        case let .tap(x, y):
            let ctx = try motionContext("tap")
            let target = try validatedPoint(x, y, ctx, names: ("x", "y"))
            let outcome = try await moveTo(target, ctx, what: "Tap at (\(fmt(x)), \(fmt(y)))")
            try await click()
            return ("Tapped (\(fmt(x)), \(fmt(y)))\(outcome.note)", timing.tapSettleMs)

        case let .tapText(text, occurrence):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenTapError.invalidArgument("text", why: "The text to tap is empty", fix: "Pass the label exactly as it appears on screen")
            }
            guard occurrence >= 1 else {
                throw OpenTapError.invalidArgument("occurrence", why: "occurrence is 1-based (got \(occurrence))", fix: "Use 1 for the first match")
            }
            let ctx = try motionContext("tap \"\(text)\"")
            let shot = try await screenshot(includeText: true)
            let items = shot.text ?? []
            guard let hit = TextMatcher.find(text, in: items, occurrence: occurrence) else {
                throw TextMatcher.notFoundError(text, occurrence: occurrence, in: items)
            }
            let target = CGPoint(x: hit.x, y: hit.y)
            let outcome = try await moveTo(target, ctx, what: "Tap on \"\(hit.text)\"")
            try await click()
            return ("Tapped \"\(hit.text)\" at (\(fmt(hit.x)), \(fmt(hit.y)))\(outcome.note)", timing.tapSettleMs)

        case let .longPress(x, y, durationMs):
            guard (100...20_000).contains(durationMs) else {
                throw OpenTapError.invalidArgument("duration_ms", why: "Must be 100...20000 ms (got \(durationMs))", fix: "Use about 800 for a typical long press")
            }
            let ctx = try motionContext("long press")
            let target = try validatedPoint(x, y, ctx, names: ("x", "y"))
            let outcome = try await moveTo(target, ctx, what: "Long press at (\(fmt(x)), \(fmt(y)))")
            try await sendMouse(MouseStep(0, 0), buttons: .left)
            do { try await sleep(ms: durationMs) } catch { try? await sendMouse(MouseStep(0, 0), buttons: []); throw error }
            try await sendMouse(MouseStep(0, 0), buttons: [])
            return ("Long-pressed (\(fmt(x)), \(fmt(y))) for \(durationMs) ms\(outcome.note)", timing.tapSettleMs)

        case let .swipe(fx, fy, tx, ty, durationMs):
            guard (50...10_000).contains(durationMs) else {
                throw OpenTapError.invalidArgument("duration_ms", why: "Must be 50...10000 ms (got \(durationMs))",
                                                   fix: "Use 500 or more for a precise drag, less for a fling")
            }
            let ctx = try motionContext("swipe")
            let from = try validatedPoint(fx, fy, ctx, names: ("from_x", "from_y"))
            let to = try validatedPoint(tx, ty, ctx, names: ("to_x", "to_y"))
            let note = try await drag(from: from, to: to, durationMs: durationMs, ctx)
            let fling = durationMs < 500
            return ("Swiped (\(fmt(fx)), \(fmt(fy))) -> (\(fmt(tx)), \(fmt(ty))) in \(durationMs) ms\(fling ? " (fling)" : "")\(note)",
                    fling ? timing.flingSettleMs : timing.swipeSettleMs)

        case let .scroll(direction, amount):
            guard amount > 0, amount <= 1 else {
                throw OpenTapError.invalidArgument("amount", why: "amount is the fraction of the screen to scroll, 0...1 (got \(amount))",
                                                   fix: "Use 0.5 for half a screen, 1 for a full screen")
            }
            let ctx = try motionContext("scroll")
            let path = ScrollPlanner.path(direction: direction, amount: amount, screen: ctx.shot)
            let note = try await drag(from: path.from, to: path.to, durationMs: ScrollPlanner.durationMs, ctx)
            return ("Scrolled \(direction.rawValue) by \(Int((amount * 100).rounded()))% of the screen\(note)", timing.swipeSettleMs)

        case let .typeText(text, submit):
            let strokes = try USKeyboardLayout.strokes(for: text)
            guard !strokes.isEmpty || submit else {
                throw OpenTapError.invalidArgument("text", why: "Nothing to type", fix: "Pass some text, or submit: true to press Return")
            }
            try requireHID("type")
            for s in strokes { try await sendStroke(s) }
            if submit { try await sendStroke(KeyStroke(KeyUsage.returnKey)) }
            return ("Typed \(text.count) character\(text.count == 1 ? "" : "s")\(submit ? " and pressed Return" : "")", timing.typeSettleMs)

        case let .pressKey(key):
            let combo = try KeyCombo.parse(key)
            try requireHID("press \(key)")
            switch combo.target {
            case .consumer(let usage) where usage == ConsumerUsage.acHome && combo.modifiers.isEmpty:
                let how = try await goHome()
                return ("Pressed Home\(how)", timing.keySettleMs)
            case .consumer(let usage):
                try await consumerPress(usage)
            case .key(let usage):
                try await sendStroke(KeyStroke(usage, combo.modifiers))
            }
            return ("Pressed \(key)", timing.keySettleMs)

        case let .openApp(name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw OpenTapError.invalidArgument("name", why: "The app name is empty", fix: "Pass the app name as shown under its icon, e.g. \"Settings\"")
            }
            let strokes = try USKeyboardLayout.strokes(for: trimmed)
            try requireHID("open \(trimmed)")
            _ = try await goHome()
            try await sleep(ms: timing.homeSettleMs)
            try await sendStroke(KeyStroke(KeyUsage.space, .command))
            try await sleep(ms: timing.spotlightSettleMs)
            for s in strokes { try await sendStroke(s) }
            try await sleep(ms: timing.spotlightTypeSettleMs)
            try await sendStroke(KeyStroke(KeyUsage.returnKey))
            return ("Opened \"\(trimmed)\" via Spotlight (Home, cmd+space, type, Return)", timing.openAppSettleMs)

        case let .wait(ms):
            guard (0...60_000).contains(ms) else {
                throw OpenTapError.invalidArgument("ms", why: "wait must be 0...60000 ms (got \(ms))", fix: "Use a shorter wait, e.g. 1000")
            }
            try await sleep(ms: ms)
            return ("Waited \(ms) ms", 0)
        }
    }

    // MARK: - Motion

    struct MotionContext {
        var calibration: CalibrationData
        /// Frame px <-> current screenshot px.
        var geometry: ScreenGeometry
        /// Current screenshot size.
        var shot: CGSize { geometry.screenshotSize }
        /// Calibration px per current screenshot px.
        var k: Double
        var intervalMs: Int
    }

    struct MoveOutcome {
        var landed: CGPoint?
        var residual: Double?
        var corrections: Int
        var warning: String?
        var note: String {
            var parts: [String] = []
            if let r = residual {
                parts.append("pointer landed within \(String(format: "%.1f", r)) px" +
                             (corrections > 0 ? " after \(corrections) correction\(corrections == 1 ? "" : "s")" : ""))
            } else {
                parts.append("pointer position not verified (pointer not seen)")
            }
            if let w = warning { parts.append(w) }
            return "; " + parts.joined(separator: "; ")
        }
    }

    func motionContext(_ what: String) throws -> MotionContext {
        try requireHID(what)
        guard let cal = try loadCalibration() else {
            throw OpenTapError(.notCalibrated, what: "Can't \(what): OpenTap isn't calibrated",
                               why: "Moving the pointer needs the iPhone's pointer-speed curve, which hasn't been measured yet",
                               fix: "Run the calibrate tool (or Calibrate in OpenTap) with the iPhone unlocked; it takes about 30 seconds")
        }
        guard cal.version == CalibrationData.currentVersion else {
            throw OpenTapError(.notCalibrated, what: "Can't \(what): the saved calibration is from another OpenTap version",
                               why: "Calibration format \(cal.version) != \(CalibrationData.currentVersion)", fix: "Run calibrate again")
        }
        guard cal.x.isUsable, cal.y.isUsable else {
            throw OpenTapError(.notCalibrated, what: "Can't \(what): the saved calibration is unusable",
                               why: "It has too few valid pointer measurements", fix: "Run calibrate again with the iPhone unlocked")
        }
        let frame = try liveFrame()
        let geo = try geometry(for: CGSize(width: frame.width, height: frame.height), frame: frame)
        let calAspect = Double(cal.screenshotSize.height / max(1, cal.screenshotSize.width))
        let aspect = Double(geo.screenshotSize.height / max(1, geo.screenshotSize.width))
        if abs(calAspect - aspect) > 0.03 * aspect {
            throw OpenTapError(.notCalibrated, what: "Can't \(what): the calibration was made on a different screen",
                               why: "Calibrated for \(Int(cal.screenshotSize.width))x\(Int(cal.screenshotSize.height)), but the screen is now \(Int(geo.screenshotSize.width))x\(Int(geo.screenshotSize.height)) (another iPhone, or it rotated)",
                               fix: "Hold the iPhone in portrait, or run calibrate again for this iPhone")
        }
        if let calUDID = cal.deviceUDID, let now = statusModel.snapshot.value.device?.udid, calUDID != now {
            throw OpenTapError(.notCalibrated, what: "Can't \(what): the calibration belongs to another iPhone",
                               why: "It was measured on device \(calUDID), but \(statusModel.snapshot.value.device?.name ?? now) is connected",
                               fix: "Run calibrate again for this iPhone")
        }
        let k = Double(cal.screenshotSize.width) / Double(max(1, geo.screenshotSize.width))
        return MotionContext(calibration: cal, geometry: geo, k: k,
                             intervalMs: reportIntervalOverrideMs ?? max(1, cal.reportIntervalMs))
    }

    func validatedPoint(_ x: Double, _ y: Double, _ ctx: MotionContext, names: (String, String)) throws -> CGPoint {
        let w = Double(ctx.shot.width), h = Double(ctx.shot.height)
        guard x.isFinite, x >= 0, x <= w else {
            throw OpenTapError.invalidArgument(names.0, why: "\(names.0)=\(fmt(x)) is outside the screenshot (0...\(Int(w)))",
                                               fix: "Use coordinates from the latest screenshot (\(Int(w))x\(Int(h)) px, origin top-left)")
        }
        guard y.isFinite, y >= 0, y <= h else {
            throw OpenTapError.invalidArgument(names.1, why: "\(names.1)=\(fmt(y)) is outside the screenshot (0...\(Int(h)))",
                                               fix: "Use coordinates from the latest screenshot (\(Int(w))x\(Int(h)) px, origin top-left)")
        }
        return CGPoint(x: x, y: y)
    }

    func parkPoint(_ corner: ParkCorner, _ size: CGSize) -> CGPoint {
        switch corner {
        case .topLeft: return .zero
        case .topRight: return CGPoint(x: size.width, y: 0)
        case .bottomLeft: return CGPoint(x: 0, y: size.height)
        case .bottomRight: return CGPoint(x: size.width, y: size.height)
        }
    }

    /// Park, move along the curve, then look for the pointer and correct up to `maxCorrections` times.
    func moveTo(_ finalTarget: CGPoint, _ ctx: MotionContext, what: String) async throws -> MoveOutcome {
        let cal = ctx.calibration
        // Near an edge the dot is clamped and half hidden, so verify at a point inset from the edge and cover the
        // last few px open-loop (the screen edge stops any overshoot).
        let m = 0.04 * Double(ctx.shot.width)
        let target = CGPoint(x: min(max(Double(finalTarget.x), m), Double(ctx.shot.width) - m),
                             y: min(max(Double(finalTarget.y), m), Double(ctx.shot.height) - m))
        let parkCount = MovePlanner.parkReportCount(screen: cal.screenshotSize, calibration: cal)
        try await sendSteps(MovePlanner.park(cal.park, reports: parkCount), buttons: [], intervalMs: ctx.intervalMs)
        var before = try await settledFrame()
        var position = parkPoint(cal.park, ctx.shot)
        var delta = CGPoint(x: target.x - position.x, y: target.y - position.y)
        let distance = Double(hypot(delta.x, delta.y))
        var outcome = MoveOutcome(landed: nil, residual: nil, corrections: 0, warning: nil)

        for attempt in 0...maxCorrections {
            let plan = MovePlanner.plan(dx: Double(delta.x) * ctx.k, dy: Double(delta.y) * ctx.k, x: cal.x, y: cal.y)
            if plan.isEmpty && attempt > 0 { break }
            try await sendSteps(plan, buttons: [], intervalMs: ctx.intervalMs)
            if attempt > 0 { outcome.corrections = attempt }
            position = CGPoint(x: position.x + delta.x, y: position.y + delta.y)
            var frame = try await settledFrame()
            let hint = ctx.geometry.toFrame(target)
            var found = pointer.locate(in: frame, hint: hint, previous: before)
            if found == nil {
                // Second chance: a tiny jiggle, so the frame difference shows exactly where the dot is.
                try await sendSteps([MouseStep(2, 2)], buttons: [], intervalMs: ctx.intervalMs)
                let jiggled = try await settledFrame()
                found = pointer.locate(in: jiggled, hint: hint, previous: frame)
                if found != nil { frame = jiggled }
            }
            guard let det = found else {
                pointerMissed()
                let e = Self.pointerNotSeenError()
                statusModel.set(.assistiveTouch, .failed(e))
                throw OpenTapError(e.code, what: "\(what) was not sent: \(e.what.prefix(1).lowercased() + e.what.dropFirst())",
                                   why: e.why, fix: e.fix)
            }
            pointerSeen()
            let p = ctx.geometry.toScreenshot(det.point)
            let err = CGPoint(x: target.x - p.x, y: target.y - p.y)
            let r = Double(hypot(err.x, err.y))
            outcome.landed = p; outcome.residual = r
            if attempt == 0, r > max(20, 0.2 * distance) {
                outcome.warning = "first move was \(Int(r)) px off; if Tracking Speed changed, run calibrate again"
                log.warning("control", "\(what): pointer landed \(Int(r)) px from target on the first move; the calibration may be stale (Tracking Speed changed?)")
            }
            if r <= tapTolerance || attempt == maxCorrections { break }
            delta = err; position = p; before = frame
        }
        if let r = outcome.residual, r > max(12, 0.025 * Double(ctx.shot.width)) {
            let p = outcome.landed ?? .zero
            throw OpenTapError(.calibrationFailed, what: "\(what) was not sent",
                               why: "The pointer stopped at (\(fmt(Double(p.x))), \(fmt(Double(p.y)))), \(Int(r)) px from the target even after \(maxCorrections) corrections; the pointer speed no longer matches the calibration (Tracking Speed or pointer settings changed?)",
                               fix: "Run calibrate again, and keep Settings > Accessibility > Touch > AssistiveTouch > Tracking Speed unchanged afterwards")
        }
        if target != finalTarget, let landed = outcome.landed {
            let dx = Double(finalTarget.x - landed.x), dy = Double(finalTarget.y - landed.y)
            try await sendSteps(MovePlanner.plan(dx: dx * ctx.k, dy: dy * ctx.k, x: cal.x, y: cal.y), buttons: [], intervalMs: ctx.intervalMs)
            outcome.landed = finalTarget
            outcome.warning = [outcome.warning, "last \(Int(hypot(dx, dy).rounded())) px to the screen edge unverified"]
                .compactMap { $0 }.joined(separator: "; ")
        }
        return outcome
    }

    /// Button-held drag along an interpolated path. >= 500 ms holds still before release so nothing coasts.
    func drag(from: CGPoint, to: CGPoint, durationMs: Int, _ ctx: MotionContext) async throws -> String {
        let outcome = try await moveTo(from, ctx, what: "Swipe start (\(fmt(Double(from.x))), \(fmt(Double(from.y))))")
        let cal = ctx.calibration
        let interval = max(ctx.intervalMs, reportIntervalOverrideMs == nil ? 8 : 0)
        let start = outcome.landed ?? from
        let k = CGFloat(ctx.k)
        let plan = SwipePlanner.plan(from: CGPoint(x: start.x * k, y: start.y * k), to: CGPoint(x: to.x * k, y: to.y * k),
                                     durationMs: durationMs, intervalMs: max(1, interval), x: cal.x, y: cal.y)
        try await sendMouse(MouseStep(0, 0), buttons: .left)
        do {
            try await sleep(ms: min(50, timing.clickHoldMs))
            try await sendSteps(plan, buttons: .left, intervalMs: interval)
            if durationMs >= 500 {
                try await sendMouse(MouseStep(0, 0), buttons: .left)
                try await sleep(ms: min(120, timing.swipeSettleMs))
            }
        } catch {
            try? await sendMouse(MouseStep(0, 0), buttons: [])
            throw error
        }
        try await sendMouse(MouseStep(0, 0), buttons: [])
        return outcome.note
    }

    // MARK: - Keys

    /// AC Home; if the screen did not change at all, also sends cmd+H (some iOS versions ignore AC Home).
    func goHome() async throws -> String {
        let before = frames.latestFrame
        try await consumerPress(ConsumerUsage.acHome)
        guard let b = before else { return "" }
        try await sleep(ms: max(timing.homeSettleMs, 0))
        guard let after = try? await settledFrame(), !Self.framesDiffer(b, after) else { return "" }
        try await sendStroke(KeyStroke(KeyUsage.a + 7 /* h */, .command))
        return " (screen didn't change after Home, also sent cmd+H)"
    }

    func consumerPress(_ usage: UInt16) async throws {
        try await send(.consumer(ConsumerReport(usage: usage)))
        try await sleep(ms: max(timing.keyHoldMs, timing.keyHoldMs > 0 ? 40 : 0))
        try await send(.consumer(.released))
        try await sleep(ms: timing.keyGapMs)
    }

    /// Modifiers first, then the key, then release in reverse (what real keyboards do).
    func sendStroke(_ s: KeyStroke) async throws {
        if !s.modifiers.isEmpty {
            try await send(.keyboard(KeyboardReport(modifiers: s.modifiers)))
            try await sleep(ms: timing.keyGapMs)
        }
        try await send(.keyboard(KeyboardReport(modifiers: s.modifiers, keys: [s.usage])))
        try await sleep(ms: timing.keyHoldMs)
        if !s.modifiers.isEmpty {
            try await send(.keyboard(KeyboardReport(modifiers: s.modifiers)))
            try await sleep(ms: timing.keyGapMs)
        }
        try await send(.keyboard(.released))
        try await sleep(ms: timing.keyGapMs)
    }

    // MARK: - Low level

    func click() async throws {
        try await sendMouse(MouseStep(0, 0), buttons: .left)
        try await sleep(ms: timing.clickHoldMs)
        try await sendMouse(MouseStep(0, 0), buttons: [])
    }

    func sendMouse(_ step: MouseStep, buttons: MouseButtons) async throws {
        let dx = Int8(clamping: step.dx), dy = Int8(clamping: step.dy)
        try await send(.mouse(MouseReport(buttons: buttons, dx: dx, dy: dy)))
    }

    /// Sends one report per `intervalMs`, scheduled by absolute deadline so the rhythm doesn't drift with send
    /// latency (iOS acceleration depends on velocity, so calibration and later moves must share the same rhythm).
    func sendSteps(_ steps: [MouseStep], buttons: MouseButtons, intervalMs: Int) async throws {
        guard intervalMs > 0 else {
            for s in steps { try await sendMouse(s, buttons: buttons); await Task.yield() }
            return
        }
        let clock = ContinuousClock()
        let period = Duration.milliseconds(intervalMs)
        var deadline = clock.now
        for s in steps {
            try await sendMouse(s, buttons: buttons)
            deadline += period
            let now = clock.now
            if deadline > now {
                try await Task.sleep(until: deadline, clock: clock)
            } else if now - deadline > period * 4 {
                deadline = now   // badly late (system stall): restart the rhythm instead of bursting to catch up
            }
        }
    }

    func send(_ report: HIDReport) async throws {
        do { try await hid.send(report) } catch {
            throw OpenTapError.wrap(error, what: "Couldn't send input to the iPhone",
                                    fix: "Check the Bluetooth pill; re-pair \"OpenTap\" in iPhone Settings > Bluetooth if needed")
        }
    }

    func sleep(ms: Int) async throws {
        guard ms > 0 else { await Task.yield(); return }
        try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    /// Waits for the pointer/UI to settle, then returns a frame captured after that.
    func settledFrame() async throws -> CGImage {
        try await sleep(ms: timing.pointerSettleMs)
        return try await freshFrame(after: frames.frameCount)
    }

    /// The next frame after `count`; sources that never advance frameCount (mocks) are detected and not waited on.
    func freshFrame(after count: Int) async throws -> CGImage {
        let now = frames.frameCount
        let isStatic: Bool = lock.withLock {
            // Any frame since static mode began means the source is live again: wait for real frames.
            if let since = _staticSince, now > since { _staticSince = nil }
            return _staticSince != nil
        }
        if !isStatic {
            do { return try await frames.waitForFrame(after: count, timeout: timing.frameTimeout) } catch {
                let after = frames.frameCount
                if after == count, frames.latestFrame != nil {
                    lock.withLock { _staticSince = after }
                    log.debug("control", "No new frame within \(timing.frameTimeout)s (still screen); using the latest until frames flow again")
                }
            }
        }
        return try liveFrame()
    }

    /// The latest frame, but only while capture is actually running: after an unplug or a capture error the
    /// last picture is stale and must not be handed out as if it were live.
    func liveFrame() throws -> CGImage {
        guard case .running = frames.state.value, let f = frames.latestFrame else { throw noFrameError() }
        return f
    }

    func resultScreenshot(settleMs: Int) async throws -> Screenshot {
        try await sleep(ms: settleMs)
        _ = try? await freshFrame(after: frames.frameCount)
        return try await screenshot(includeText: true)
    }

    func geometry(for frameSize: CGSize, frame: CGImage) throws -> ScreenGeometry {
        if let r = renderer as? ImageScreenshotRenderer { return r.geometry(forFrameSize: frameSize) }
        if let s = lock.withLock({ _lastScreenshotSize }) {
            return ScreenGeometry(frameSize: frameSize, screenshotWidth: Double(s.width))
        }
        let rendered = try renderer.render(frame)
        lock.withLock { _lastScreenshotSize = CGSize(width: rendered.image.width, height: rendered.image.height) }
        return ScreenGeometry(frameSize: frameSize, screenshotWidth: Double(rendered.image.width))
    }

    func loadCalibration() throws -> CalibrationData? {
        do { return try calibrationStore.load() } catch {
            throw OpenTapError.wrap(error, what: "Couldn't read the saved calibration", fix: "Run calibrate again")
        }
    }

    func requireHID(_ what: String) throws {
        let st = hid.state.value
        if st.isConnected { return }
        var why = "The iPhone hasn't connected to \"\(HIDDescriptor.deviceName)\" over Bluetooth yet"
        var fix = "On the iPhone open Settings > Bluetooth and tap \"\(HIDDescriptor.deviceName)\" (OpenTap must be running on the Mac)"
        switch st {
        case .off: why = "Bluetooth input hasn't been started in OpenTap"; fix = "Open OpenTap and finish the Bluetooth step of setup"
        case .connecting: why = "The Bluetooth connection is still being set up"; fix = "Wait a few seconds and try again"
        case .unavailable(let e), .failed(let e): why = e.why; fix = e.fix
        case .advertising, .connected: break
        }
        throw OpenTapError(.hidNotConnected, what: "Can't \(what): the iPhone isn't connected as a Bluetooth keyboard/mouse", why: why, fix: fix)
    }

    func noFrameError() -> OpenTapError {
        switch frames.state.value {
        case .failed(let e): return e
        case .waitingForDevice:
            return OpenTapError(.noFrame, what: "No iPhone screen yet", why: "No iPhone screen is visible to the Mac",
                                fix: "Plug the iPhone in with a USB cable, unlock it and tap Trust")
        case .starting:
            return OpenTapError(.noFrame, what: "No iPhone screen yet", why: "Screen capture is still starting",
                                fix: "Wait a couple of seconds and try again")
        case .idle:
            return OpenTapError(.noFrame, what: "No iPhone screen", why: "Screen capture hasn't been started",
                                fix: "Open OpenTap and finish the screen step of setup")
        case .running:
            return OpenTapError(.noFrame, what: "No iPhone screen yet", why: "Capture is running but no frame has arrived",
                                fix: "Unlock the iPhone and wake its screen, then try again")
        }
    }

    func pointerSeen() {
        lock.withLock { _pointerMisses = 0 }
        if statusModel.snapshot.value[.assistiveTouch].health != .ok {
            statusModel.set(.assistiveTouch, .ok("Pointer visible"))
        }
    }

    func pointerMissed() {
        let misses: Int = lock.withLock { _pointerMisses += 1; return _pointerMisses }
        log.warning("control", "Couldn't see the pointer after moving it (\(misses) in a row)")
        if misses >= 3 { statusModel.set(.assistiveTouch, .failed(Self.pointerNotSeenError())) }
    }

    static func pointerNotSeenError() -> OpenTapError {
        OpenTapError(.assistiveTouchOff, what: "Couldn't see the pointer on the iPhone screen",
                     why: "AssistiveTouch looks off (iOS only shows a mouse pointer with AssistiveTouch on), or the pointer is hidden",
                     fix: "On the iPhone: Settings > Accessibility > Touch > AssistiveTouch, turn it on; keep the iPhone unlocked")
    }

    /// True when two frames differ beyond noise (used to check that Home did something).
    static func framesDiffer(_ a: CGImage, _ b: CGImage) -> Bool {
        guard let ga = PointerGrayImage(a, width: 48, height: 96), let gb = PointerGrayImage(b, width: 48, height: 96) else { return true }
        var total = 0
        for i in 0..<ga.pixels.count { total += abs(Int(ga.pixels[i]) - Int(gb.pixels[i])) }
        return Double(total) / Double(ga.pixels.count) > 3
    }

    func fmt(_ v: Double) -> String { Self.fmt(v) }

    /// Never traps: Int(v) is only used for whole numbers well inside Int's range.
    static func fmt(_ v: Double) -> String {
        guard v.isFinite else { return v.isNaN ? "NaN" : (v < 0 ? "-infinity" : "infinity") }
        if abs(v) < 1e15, v.rounded() == v { return String(Int(v)) }
        if abs(v) < 1e15 { return String(format: "%.1f", v) }
        return String(format: "%g", v)
    }
}

/// Serializes actions: only one gesture drives the pointer at a time (MCP calls can arrive concurrently).
actor ActionGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    nonisolated func serialized<T>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        do {
            let r = try await body()
            await release()
            return r
        } catch {
            await release()
            throw error
        }
    }
}
