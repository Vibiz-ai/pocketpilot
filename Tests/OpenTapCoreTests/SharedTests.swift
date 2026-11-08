import CoreGraphics
import XCTest
@testable import OpenTapCore

/// Owner: architect (Shared/ contracts). Other roles add files under Tests/OpenTapCoreTests/<Module>/.
final class SharedTests: XCTestCase {
    func testKeyboardLayout() throws {
        XCTAssertEqual(USKeyboardLayout.stroke(for: "a"), KeyStroke(0x04))
        XCTAssertEqual(USKeyboardLayout.stroke(for: "A"), KeyStroke(0x04, .shift))
        XCTAssertEqual(USKeyboardLayout.stroke(for: "0"), KeyStroke(0x27))
        XCTAssertEqual(USKeyboardLayout.stroke(for: "?"), KeyStroke(0x38, .shift))
        XCTAssertThrowsError(try USKeyboardLayout.strokes(for: "héllo"))
    }

    func testKeyCombo() throws {
        XCTAssertEqual(try KeyCombo.parse("cmd+space"), KeyCombo(modifiers: .command, target: .key(KeyUsage.space)))
        XCTAssertEqual(try KeyCombo.parse("home").target, .consumer(ConsumerUsage.acHome))
        XCTAssertThrowsError(try KeyCombo.parse("hyper+x"))
    }

    func testReports() {
        XCTAssertEqual(HIDReport.mouse(MouseReport(buttons: .left, dx: -1, dy: 5)).interruptPacket, [0xA1, 0x02, 0x01, 0xFF, 0x05, 0x00])
        XCTAssertEqual(HIDReport.consumer(ConsumerReport(usage: 0x0223)).interruptPacket, [0xA1, 0x03, 0x23, 0x02])
        XCTAssertEqual(KeyboardReport(modifiers: .shift, keys: [0x04]).payload.count, 8)
    }

    func testCurveAndStore() throws {
        let c = AxisCurve(samples: [CurveSample(step: 10, pixelsPerStep: 5), CurveSample(step: 2, pixelsPerStep: 1)])
        XCTAssertEqual(c.pixels(forStep: 6), 3, accuracy: 0.001)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("opentap-test-\(UUID()).json")
        let store = FileCalibrationStore(url: url)
        let data = CalibrationData(deviceUDID: "x", screenshotSize: CGSize(width: 590, height: 1280), x: c, y: c)
        try store.save(data)
        XCTAssertEqual(try store.load()?.x, c)
        try store.clear()
    }

    func testFindText() {
        let items = [RecognizedText(text: "Settings", x: 10, y: 100, width: 1, height: 1, confidence: 1),
                     RecognizedText(text: "settings", x: 10, y: 50, width: 1, height: 1, confidence: 1)]
        XCTAssertEqual(items.find("SETTINGS")?.y, 50)
        XCTAssertEqual(items.find("settings", occurrence: 2)?.y, 100)
        XCTAssertNil(items.find("settings", occurrence: 3))
    }

    func testMockEnvironmentWires() async {
        let env = OpenTapEnvironment.mock(port: 0)
        await env.device.start()
        XCTAssertEqual(env.status.snapshot.value[.usb].health, .ok)
    }
}
