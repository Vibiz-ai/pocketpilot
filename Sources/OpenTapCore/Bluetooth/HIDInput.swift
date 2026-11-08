import Foundation

/// High-level input helpers on any HIDTransport (the real Bluetooth one or a mock).
/// Report pacing is the transport's job; these only add the hold times iOS needs to see a press.
public extension HIDTransport {
    /// Sends reports in order, waiting `gapMs` between them.
    func sendSequence(_ reports: [HIDReport], gapMs: Int = 0) async throws {
        for (i, r) in reports.enumerated() {
            if i > 0, gapMs > 0 { try await Task.sleep(nanoseconds: UInt64(gapMs) * 1_000_000) }
            try await send(r)
        }
    }

    /// Relative move, split into int8 reports (even split; pass `maxStep` to cap the per-report size).
    func mouseMove(dx: Int, dy: Int, buttons: MouseButtons = [], maxStep: Int = HIDReportSequence.maxStep) async throws {
        try await sendSequence(HIDReportSequence.move(dx: dx, dy: dy, buttons: buttons, maxStep: maxStep))
    }

    /// Presses (`down: true`) or releases all of `buttons`.
    func mouseButton(_ buttons: MouseButtons = .left, down: Bool) async throws {
        try await send(HIDReportSequence.mouseButtons(down ? buttons : []))
    }

    func click(_ button: MouseButtons = .left, holdMs: Int = 40) async throws {
        try await sendSequence(HIDReportSequence.click(button), gapMs: holdMs)
    }

    /// Wheel ticks, positive = scroll content up (wheel away from the user).
    func scrollWheel(_ ticks: Int) async throws {
        try await sendSequence(HIDReportSequence.scroll(ticks))
    }

    func keyPress(_ usage: UInt8, modifiers: KeyModifiers = [], holdMs: Int = 20) async throws {
        try await sendSequence(HIDReportSequence.keyTap(usage, modifiers: modifiers), gapMs: holdMs)
    }

    /// "return", "cmd+space", "home", ... (see KeyCombo.parse).
    func pressCombo(_ combo: KeyCombo, holdMs: Int = 30) async throws {
        try await sendSequence(HIDReportSequence.combo(combo), gapMs: holdMs)
    }

    /// Types printable ASCII (plus newline/tab) with a US layout. Validates the whole string before sending anything.
    func typeASCII(_ text: String, holdMs: Int = 10, gapMs: Int = 15) async throws {
        let taps = try HIDReportSequence.type(text)
        for (i, tap) in taps.enumerated() {
            if i > 0, gapMs > 0 { try await Task.sleep(nanoseconds: UInt64(gapMs) * 1_000_000) }
            try await sendSequence(tap, gapMs: holdMs)
        }
    }

    /// Consumer control press + release, e.g. ConsumerUsage.acHome or .volumeUp.
    func consumer(_ usage: UInt16, holdMs: Int = 40) async throws {
        try await sendSequence(HIDReportSequence.consumerTap(usage), gapMs: holdMs)
    }

    /// Releases every key, button and consumer usage (safe to call after an interrupted action).
    func releaseAll() async throws {
        try await send(.keyboard(.released))
        try await send(.mouse(MouseReport()))
        try await send(.consumer(.released))
    }
}
