import Foundation

public struct DeviceInfo: Codable, Equatable, Sendable {
    public var udid: String
    /// User-visible name, e.g. "Lautaro's iPhone".
    public var name: String
    /// Marketing-ish model, e.g. "iPhone" (DeviceClass).
    public var model: String
    /// e.g. "iPhone16,2".
    public var productType: String
    /// e.g. "18.1".
    public var iosVersion: String

    public init(udid: String, name: String, model: String, productType: String, iosVersion: String) {
        self.udid = udid; self.name = name; self.model = model; self.productType = productType; self.iosVersion = iosVersion
    }
}

public enum TrustState: String, Codable, Sendable {
    case unknown
    case notPaired
    /// Pair requested; the iPhone is showing "Trust This Computer?".
    case awaitingUserTrust
    case paired
    /// Device is locked; it must be unlocked before pairing / reading values.
    case locked
    /// The user tapped "Don't Trust".
    case denied
}

public enum DeviceLinkState: Equatable, Sendable {
    /// MobileDevice.framework or required symbols missing: show manual instructions instead.
    case unavailable(PocketPilotError)
    case idle
    case noDevice
    case attached(DeviceInfo, trust: TrustState)

    public var device: DeviceInfo? { if case .attached(let d, _) = self { return d }; return nil }
}

/// USB / lockdown link to the iPhone (MobileDevice.framework via dlopen). Implemented by Device/ and Mock/.
/// Must never crash if the private framework is missing: report `.unavailable` with manual fix steps.
public protocol DeviceLink: AnyObject {
    var state: StateChannel<DeviceLinkState> { get }
    /// Starts attach/detach notifications.
    func start() async
    func stop()
    func isPaired() async throws -> Bool
    /// Triggers "Trust This Computer?" and returns once paired. Throws .deviceLocked / .notPaired (denied) / .timeout.
    func pair() async throws
    /// Reads com.apple.Accessibility / AssistiveTouchEnabledByiTunes.
    func assistiveTouchEnabled() async throws -> Bool
    func setAssistiveTouch(_ enabled: Bool) async throws
}
