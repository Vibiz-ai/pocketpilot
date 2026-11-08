import Foundation

/// Owner: bluetooth. HID report descriptor (keyboard ID 1, mouse ID 2, consumer ID 3 — see Shared/HID.swift)
/// and the SDP service record dictionary.
public enum HIDDescriptor {
    /// Fill in: must describe exactly the payload layouts in Shared/HID.swift.
    public static let reportDescriptor: [UInt8] = []
    public static let deviceName = "OpenTap"
    public static let controlPSM: UInt16 = 0x11
    public static let interruptPSM: UInt16 = 0x13
}
