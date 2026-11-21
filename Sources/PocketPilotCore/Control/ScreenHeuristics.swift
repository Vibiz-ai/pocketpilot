import CoreGraphics
import Foundation

/// Owner: control. Reads what state the iPhone is in from the OCR of a screenshot.
public enum ScreenHeuristics {
    public enum LockSignal: Equatable, Sendable {
        case none
        /// Big clock + weekday date and little else: the Lock Screen, or Notification Center (which looks the same).
        case likely
        /// Text only the Lock Screen / passcode screen shows ("Swipe up to open", "Enter Passcode").
        case certain
    }

    /// Lock Screen proper. (The passcode screen is not "locked" for us: taps and a keyboard both work there.)
    static let lockPhrases = ["swipe up to open", "swipe up to unlock", "press home to unlock", "press home to open"]
    static let passcodePhrases = ["enter passcode", "touch id or enter passcode", "face id or enter passcode"]
    static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    public static func lockSignal(_ texts: [RecognizedText], screenHeight: Double) -> LockSignal {
        let norm = texts.map { TextMatcher.normalize($0.text) }
        if norm.contains(where: { t in passcodePhrases.contains { t.contains($0) } }) { return .none }
        if norm.contains(where: { t in lockPhrases.contains { t.contains($0) } }) { return .certain }
        let h = max(1, screenHeight)
        let bigClock = zip(texts, norm).contains { item, t in
            isClock(t) && item.height >= 0.045 * h && item.y <= 0.45 * h
        }
        let dateLine = norm.contains { t in weekdays.contains { t.hasPrefix($0) } }
        return bigClock && dateLine ? .likely : .none
    }

    static func isClock(_ t: String) -> Bool {
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), parts[1].count == 2 else { return false }
        return (0...23).contains(h) && (0...59).contains(m)
    }

    /// Words only Spotlight's results list shows.
    static let spotlightMarkers = ["top hits", "siri suggestions", "search the web", "search web", "no results",
                                   "search in apps", "siri knowledge", "show more results"]

    /// True when, after Return, the screen still looks like Spotlight (so no app was launched).
    public static func spotlightStillOpen(_ texts: [RecognizedText], query: String) -> Bool {
        let norm = texts.map { TextMatcher.normalize($0.text) }
        return norm.contains { t in spotlightMarkers.contains { t == $0 || t.hasPrefix($0) } }
    }
}

extension HIDPhoneController {
    static func lockedError(_ what: String) -> PocketPilotError {
        PocketPilotError(.deviceLocked, what: what,
                     why: "The iPhone is on the Lock Screen, and iOS ignores keyboard input and taps there until it is unlocked",
                     fix: "Unlock the iPhone (Face ID, Touch ID or passcode) and try again; to keep it unlocked set Settings > Display & Brightness > Auto-Lock to Never while your agent works")
    }

    /// Checks the screenshot taken after `action`. Throws when the action evidently didn't work (locked iPhone,
    /// Spotlight found no app); returns a note to append to the summary otherwise.
    /// `before` is the frame from just before the action (pointer actions on the Lock Screen only fail when the
    /// screen didn't change at all).
    func checkOutcome(of action: PhoneAction, _ shot: Screenshot, before: CGImage?) throws -> String {
        if case .wait = action { return "" }
        let texts = shot.text ?? []
        let isKeyboard: Bool
        switch action {
        case .typeText, .pressKey, .openApp: isKeyboard = true
        default: isKeyboard = false
        }
        let verb = action.name.replacingOccurrences(of: "_", with: " ")
        switch ScreenHeuristics.lockSignal(texts, screenHeight: Double(shot.height)) {
        case .certain where isKeyboard:
            throw Self.lockedError("Couldn't \(verb): the iPhone is locked")
        case .certain:
            if let b = before, let after = frames.latestFrame, !Self.framesDiffer(b, after) {
                throw Self.lockedError("The \(verb) did nothing: the iPhone is locked")
            }
            return "; warning: the iPhone is on the Lock Screen; unlock it if the \(verb) didn't do what you expected"
        case .likely where isKeyboard:
            throw Self.lockedError("Couldn't \(verb): the iPhone looks locked")
        case .likely:
            return "; warning: the screen looks like the Lock Screen (or Notification Center); if nothing changed, unlock the iPhone"
        case .none: break
        }
        if case let .openApp(name) = action {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if ScreenHeuristics.spotlightStillOpen(texts, query: trimmed) {
                throw PocketPilotError(.appNotOpened, what: "Couldn't open \"\(trimmed)\"",
                                   why: "Spotlight is still showing after Return, so it found no app called \"\(trimmed)\"",
                                   fix: "Use the exact name shown under the app's icon, or go Home and tap_text it on the Home Screen")
            }
        }
        return ""
    }

    /// Updates the Screen pill from a screenshot's OCR: says so while the iPhone is on the Lock Screen and goes
    /// back to "Live" once it isn't.
    func noteLockState(_ texts: [RecognizedText], screenHeight: Double) {
        guard case .running(let name) = frames.state.value else { return }
        let current = statusModel.snapshot.value[.screen]
        let locked = ScreenHeuristics.lockSignal(texts, screenHeight: screenHeight) == .certain
        if locked {
            guard current.error?.code != .deviceLocked else { return }
            let e = Self.lockedError("\(name) is locked")
            statusModel.set(.screen, ComponentStatus(.pending, "Live from \(name), but the iPhone is locked", error: e))
        } else if current.error?.code == .deviceLocked {
            statusModel.set(.screen, .ok("Live from \(name)"))
        }
    }

    /// One AssistiveTouch check: wiggles the mouse by `dx` (and back) and looks for the pointer dot. Runs through
    /// the action gate so it can never interleave with a gesture or calibration. Returns the pointer position in
    /// frame pixels, or nil when no pointer appeared. "No new frame after the move" counts as no pointer (an
    /// iPhone only sends frames when its screen changes, and without AssistiveTouch a mouse move changes nothing).
    public func probePointer(dx: Int8) async throws -> CGPoint? {
        try await gate.serialized {
            try self.requireHID("look for the pointer")
            let before = try self.liveFrame()
            let count = self.frames.frameCount
            try await self.send(.mouse(MouseReport(dx: dx, dy: dx)))
            try await self.send(.mouse(MouseReport()))
            let after: CGImage
            do { after = try await self.frames.waitForFrame(after: count, timeout: 1.5) } catch {
                return nil
            }
            guard let hit = self.pointer.locate(in: after, hint: nil, previous: before), hit.confidence >= 0.5 else { return nil }
            self.pointerSeen()
            return hit.point
        }
    }
}
