import Foundation
import IOBluetooth

/// Owner: bluetooth. Classic BT HID device via IOBluetooth: SDP record, device class, L2CAP 0x11/0x13, 0xA1 input reports.
public final class BluetoothHIDTransport: HIDTransport {
    public let state = StateChannel<HIDConnectionState>(.off)
    private let log: Log

    public init(log: Log) { self.log = log }

    public func start() async throws {
        let e = OpenTapError.notImplemented("Bluetooth keyboard and mouse", module: "Bluetooth")
        state.send(.unavailable(e))
        throw e
    }

    public func stop() { state.send(.off) }

    public func send(_ report: HIDReport) async throws {
        throw OpenTapError(.hidNotConnected, what: "Couldn't send input to the iPhone",
                           why: "The iPhone is not connected to OpenTap over Bluetooth",
                           fix: "On the iPhone open Settings > Bluetooth and tap \"OpenTap\"")
    }
}
