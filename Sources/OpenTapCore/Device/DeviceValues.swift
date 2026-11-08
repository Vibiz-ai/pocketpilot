import CoreFoundation
import Foundation

/// Lockdown keys/domains OpenTap reads or writes, and the user-facing manual fallbacks.
public enum LockdownKeys {
    public static let deviceName = "DeviceName"
    public static let deviceClass = "DeviceClass"
    public static let productType = "ProductType"
    public static let productVersion = "ProductVersion"
    public static let uniqueDeviceID = "UniqueDeviceID"

    public static let accessibilityDomain = "com.apple.Accessibility"
    public static let assistiveTouchKey = "AssistiveTouchEnabledByiTunes"

    /// Keys read for `DeviceInfo` (domain nil).
    public static let infoKeys = [deviceName, deviceClass, productType, productVersion, uniqueDeviceID]
}

public enum ManualSteps {
    public static let assistiveTouch = "On the iPhone open Settings > Accessibility > Touch > AssistiveTouch and turn it on"
    public static let trust = "Unlock the iPhone, unplug and replug the USB cable, then tap Trust on the \"Trust This Computer?\" alert and enter your passcode"
    public static let unlock = "Unlock your iPhone (Face ID, Touch ID or passcode) and keep it on the Home Screen"
    public static let resetTrust = "Unplug the iPhone, then on it open Settings > General > Transfer or Reset iPhone > Reset > Reset Location & Privacy, plug it back in and tap Trust"
}

/// Result codes returned by AMDevice* calls (mach_error_t, 0 = success).
/// Only the codes OpenTap reacts to are named; everything else is shown with its hex value.
public enum AMDResult: Equatable, Sendable {
    case ok
    /// Device has a passcode and is locked (kAMDPasswordProtectedError).
    case locked
    /// The user tapped "Don't Trust" (kAMDUserDeniedPairingError).
    case denied
    /// "Trust This Computer?" is showing and the user hasn't answered (kAMDPairingDialogResponsePendingError).
    case pending
    /// This Mac's pair record is missing/invalid (kAMDInvalidHostIDError).
    case notPaired
    case other(Int32)

    public static let passwordProtectedCode = Int32(bitPattern: 0xE800_001A)
    public static let userDeniedCode = Int32(bitPattern: 0xE800_0095)
    public static let dialogPendingCode = Int32(bitPattern: 0xE800_0096)
    public static let invalidHostIDCode = Int32(bitPattern: 0xE800_0007)

    public init(_ code: Int32) {
        switch code {
        case 0: self = .ok
        case Self.passwordProtectedCode: self = .locked
        case Self.userDeniedCode: self = .denied
        case Self.dialogPendingCode: self = .pending
        case Self.invalidHostIDCode: self = .notPaired
        default: self = .other(code)
        }
    }

    public static func hex(_ code: Int32) -> String { String(format: "0x%08X", UInt32(bitPattern: code)) }

    /// Converts a failed call into an OpenTapError that says what, why and how to fix. Returns nil for `.ok`.
    public static func error(_ code: Int32, what: String, deviceName: String = "the iPhone",
                             fallback: String = ManualSteps.trust) -> OpenTapError? {
        switch AMDResult(code) {
        case .ok: return nil
        case .locked:
            return OpenTapError(.deviceLocked, what: what, why: "\(deviceName) is locked",
                                fix: ManualSteps.unlock + ", then try again")
        case .denied:
            return OpenTapError(.notPaired, what: what, why: "\"Don't Trust\" was tapped on \(deviceName)",
                                fix: ManualSteps.resetTrust)
        case .pending:
            return OpenTapError(.notPaired, what: what,
                                why: "\(deviceName) is still showing \"Trust This Computer?\"",
                                fix: "Tap Trust on \(deviceName) and enter your passcode")
        case .notPaired:
            return OpenTapError(.notPaired, what: what, why: "This Mac is not trusted by \(deviceName)",
                                fix: ManualSteps.trust)
        case .other(let c):
            return OpenTapError(.io, what: what,
                                why: "MobileDevice returned error \(hex(c)) while talking to \(deviceName)",
                                fix: "Unplug and replug the USB cable, unlock the iPhone and try again. If it keeps failing: \(fallback)")
        }
    }
}

/// Parses lockdown values (CFTypes bridged to Swift) into OpenTap types.
public enum DeviceValueParser {
    /// Lenient boolean: CFBoolean/NSNumber, integer 0/1, or "true"/"false"/"yes"/"no"/"1"/"0" strings. nil if absent/unknown.
    public static func bool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.intValue != 0 }
        if let i = value as? Int { return i != 0 }
        if let s = value as? String {
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1", "on": return true
            case "false", "no", "0", "off": return false
            default: return nil
            }
        }
        return nil
    }

    public static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    /// Builds DeviceInfo from lockdown values, filling gaps with sensible fallbacks
    /// (an unpaired iPhone may refuse to give its name).
    public static func deviceInfo(udid: String?, values: [String: Any]) -> DeviceInfo {
        let model = string(values[LockdownKeys.deviceClass]) ?? "iPhone"
        let productType = string(values[LockdownKeys.productType]) ?? "unknown"
        let id = udid.flatMap { string($0) } ?? string(values[LockdownKeys.uniqueDeviceID]) ?? "unknown"
        let name = string(values[LockdownKeys.deviceName]) ?? model
        let version = string(values[LockdownKeys.productVersion]) ?? "unknown"
        return DeviceInfo(udid: id, name: name, model: model, productType: productType, iosVersion: version)
    }
}
