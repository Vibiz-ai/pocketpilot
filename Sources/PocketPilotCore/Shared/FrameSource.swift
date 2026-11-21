import CoreGraphics
import Foundation

public enum FrameSourceState: Equatable, Sendable {
    case idle
    /// Running but no iPhone capture device is visible yet.
    case waitingForDevice
    case starting
    /// Frames are flowing.
    case running(deviceName: String)
    case failed(PocketPilotError)
}

/// The live iPhone screen. Implemented by Capture/ (AVFoundation) and Mock/.
public protocol FrameSource: AnyObject {
    var state: StateChannel<FrameSourceState> { get }
    /// Most recent full-resolution frame (top-left origin), nil until the first frame arrives.
    var latestFrame: CGImage? { get }
    /// Pixel size of `latestFrame`.
    var frameSize: CGSize? { get }
    /// Increments for every frame received; use it to wait for a *fresh* frame after an action.
    var frameCount: Int { get }
    /// Starts capture. Throws PocketPilotError (.permissionDenied, .noDevice, .captureFailed).
    func start() async throws
    func stop()
}

public extension FrameSource {
    /// Waits until a frame newer than `after` arrives, or throws `.timeout`.
    func waitForFrame(after count: Int, timeout: TimeInterval = 2.0) async throws -> CGImage {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if frameCount > count, let f = latestFrame { return f }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        throw PocketPilotError(.timeout,
                           what: "No new screen frame arrived",
                           why: "The iPhone screen stream stopped updating for \(timeout)s",
                           fix: "Check the USB cable, unlock the iPhone, and make sure the Screen pill is green")
    }
}

/// Turns a full-resolution frame into the screenshot handed to agents
/// (downscaled to `ScreenGeometry.defaultScreenshotWidth`, encoded). Implemented in Capture/.
public protocol ScreenshotRenderer: AnyObject {
    func render(_ frame: CGImage) throws -> RenderedScreenshot
}

public enum ImageFormat: String, Codable, Sendable {
    case jpeg, png
    public var mimeType: String { self == .jpeg ? "image/jpeg" : "image/png" }
}

public struct RenderedScreenshot {
    /// The downscaled image (in screenshot space); OCR runs on this so coordinates match.
    public var image: CGImage
    public var data: Data
    public var format: ImageFormat
    public init(image: CGImage, data: Data, format: ImageFormat) {
        self.image = image; self.data = data; self.format = format
    }
}

/// Conversions between full-resolution frame pixels and screenshot space.
public struct ScreenGeometry: Codable, Equatable, Sendable {
    public static let defaultScreenshotWidth: Double = 590

    public var frameSize: CGSize
    public var screenshotSize: CGSize

    public init(frameSize: CGSize, screenshotWidth: Double = ScreenGeometry.defaultScreenshotWidth) {
        self.frameSize = frameSize
        let w = min(screenshotWidth, Double(frameSize.width))
        let scale = frameSize.width > 0 ? w / Double(frameSize.width) : 1
        self.screenshotSize = CGSize(width: w.rounded(), height: (Double(frameSize.height) * scale).rounded())
    }

    /// screenshot px per frame px.
    public var scale: Double { frameSize.width > 0 ? Double(screenshotSize.width / frameSize.width) : 1 }

    public func toScreenshot(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: p.y * scale) }
    public func toFrame(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / scale, y: p.y / scale) }
    public func contains(screenshotPoint p: CGPoint) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x <= screenshotSize.width && p.y <= screenshotSize.height
    }
}
