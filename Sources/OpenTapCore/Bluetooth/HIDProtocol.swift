import Foundation

/// Bluetooth HIDP transaction types (high nibble of the first byte of every L2CAP HID message).
public enum HIDPMessageType: UInt8 {
    case handshake = 0x0, hidControl = 0x1, getReport = 0x4, setReport = 0x5
    case getProtocol = 0x6, setProtocol = 0x7, getIdle = 0x8, setIdle = 0x9, data = 0xA, datc = 0xB
}

/// HANDSHAKE result codes.
public enum HIDPHandshake: UInt8 {
    case successful = 0x0, notReady = 0x1, invalidReportID = 0x2, unsupportedRequest = 0x3
    case invalidParameter = 0x4, unknown = 0xE, fatal = 0xF

    public var message: [UInt8] { [(HIDPMessageType.handshake.rawValue << 4) | rawValue] }
}

/// HID_CONTROL operations.
public enum HIDPControlOperation: UInt8 {
    case nop = 0, hardReset = 1, softReset = 2, suspend = 3, exitSuspend = 4, virtualCableUnplug = 5
}

/// Report types in GET_REPORT / SET_REPORT / DATA parameters.
public enum HIDPReportType: UInt8 { case other = 0, input = 1, output = 2, feature = 3 }

/// Answers what the host (iPhone) sends on the HID control channel (PSM 0x11) and the interrupt channel (PSM 0x13).
/// Pure logic: no IOBluetooth, so it is unit tested.
public struct HIDPControlResponder: Equatable {
    public enum Event: Equatable {
        case none
        case protocolChanged(boot: Bool)
        case suspend
        case exitSuspend
        case virtualCableUnplug
        case reset
        /// Keyboard LEDs (caps lock etc.) the host set.
        case leds(UInt8)
        case ignored(String)
    }

    public struct Outcome: Equatable {
        /// Bytes to send back on the control channel, if any.
        public var reply: [UInt8]?
        public var event: Event
    }

    /// Report sizes (payload bytes, after the report ID) for each input report ID.
    public static let inputReportSizes: [UInt8: Int] = [
        HIDReportID.keyboard: 8, HIDReportID.mouse: 4, HIDReportID.consumer: 2,
    ]

    public private(set) var bootProtocol = false
    public private(set) var idleRate: UInt8 = 0
    public private(set) var leds: UInt8 = 0

    public init() {}

    /// One message received on the control channel.
    public mutating func handleControl(_ message: [UInt8]) -> Outcome {
        guard let header = message.first else { return Outcome(reply: nil, event: .ignored("empty control message")) }
        let param = header & 0x0F
        guard let type = HIDPMessageType(rawValue: header >> 4) else {
            return Outcome(reply: HIDPHandshake.unsupportedRequest.message,
                           event: .ignored(String(format: "unknown transaction 0x%02X", header)))
        }
        switch type {
        case .handshake:
            return Outcome(reply: nil, event: .ignored(String(format: "handshake 0x%X from host", param)))

        case .hidControl:
            switch HIDPControlOperation(rawValue: param) {
            case .suspend: return Outcome(reply: nil, event: .suspend)
            case .exitSuspend: return Outcome(reply: nil, event: .exitSuspend)
            case .virtualCableUnplug: return Outcome(reply: nil, event: .virtualCableUnplug)
            case .hardReset, .softReset: return Outcome(reply: nil, event: .reset)
            case .nop: return Outcome(reply: nil, event: .none)
            case nil: return Outcome(reply: HIDPHandshake.invalidParameter.message, event: .ignored("bad HID_CONTROL \(param)"))
            }

        case .getReport:
            return getReport(param: param, body: Array(message.dropFirst()))

        case .setReport:
            let reportType = HIDPReportType(rawValue: param & 0x03) ?? .other
            let body = Array(message.dropFirst())
            if reportType == .output {
                // Report mode: [id, leds]; boot mode: [leds].
                if bootProtocol, let l = body.first { leds = l; return Outcome(reply: HIDPHandshake.successful.message, event: .leds(l)) }
                if body.count >= 2, body[0] == HIDReportID.keyboard { leds = body[1]
                    return Outcome(reply: HIDPHandshake.successful.message, event: .leds(body[1])) }
                return Outcome(reply: HIDPHandshake.invalidReportID.message, event: .ignored("SET_REPORT output for unknown report"))
            }
            if let id = body.first, Self.inputReportSizes[id] != nil {
                return Outcome(reply: HIDPHandshake.successful.message, event: .none)
            }
            return Outcome(reply: HIDPHandshake.invalidReportID.message, event: .ignored("SET_REPORT for unknown report"))

        case .getProtocol:
            return Outcome(reply: [0xA0, bootProtocol ? 0x00 : 0x01], event: .none)

        case .setProtocol:
            let boot = (param & 0x01) == 0
            bootProtocol = boot
            return Outcome(reply: HIDPHandshake.successful.message, event: .protocolChanged(boot: boot))

        case .getIdle:
            return Outcome(reply: [0xA0, idleRate], event: .none)

        case .setIdle:
            idleRate = message.count > 1 ? message[1] : 0
            return Outcome(reply: HIDPHandshake.successful.message, event: .none)

        case .data, .datc:
            return Outcome(reply: nil, event: handleOutputData(message))
        }
    }

    /// One message received on the interrupt channel (host output reports, 0xA2).
    public mutating func handleInterrupt(_ message: [UInt8]) -> Event {
        handleOutputData(message)
    }

    private mutating func handleOutputData(_ message: [UInt8]) -> Event {
        guard let header = message.first else { return .ignored("empty data message") }
        guard HIDPReportType(rawValue: header & 0x03) == .output else {
            return .ignored(String(format: "data 0x%02X from host", header))
        }
        let body = Array(message.dropFirst())
        if bootProtocol, let l = body.first { leds = l; return .leds(l) }
        if body.count >= 2, body[0] == HIDReportID.keyboard { leds = body[1]; return .leds(body[1]) }
        return .ignored("output report for unknown report")
    }

    private func getReport(param: UInt8, body: [UInt8]) -> Outcome {
        let reportType = HIDPReportType(rawValue: param & 0x03) ?? .other
        let hasBufferSize = (param & 0x08) != 0
        var rest = body[...]
        var reportID: UInt8? = nil
        if !bootProtocol {
            guard let id = rest.first else {
                return Outcome(reply: HIDPHandshake.invalidParameter.message, event: .ignored("GET_REPORT without report ID"))
            }
            reportID = id
            rest = rest.dropFirst()
        }
        var maxBytes: Int? = nil
        if hasBufferSize, rest.count >= 2 {
            maxBytes = Int(rest[rest.startIndex]) | (Int(rest[rest.startIndex + 1]) << 8)
        }
        let dataHeader = (HIDPMessageType.data.rawValue << 4) | reportType.rawValue
        var reply: [UInt8]
        switch reportType {
        case .input:
            let id = reportID ?? HIDReportID.keyboard
            guard let size = Self.inputReportSizes[id] else {
                return Outcome(reply: HIDPHandshake.invalidReportID.message, event: .ignored("GET_REPORT for unknown report \(id)"))
            }
            // Nothing pressed, no motion: an all-zero report is the current state between actions.
            reply = [dataHeader] + (reportID.map { [$0] } ?? []) + [UInt8](repeating: 0, count: size)
        case .output:
            guard (reportID ?? HIDReportID.keyboard) == HIDReportID.keyboard else {
                return Outcome(reply: HIDPHandshake.invalidReportID.message, event: .ignored("GET_REPORT output for unknown report"))
            }
            reply = [dataHeader] + (reportID.map { [$0] } ?? []) + [leds]
        case .feature, .other:
            return Outcome(reply: HIDPHandshake.invalidReportID.message, event: .ignored("GET_REPORT feature (none defined)"))
        }
        if let m = maxBytes, reply.count - 1 > m { reply = Array(reply.prefix(1 + m)) }
        return Outcome(reply: reply, event: .none)
    }
}

/// One relative mouse step, as sent in a single report.
public struct HIDMouseStep: Equatable, Sendable {
    public var dx: Int8
    public var dy: Int8
    public init(dx: Int8, dy: Int8) { self.dx = dx; self.dy = dy }
}

/// Turns high-level input into sequences of HID reports. Pure logic, unit tested.
public enum HIDReportSequence {
    public static let maxStep = 127

    /// Splits a move into as few reports as possible (each axis within ±maxStep), spread evenly so both
    /// axes finish together. The sum of the steps equals (dx, dy) exactly.
    public static func moveSteps(dx: Int, dy: Int, maxStep: Int = maxStep) -> [HIDMouseStep] {
        let m = max(1, min(maxStep, 127))
        let n = max((abs(dx) + m - 1) / m, (abs(dy) + m - 1) / m)
        guard n > 0 else { return [] }
        func share(_ total: Int, _ i: Int) -> Int8 {
            let end: Int = total * (i + 1) / n
            let start: Int = total * i / n
            return Int8(end - start)
        }
        return (0..<n).map { i in HIDMouseStep(dx: share(dx, i), dy: share(dy, i)) }
    }

    /// A move made of reports of exactly `step` units per axis (the last one carries the remainder).
    /// Used by calibration, where the step size changes how far iOS's acceleration carries the pointer.
    public static func uniformSteps(dx: Int, dy: Int, step: Int) -> [HIDMouseStep] {
        let s = max(1, min(abs(step), 127))
        var rx = dx, ry = dy
        var out: [HIDMouseStep] = []
        while rx != 0 || ry != 0 {
            let sx = rx.signum() * min(abs(rx), s)
            let sy = ry.signum() * min(abs(ry), s)
            out.append(HIDMouseStep(dx: Int8(sx), dy: Int8(sy)))
            rx -= sx; ry -= sy
        }
        return out
    }

    public static func move(dx: Int, dy: Int, buttons: MouseButtons = [], maxStep: Int = maxStep) -> [HIDReport] {
        moveSteps(dx: dx, dy: dy, maxStep: maxStep).map { .mouse(MouseReport(buttons: buttons, dx: $0.dx, dy: $0.dy)) }
    }

    public static func mouseButtons(_ buttons: MouseButtons) -> HIDReport { .mouse(MouseReport(buttons: buttons)) }

    public static func click(_ button: MouseButtons = .left) -> [HIDReport] {
        [mouseButtons(button), mouseButtons([])]
    }

    /// Wheel ticks (positive = up/away), chunked into ±127 per report.
    public static func scroll(_ ticks: Int) -> [HIDReport] {
        moveSteps(dx: ticks, dy: 0).map { .mouse(MouseReport(wheel: $0.dx)) }
    }

    /// Press then release one key. With modifiers, the modifiers go down first and come up last,
    /// which iOS needs for shortcuts like cmd+space.
    public static func keyTap(_ usage: UInt8, modifiers: KeyModifiers = []) -> [HIDReport] {
        if modifiers.isEmpty {
            return [.keyboard(KeyboardReport(keys: [usage])), .keyboard(.released)]
        }
        return [
            .keyboard(KeyboardReport(modifiers: modifiers)),
            .keyboard(KeyboardReport(modifiers: modifiers, keys: [usage])),
            .keyboard(KeyboardReport(modifiers: modifiers)),
            .keyboard(.released),
        ]
    }

    public static func keyTap(_ stroke: KeyStroke) -> [HIDReport] { keyTap(stroke.usage, modifiers: stroke.modifiers) }

    public static func consumerTap(_ usage: UInt16) -> [HIDReport] {
        [.consumer(ConsumerReport(usage: usage)), .consumer(.released)]
    }

    public static func combo(_ combo: KeyCombo) -> [HIDReport] {
        switch combo.target {
        case .key(let u): return keyTap(u, modifiers: combo.modifiers)
        case .consumer(let u):
            guard !combo.modifiers.isEmpty else { return consumerTap(u) }
            return [.keyboard(KeyboardReport(modifiers: combo.modifiers))] + consumerTap(u) + [.keyboard(.released)]
        }
    }

    /// US-layout typing, one key tap per character. Throws `.invalidArgument` naming the first character
    /// that has no US key.
    public static func type(_ text: String) throws -> [[HIDReport]] {
        try USKeyboardLayout.strokes(for: text).map(keyTap)
    }
}
