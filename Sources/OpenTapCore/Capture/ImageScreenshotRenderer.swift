import CoreGraphics
import Foundation
import ImageIO

/// Owner: capture. Downscales a frame to screenshot space and encodes it (JPEG by default).
public final class ImageScreenshotRenderer: ScreenshotRenderer {
    public var targetWidth: Double
    public var format: ImageFormat
    public var jpegQuality: Double

    public init(targetWidth: Double = ScreenGeometry.defaultScreenshotWidth, format: ImageFormat = .jpeg, jpegQuality: Double = 0.7) {
        self.targetWidth = targetWidth; self.format = format; self.jpegQuality = jpegQuality
    }

    public func render(_ frame: CGImage) throws -> RenderedScreenshot {
        throw OpenTapError.notImplemented("Screenshot encoding", module: "Capture")
    }
}
