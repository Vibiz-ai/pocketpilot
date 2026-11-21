import CoreGraphics
import CoreText
import XCTest
@testable import PocketPilotCore

final class VisionTextRecognizerTests: XCTestCase {
    /// White image with black text lines drawn at known top-left positions. Returns the image and each label's
    /// expected bounding rect (top-left origin).
    static func makeImage(width: Int = 590, height: Int = 1280,
                          labels: [(String, CGPoint, CGFloat)]) -> (CGImage, [String: CGRect]) {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var rects: [String: CGRect] = [:]
        for (text, topLeft, size) in labels {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            ctx.textPosition = .zero   // image bounds are relative to the current text position
            let bounds = CTLineGetImageBounds(line, ctx)
            let ascent = CTFontGetAscent(font)
            // Baseline in CG (bottom-left) coordinates so the glyph tops sit near topLeft.y.
            let baselineY = CGFloat(height) - topLeft.y - ascent
            ctx.textPosition = CGPoint(x: topLeft.x, y: baselineY)
            CTLineDraw(line, ctx)
            let imgRect = CGRect(x: topLeft.x + bounds.minX, y: CGFloat(height) - (baselineY + bounds.maxY),
                                 width: bounds.width, height: bounds.height)
            rects[text] = imgRect
        }
        return (ctx.makeImage()!, rects)
    }

    func testPixelRectConversion() {
        let r = VisionTextRecognizer.pixelRect(fromNormalized: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1),
                                               imageSize: CGSize(width: 500, height: 1000))
        XCTAssertEqual(r.minX, 50, accuracy: 1e-9)
        XCTAssertEqual(r.minY, 100, accuracy: 1e-9)   // top of a box whose bottom-left-origin top edge is 0.9
        XCTAssertEqual(r.width, 100, accuracy: 1e-9)
        XCTAssertEqual(r.height, 100, accuracy: 1e-9)
    }

    func testReadingOrder() {
        func t(_ s: String, _ x: Double, _ y: Double) -> RecognizedText { RecognizedText(text: s, x: x, y: y, width: 40, height: 20, confidence: 1) }
        let sorted = VisionTextRecognizer.readingOrder([t("C", 50, 300), t("B", 400, 102), t("A", 60, 100), t("D", 300, 301)])
        XCTAssertEqual(sorted.map(\.text), ["A", "B", "C", "D"])
    }

    func testRecognizesRenderedTextWithCorrectCentres() async throws {
        let (img, rects) = Self.makeImage(labels: [
            ("Settings", CGPoint(x: 60, y: 120), 40),
            ("Wallpaper", CGPoint(x: 300, y: 600), 36),
            ("Continue", CGPoint(x: 150, y: 1100), 40),
        ])
        let items = try await VisionTextRecognizer().recognize(in: img)
        XCTAssertGreaterThanOrEqual(items.count, 3, "got \(items.map(\.text))")

        for (label, rect) in rects {
            let found = try XCTUnwrap(items.find(label), "missing \(label) in \(items.map(\.text))")
            XCTAssertEqual(found.x, Double(rect.midX), accuracy: 15, "\(label) x")
            XCTAssertEqual(found.y, Double(rect.midY), accuracy: 15, "\(label) y")
            XCTAssertGreaterThan(found.width, 20); XCTAssertGreaterThan(found.height, 10)
            XCTAssertGreaterThan(found.confidence, 0.3)
        }
        // Reading order: top to bottom.
        let order = items.map(\.text.localizedLowercase)
        let iS = try XCTUnwrap(order.firstIndex(of: "settings")), iW = try XCTUnwrap(order.firstIndex(of: "wallpaper"))
        let iC = try XCTUnwrap(order.firstIndex(of: "continue"))
        XCTAssertLessThan(iS, iW); XCTAssertLessThan(iW, iC)
    }

    func testWordGranularitySplitsLine() async throws {
        let (img, _) = Self.makeImage(labels: [("Cancel Done", CGPoint(x: 40, y: 200), 44)])
        let lines = try await VisionTextRecognizer().recognize(in: img)
        let words = try await VisionTextRecognizer(granularity: .words).recognize(in: img)
        XCTAssertNotNil(lines.find("Cancel Done"), "lines: \(lines.map(\.text))")
        let cancel = try XCTUnwrap(words.find("Cancel"), "words: \(words.map(\.text))")
        let done = try XCTUnwrap(words.find("Done"))
        XCTAssertLessThan(cancel.x, done.x)
        XCTAssertEqual(cancel.y, done.y, accuracy: 6)
    }

    func testOCROnRenderedScreenshotUsesScreenshotCoordinates() async throws {
        // Draw text on a full-res frame, render it to the 590-wide screenshot, OCR the screenshot.
        let (frame, rects) = Self.makeImage(width: 1180, height: 2560, labels: [("Bluetooth", CGPoint(x: 400, y: 1000), 80)])
        let shot = try ImageScreenshotRenderer().render(frame)
        let items = try await VisionTextRecognizer().recognize(in: shot.image)
        let found = try XCTUnwrap(items.find("Bluetooth"), "got \(items.map(\.text))")
        let g = ScreenGeometry(frameSize: CGSize(width: 1180, height: 2560))
        let expected = g.toScreenshot(CGPoint(x: rects["Bluetooth"]!.midX, y: rects["Bluetooth"]!.midY))
        XCTAssertEqual(found.x, Double(expected.x), accuracy: 10)
        XCTAssertEqual(found.y, Double(expected.y), accuracy: 10)
    }

    func testEmptyImageReturnsNoText() async throws {
        let (img, _) = Self.makeImage(width: 200, height: 200, labels: [])
        let items = try await VisionTextRecognizer().recognize(in: img)
        XCTAssertTrue(items.isEmpty)
    }
}
