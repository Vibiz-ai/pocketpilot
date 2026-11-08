import CoreGraphics
import Foundation

/// Owner: qa. Mock implementations of the hardware protocols backed by one MockPhone.

public final class MockFrameSource: FrameSource {
    public let phone: MockPhone
    public let state = StateChannel<FrameSourceState>(.idle)
    public var latestFrame: CGImage? { phone.render() }
    public var frameSize: CGSize? { phone.screenSize }
    public private(set) var frameCount: Int = 0
    public init(phone: MockPhone) { self.phone = phone }
    public func start() async throws {
        let e = OpenTapError.notImplemented("Mock screen", module: "Mock")
        state.send(.failed(e)); throw e
    }
    public func stop() { state.send(.idle) }
}

public final class MockHIDTransport: HIDTransport {
    public let phone: MockPhone
    public let state = StateChannel<HIDConnectionState>(.off)
    public init(phone: MockPhone) { self.phone = phone }
    public func start() async throws { state.send(.connected(hostName: phone.deviceInfo.name)) }
    public func stop() { state.send(.off) }
    public func send(_ report: HIDReport) async throws { phone.receive(report) }
}

public final class MockDeviceLink: DeviceLink {
    public let phone: MockPhone
    public let state = StateChannel<DeviceLinkState>(.idle)
    public init(phone: MockPhone) { self.phone = phone }
    public func start() async { state.send(.attached(phone.deviceInfo, trust: .paired)) }
    public func stop() { state.send(.idle) }
    public func isPaired() async throws -> Bool { true }
    public func pair() async throws {}
    public func assistiveTouchEnabled() async throws -> Bool { phone.assistiveTouchEnabled }
    public func setAssistiveTouch(_ enabled: Bool) async throws { phone.assistiveTouchEnabled = enabled }
}

/// Deterministic OCR: returns the phone's elements scaled into the given image's space (no Vision needed).
public final class MockTextRecognizer: TextRecognizer {
    public let phone: MockPhone
    public init(phone: MockPhone) { self.phone = phone }
    public func recognize(in image: CGImage) async throws -> [RecognizedText] {
        let s = Double(image.width) / Double(phone.screenSize.width)
        return phone.elements.map {
            RecognizedText(text: $0.text, x: Double($0.center.x) * s, y: Double($0.center.y) * s,
                           width: Double($0.text.count) * 10, height: 20, confidence: 1)
        }
    }
}

public final class MockPermissions: PermissionsProvider {
    public var statuses: [Permission: PermissionStatus]
    public init(_ statuses: [Permission: PermissionStatus] = [.camera: .granted, .bluetooth: .granted]) { self.statuses = statuses }
    public func status(_ p: Permission) -> PermissionStatus { statuses[p] ?? .notDetermined }
    public func request(_ p: Permission) async -> PermissionStatus { status(p) }
    public func openSettings(_ p: Permission) {}
}
