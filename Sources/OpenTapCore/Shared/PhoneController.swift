import CoreGraphics
import Foundation

public enum ScrollDirection: String, Codable, Sendable, CaseIterable { case up, down, left, right }

/// Every high-level action. Coordinates are in the latest screenshot's space (origin top-left).
public enum PhoneAction: Equatable, Sendable {
    case tap(x: Double, y: Double)
    /// `occurrence` is 1-based (see `[RecognizedText].find`).
    case tapText(text: String, occurrence: Int)
    case longPress(x: Double, y: Double, durationMs: Int)
    case swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int)
    /// `amount` = fraction of the screen to scroll (0.1...1.0); "down" reveals content below.
    case scroll(direction: ScrollDirection, amount: Double)
    case typeText(text: String, submit: Bool)
    /// A `KeyCombo` string, e.g. "return", "cmd+space", "home".
    case pressKey(key: String)
    case openApp(name: String)
    case wait(ms: Int)

    /// MCP tool name of this action.
    public var name: String {
        switch self {
        case .tap: return "tap"
        case .tapText: return "tap_text"
        case .longPress: return "long_press"
        case .swipe: return "swipe"
        case .scroll: return "scroll"
        case .typeText: return "type_text"
        case .pressKey: return "press_key"
        case .openApp: return "open_app"
        case .wait: return "wait"
        }
    }
}

public struct Screenshot: Codable, Equatable, Sendable {
    public var imageData: Data
    public var format: ImageFormat
    /// Screenshot-space size; all coordinates for actions use this space.
    public var width: Int
    public var height: Int
    /// `FrameSource.frameCount` of the frame this came from.
    public var frameNumber: Int
    public var capturedAt: Date
    /// OCR results in screenshot space (nil when not requested).
    public var text: [RecognizedText]?

    public init(imageData: Data, format: ImageFormat, width: Int, height: Int, frameNumber: Int,
                capturedAt: Date = Date(), text: [RecognizedText]? = nil) {
        self.imageData = imageData; self.format = format; self.width = width; self.height = height
        self.frameNumber = frameNumber; self.capturedAt = capturedAt; self.text = text
    }

    public var base64: String { imageData.base64EncodedString() }
    public var mimeType: String { format.mimeType }
}

public struct ActionResult: Equatable, Sendable {
    /// Human-readable outcome, e.g. "Tapped (120, 340); pointer landed within 2px".
    public var summary: String
    /// Fresh screenshot taken after the action, always with OCR text.
    public var screenshot: Screenshot
    public init(summary: String, screenshot: Screenshot) { self.summary = summary; self.screenshot = screenshot }
}

public struct CalibrationProgress: Equatable, Sendable {
    public var fraction: Double
    public var message: String
    public init(fraction: Double, message: String) { self.fraction = fraction; self.message = message }
}

/// High-level phone driving used by MCP and the UI. Implemented by Control/ (on top of
/// FrameSource + TextRecognizer + HIDTransport + PointerLocator + CalibrationStore).
public protocol PhoneController: AnyObject {
    func screenshot(includeText: Bool) async throws -> Screenshot
    /// Performs one action and returns a fresh screenshot with OCR text.
    func perform(_ action: PhoneAction) async throws -> ActionResult
    /// Performs actions in order with one screenshot at the end. Stops at the first failure and throws
    /// an OpenTapError whose `what` names the failing step ("Step 3 (tap_text) failed: ...").
    func performBatch(_ actions: [PhoneAction]) async throws -> ActionResult
    /// Parks, measures the acceleration curve, saves it to the CalibrationStore, returns it.
    func calibrate(progress: @escaping (CalibrationProgress) -> Void) async throws -> CalibrationData
    func status() async -> StatusSnapshot
}
