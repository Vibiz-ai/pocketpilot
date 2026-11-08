import Foundation

/// Report IDs used in OpenTap's HID report descriptor (Bluetooth/HIDDescriptor.swift must match).
public enum HIDReportID {
    public static let keyboard: UInt8 = 0x01
    public static let mouse: UInt8 = 0x02
    public static let consumer: UInt8 = 0x03
}

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let control = KeyModifiers(rawValue: 0x01)
    public static let shift   = KeyModifiers(rawValue: 0x02)
    public static let option  = KeyModifiers(rawValue: 0x04)
    public static let command = KeyModifiers(rawValue: 0x08)
}

public struct MouseButtons: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let left   = MouseButtons(rawValue: 0x01)
    public static let right  = MouseButtons(rawValue: 0x02)
    public static let middle = MouseButtons(rawValue: 0x04)
}

/// Boot-style keyboard input: modifiers, reserved, up to 6 key usages.
public struct KeyboardReport: Equatable, Codable, Sendable {
    public var modifiers: KeyModifiers
    public var keys: [UInt8]
    public init(modifiers: KeyModifiers = [], keys: [UInt8] = []) {
        self.modifiers = modifiers; self.keys = Array(keys.prefix(6))
    }
    public static let released = KeyboardReport()
    public var payload: [UInt8] {
        [modifiers.rawValue, 0x00] + keys + [UInt8](repeating: 0, count: 6 - keys.count)
    }
}

/// Relative mouse: buttons, dx, dy, wheel (all signed 8-bit, -127...127). +dx right, +dy down.
public struct MouseReport: Equatable, Codable, Sendable {
    public var buttons: MouseButtons
    public var dx: Int8
    public var dy: Int8
    public var wheel: Int8
    public init(buttons: MouseButtons = [], dx: Int8 = 0, dy: Int8 = 0, wheel: Int8 = 0) {
        self.buttons = buttons; self.dx = dx; self.dy = dy; self.wheel = wheel
    }
    public var payload: [UInt8] { [buttons.rawValue, UInt8(bitPattern: dx), UInt8(bitPattern: dy), UInt8(bitPattern: wheel)] }
}

/// Consumer control: one 16-bit usage, little-endian. usage 0 = released.
public struct ConsumerReport: Equatable, Codable, Sendable {
    public var usage: UInt16
    public init(usage: UInt16) { self.usage = usage }
    public static let released = ConsumerReport(usage: 0)
    public var payload: [UInt8] { [UInt8(usage & 0xFF), UInt8(usage >> 8)] }
}

public enum HIDReport: Equatable, Codable, Sendable {
    case keyboard(KeyboardReport)
    case mouse(MouseReport)
    case consumer(ConsumerReport)

    public var reportID: UInt8 {
        switch self {
        case .keyboard: return HIDReportID.keyboard
        case .mouse: return HIDReportID.mouse
        case .consumer: return HIDReportID.consumer
        }
    }
    public var payload: [UInt8] {
        switch self {
        case .keyboard(let r): return r.payload
        case .mouse(let r): return r.payload
        case .consumer(let r): return r.payload
        }
    }
    /// Bytes for the L2CAP interrupt channel: 0xA1 (DATA | Input) + report ID + payload.
    public var interruptPacket: [UInt8] { [0xA1, reportID] + payload }
}

public enum HIDConnectionState: Equatable, Sendable {
    case off
    /// Bluetooth is off/unsupported or permission denied.
    case unavailable(OpenTapError)
    /// SDP record published, Mac discoverable under `name`, waiting for the iPhone to connect.
    case advertising(name: String)
    /// One of the two L2CAP channels (control 0x11 / interrupt 0x13) is open.
    case connecting
    /// Both channels open: reports can be sent.
    case connected(hostName: String?)
    case failed(OpenTapError)

    public var isConnected: Bool { if case .connected = self { return true }; return false }
}

/// The Mac acting as a Bluetooth HID keyboard+mouse+consumer device. Implemented by Bluetooth/ and Mock/.
public protocol HIDTransport: AnyObject {
    var state: StateChannel<HIDConnectionState> { get }
    /// Publishes the SDP record, sets device class, becomes discoverable, listens on PSM 0x11/0x13.
    func start() async throws
    func stop()
    /// Sends one input report on the interrupt channel. Throws `.hidNotConnected` if not connected.
    func send(_ report: HIDReport) async throws
}
