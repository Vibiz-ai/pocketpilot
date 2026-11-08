import Foundation

/// Owner: device. dlopen(/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice) + dlsym AMDevice*.
/// Must degrade to `.unavailable(error with manual steps)` when the framework or any symbol is missing.
public final class MobileDeviceLink: DeviceLink {
    public let state = StateChannel<DeviceLinkState>(.idle)
    private let log: Log

    public init(log: Log) { self.log = log }

    public func start() async {
        state.send(.unavailable(OpenTapError.notImplemented("USB device detection", module: "Device")))
    }
    public func stop() { state.send(.idle) }

    public func isPaired() async throws -> Bool { throw OpenTapError.notImplemented("Pairing check", module: "Device") }
    public func pair() async throws { throw OpenTapError.notImplemented("Trust pairing", module: "Device") }
    public func assistiveTouchEnabled() async throws -> Bool {
        throw OpenTapError.notImplemented("Reading AssistiveTouch", module: "Device")
    }
    public func setAssistiveTouch(_ enabled: Bool) async throws {
        throw OpenTapError(.frameworkUnavailable, what: "Couldn't turn on AssistiveTouch automatically",
                           why: "USB AssistiveTouch control is not implemented in this build",
                           fix: "On the iPhone open Settings > Accessibility > Touch > AssistiveTouch and turn it on")
    }
}
