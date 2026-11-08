import CoreGraphics
import CoreVideo
import XCTest
@testable import OpenTapCore

final class ScreenGeometryCaptureTests: XCTestCase {
    func testIPhoneFrameMapsToDefaultWidth() {
        let g = ScreenGeometry(frameSize: CGSize(width: 1179, height: 2556))
        XCTAssertEqual(g.screenshotSize.width, 590)
        XCTAssertEqual(g.screenshotSize.height, (2556.0 * 590 / 1179).rounded())
        XCTAssertEqual(g.scale, 590.0 / 1179, accuracy: 1e-9)
    }

    func testRoundTripFrameAndScreenshotPoints() {
        let g = ScreenGeometry(frameSize: CGSize(width: 1290, height: 2796))
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 295, y: 640), CGPoint(x: 589.5, y: 1278)] {
            let back = g.toScreenshot(g.toFrame(p))
            XCTAssertEqual(back.x, p.x, accuracy: 1e-9); XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        }
        let centreFrame = g.toFrame(CGPoint(x: g.screenshotSize.width / 2, y: g.screenshotSize.height / 2))
        XCTAssertEqual(centreFrame.x, 645, accuracy: 0.5)
        XCTAssertEqual(centreFrame.y, 1398, accuracy: 1.5)
    }

    func testNoUpscaleForSmallFrames() {
        let g = ScreenGeometry(frameSize: CGSize(width: 400, height: 800))
        XCTAssertEqual(g.screenshotSize, CGSize(width: 400, height: 800))
        XCTAssertEqual(g.scale, 1)
    }

    func testContains() {
        let g = ScreenGeometry(frameSize: CGSize(width: 1180, height: 2560))
        XCTAssertTrue(g.contains(screenshotPoint: CGPoint(x: 10, y: 10)))
        XCTAssertFalse(g.contains(screenshotPoint: CGPoint(x: -1, y: 10)))
        XCTAssertFalse(g.contains(screenshotPoint: CGPoint(x: 10, y: 1281)))
    }
}

final class ImageScreenshotRendererTests: XCTestCase {
    /// Left half red, right half blue, with a green 40x40 square at frame (100,200) from the top-left.
    static func makeFrame(width: Int = 1180, height: Int = 2560) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        // CG origin is bottom-left; top-left y=200 -> bottom-left y = height-200-40.
        ctx.fill(CGRect(x: 100, y: height - 200 - 40, width: 40, height: 40))
        return ctx.makeImage()!
    }

    static func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = (y * img.width + x) * 4   // bitmap memory row 0 is the top row
        return (p[i], p[i + 1], p[i + 2])
    }

    func testJPEGRenderScalesAndKeepsAspect() throws {
        let frame = Self.makeFrame()
        let r = try ImageScreenshotRenderer().render(frame)
        XCTAssertEqual(r.format, .jpeg)
        XCTAssertEqual(r.image.width, 590)
        XCTAssertEqual(r.image.height, 1280)
        XCTAssertEqual(Array(r.data.prefix(2)), [0xFF, 0xD8], "JPEG SOI marker")
        let decoded = try XCTUnwrap(ImageScreenshotRenderer.decode(r.data))
        XCTAssertEqual(decoded.width, 590); XCTAssertEqual(decoded.height, 1280)
        XCTAssertFalse(r.data.base64EncodedString().isEmpty)
    }

    func testPNGRenderAndOrientationPreserved() throws {
        let frame = Self.makeFrame()
        let r = try ImageScreenshotRenderer(format: .png).render(frame)
        XCTAssertEqual(Array(r.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let img = try XCTUnwrap(ImageScreenshotRenderer.decode(r.data))
        // Green square at frame (100..140, 200..240) -> screenshot (50..70, 100..120); centre (60, 110).
        let g = ScreenGeometry(frameSize: CGSize(width: frame.width, height: frame.height))
        let c = g.toScreenshot(CGPoint(x: 120, y: 220))
        let px = Self.pixel(img, Int(c.x), Int(c.y))
        XCTAssertGreaterThan(px.g, 200); XCTAssertLessThan(px.r, 60)
        let left = Self.pixel(img, 20, 600), right = Self.pixel(img, 570, 600)
        XCTAssertGreaterThan(left.r, 200); XCTAssertGreaterThan(right.b, 200)
    }

    func testJPEGQualityAffectsSize() throws {
        let frame = Self.makeFrame()
        let lo = try ImageScreenshotRenderer(format: .jpeg, jpegQuality: 0.1).render(frame)
        let hi = try ImageScreenshotRenderer(format: .jpeg, jpegQuality: 1.0).render(frame)
        XCTAssertLessThan(lo.data.count, hi.data.count)
    }

    func testCustomWidth() throws {
        let r = try ImageScreenshotRenderer(targetWidth: 295).render(Self.makeFrame())
        XCTAssertEqual(r.image.width, 295); XCTAssertEqual(r.image.height, 640)
    }

    func testInvalidWidthSaysWhyAndFix() {
        XCTAssertThrowsError(try ImageScreenshotRenderer(targetWidth: 0).render(Self.makeFrame())) { err in
            let e = err as! OpenTapError
            XCTAssertEqual(e.code, .invalidArgument)
            XCTAssertFalse(e.why.isEmpty); XCTAssertFalse(e.fix.isEmpty)
        }
    }
}

final class ScreenCaptureFrameSourceTests: XCTestCase {
    func testDeviceFilter() {
        XCTAssertTrue(ScreenCaptureFrameSource.isScreenCaptureDevice(modelID: "iOS Device", manufacturer: "Apple Inc.", hasMuxedMedia: true))
        XCTAssertTrue(ScreenCaptureFrameSource.isScreenCaptureDevice(modelID: "iOS Device", manufacturer: "", hasMuxedMedia: false))
        XCTAssertFalse(ScreenCaptureFrameSource.isScreenCaptureDevice(modelID: "UVC Camera VendorID_1133", manufacturer: "Logitech", hasMuxedMedia: false))
        XCTAssertFalse(ScreenCaptureFrameSource.isScreenCaptureDevice(modelID: "Studio Display", manufacturer: "Apple Inc.", hasMuxedMedia: false))
    }

    func testNormalizedID() {
        XCTAssertEqual(ScreenCaptureFrameSource.normalizedID("00008110-001A2B3C4D5E"), "00008110001a2b3c4d5e")
    }

    func testPixelBufferToCGImage() throws {
        let w = 64, h = 32
        var pbOut: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pbOut), kCVReturnSuccess)
        let pb = try XCTUnwrap(pbOut)
        CVPixelBufferLockBaseAddress(pb, [])
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * bpr + x * 4
                // Top half red, bottom half blue (BGRA byte order).
                if y < h / 2 { base[i] = 0; base[i + 1] = 0; base[i + 2] = 255 } else { base[i] = 255; base[i + 1] = 0; base[i + 2] = 0 }
                base[i + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        let img = try XCTUnwrap(ScreenCaptureFrameSource.makeImage(from: pb))
        XCTAssertEqual(img.width, w); XCTAssertEqual(img.height, h)
        let top = ImageScreenshotRendererTests.pixel(img, 10, 2), bottom = ImageScreenshotRendererTests.pixel(img, 10, h - 3)
        XCTAssertGreaterThan(top.r, 200); XCTAssertLessThan(top.b, 50)
        XCTAssertGreaterThan(bottom.b, 200); XCTAssertLessThan(bottom.r, 50)
    }

    func testRejectsUnsupportedPixelFormat() throws {
        var pbOut: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pbOut)
        let pb = try XCTUnwrap(pbOut)
        XCTAssertNil(ScreenCaptureFrameSource.makeImage(from: pb))
    }

    func testInitialStateIsIdleWithNoFrame() {
        let src = ScreenCaptureFrameSource(log: Log())
        XCTAssertEqual(src.state.value, .idle)
        XCTAssertNil(src.latestFrame); XCTAssertNil(src.frameSize)
        XCTAssertEqual(src.frameCount, 0); XCTAssertEqual(src.fps, 0)
    }
}
