import CoreGraphics
import Foundation

/// Owner: qa. A simulated iPhone shared by the Mock* components:
/// renders a fake screen with text (CoreGraphics), moves a pointer dot with an iOS-like acceleration curve
/// from relative HID mouse reports, records every HID report, and reacts to clicks/keys.
public final class MockPhone: @unchecked Sendable {
    public struct Element: Equatable, Sendable {
        public var text: String
        /// Centre in screen pixels (frame space), top-left origin.
        public var center: CGPoint
        public init(text: String, center: CGPoint) { self.text = text; self.center = center }
    }

    public let screenSize: CGSize
    public let deviceInfo: DeviceInfo
    public private(set) var elements: [Element]
    public private(set) var pointer: CGPoint
    public private(set) var receivedReports: [HIDReport] = []
    public let reports = EventChannel<HIDReport>()
    public var assistiveTouchEnabled: Bool = false

    public init(screenSize: CGSize = CGSize(width: 1179, height: 2556),
                deviceInfo: DeviceInfo = DeviceInfo(udid: "00008130-MOCK", name: "Mock iPhone", model: "iPhone",
                                                    productType: "iPhone16,2", iosVersion: "18.1"),
                elements: [Element] = []) {
        self.screenSize = screenSize
        self.deviceInfo = deviceInfo
        self.elements = elements
        self.pointer = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
    }

    /// iOS-like acceleration: pixels moved for one report of `units`. QA: replace with a realistic curve.
    public func pixels(forUnits units: Int) -> Double { Double(units) }

    public func receive(_ report: HIDReport) {
        receivedReports.append(report)
        reports.send(report)
    }

    /// QA: draw background, elements' text and the pointer dot.
    public func render() -> CGImage? { nil }
}
