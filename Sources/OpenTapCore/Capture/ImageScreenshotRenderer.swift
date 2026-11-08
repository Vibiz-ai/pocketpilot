import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Owner: capture. Downscales a frame to screenshot space and encodes it (JPEG by default).
///
/// The output size always follows `ScreenGeometry(frameSize:screenshotWidth:)`, so coordinates in the
/// returned image map back to frame pixels with that same geometry. Frames narrower than `targetWidth`
/// are never upscaled.
public final class ImageScreenshotRenderer: ScreenshotRenderer {
    public var targetWidth: Double
    public var format: ImageFormat
    /// 0...1, used for JPEG only.
    public var jpegQuality: Double

    public init(targetWidth: Double = ScreenGeometry.defaultScreenshotWidth, format: ImageFormat = .jpeg, jpegQuality: Double = 0.7) {
        self.targetWidth = targetWidth; self.format = format; self.jpegQuality = jpegQuality
    }

    /// Geometry this renderer uses for a frame of the given size.
    public func geometry(forFrameSize size: CGSize) -> ScreenGeometry {
        ScreenGeometry(frameSize: size, screenshotWidth: targetWidth)
    }

    public func render(_ frame: CGImage) throws -> RenderedScreenshot {
        guard targetWidth > 0 else {
            throw OpenTapError.invalidArgument("targetWidth", why: "The screenshot width must be greater than 0 (got \(targetWidth))",
                                               fix: "Use a width such as \(Int(ScreenGeometry.defaultScreenshotWidth))")
        }
        guard frame.width > 0, frame.height > 0 else {
            throw OpenTapError(.noFrame, what: "Couldn't make a screenshot",
                               why: "The latest iPhone frame is empty (\(frame.width)x\(frame.height) px)",
                               fix: "Wait for the live preview to show the iPhone screen, then try again")
        }
        let geo = geometry(forFrameSize: CGSize(width: frame.width, height: frame.height))
        let image = try Self.scale(frame, to: geo.screenshotSize)
        let data = try Self.encode(image, format: format, quality: jpegQuality)
        return RenderedScreenshot(image: image, data: data, format: format)
    }

    // MARK: - Helpers (public so other modules and tests can reuse them)

    /// Redraws `image` at `size` (rounded to whole pixels) into an sRGB 8-bit context. Returns the
    /// original image when the size already matches.
    public static func scale(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
        if w == image.width, h == image.height, image.bitsPerComponent == 8 { return image }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw OpenTapError(.captureFailed, what: "Couldn't scale the iPhone frame",
                               why: "CoreGraphics could not create a \(w)x\(h) drawing context (out of memory?)",
                               fix: "Close other heavy apps and try again; if it persists, restart OpenTap")
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else {
            throw OpenTapError(.captureFailed, what: "Couldn't scale the iPhone frame",
                               why: "CoreGraphics returned no image after drawing",
                               fix: "Try again; if it persists, restart OpenTap")
        }
        return out
    }

    /// Encodes `image` as JPEG (with `quality` 0...1) or PNG.
    public static func encode(_ image: CGImage, format: ImageFormat, quality: Double = 0.7) throws -> Data {
        let data = NSMutableData()
        let type = (format == .jpeg ? UTType.jpeg : UTType.png).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw OpenTapError(.captureFailed, what: "Couldn't encode the screenshot",
                               why: "ImageIO has no \(format.rawValue.uppercased()) encoder available",
                               fix: "Switch the screenshot format to \(format == .jpeg ? "png" : "jpeg")")
        }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, quality)) }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw OpenTapError(.captureFailed, what: "Couldn't encode the screenshot",
                               why: "ImageIO failed to write the \(format.rawValue.uppercased()) data",
                               fix: "Try again; if it persists, switch the screenshot format")
        }
        return data as Data
    }

    /// Decodes JPEG/PNG data back into a CGImage (used by tests and previews).
    public static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
