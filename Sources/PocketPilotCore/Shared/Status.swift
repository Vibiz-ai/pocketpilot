import Foundation

public enum Component: String, Codable, Sendable, CaseIterable {
    case usb, screen, bluetooth, assistiveTouch, calibration, mcp

    public var title: String {
        switch self {
        case .usb: return "USB"
        case .screen: return "Screen"
        case .bluetooth: return "Bluetooth"
        case .assistiveTouch: return "AssistiveTouch"
        case .calibration: return "Calibration"
        case .mcp: return "MCP"
        }
    }
}

public enum ComponentHealth: String, Codable, Sendable { case unknown, pending, ok, failed }

public struct ComponentStatus: Codable, Equatable, Sendable {
    public var health: ComponentHealth
    /// Short live detail, e.g. "Lautaro's iPhone, iOS 18.1" or "Waiting for iPhone to connect".
    public var detail: String
    public var error: PocketPilotError?

    public init(_ health: ComponentHealth, _ detail: String, error: PocketPilotError? = nil) {
        self.health = health; self.detail = detail; self.error = error
    }
    public static let unknown = ComponentStatus(.unknown, "Not checked yet")
    public static func ok(_ detail: String) -> ComponentStatus { ComponentStatus(.ok, detail) }
    public static func pending(_ detail: String) -> ComponentStatus { ComponentStatus(.pending, detail) }
    public static func failed(_ error: PocketPilotError) -> ComponentStatus { ComponentStatus(.failed, error.what, error: error) }
}

public struct StatusSnapshot: Codable, Equatable, Sendable {
    public var components: [Component: ComponentStatus]
    public var device: DeviceInfo?
    public var screenshotWidth: Int?
    public var screenshotHeight: Int?

    public init(components: [Component: ComponentStatus] = Dictionary(uniqueKeysWithValues: Component.allCases.map { ($0, .unknown) }),
                device: DeviceInfo? = nil, screenshotWidth: Int? = nil, screenshotHeight: Int? = nil) {
        self.components = components; self.device = device
        self.screenshotWidth = screenshotWidth; self.screenshotHeight = screenshotHeight
    }

    public subscript(_ c: Component) -> ComponentStatus {
        get { components[c] ?? .unknown }
        set { components[c] = newValue }
    }

    /// Ready to drive the phone (everything except MCP is green).
    public var canControl: Bool {
        [Component.screen, .bluetooth, .assistiveTouch, .calibration].allSatisfy { self[$0].health == .ok }
    }
}

/// Thread-safe holder of the global status; the UI and MCP `status` tool read it.
public final class StatusModel: @unchecked Sendable {
    public let snapshot = StateChannel(StatusSnapshot())
    private let lock = NSLock()
    public init() {}

    public func update(_ mutate: (inout StatusSnapshot) -> Void) {
        let s: StatusSnapshot = lock.withLock { var s = snapshot.value; mutate(&s); return s }
        snapshot.send(s)
    }
    public func set(_ c: Component, _ status: ComponentStatus) { update { $0[c] = status } }
}
