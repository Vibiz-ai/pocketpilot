import CoreGraphics
import XCTest
@testable import PocketPilotCore

/// QA review (correctness & concurrency). Each test here reproduces a finding; a failing test = open bug.

/// A frame source that behaves like the real capture: `frameCount` only advances when a frame actually arrives.
private final class CountingFrames: FrameSource, @unchecked Sendable {
    let state = StateChannel<FrameSourceState>(.running(deviceName: "QA"))
    private let lock = NSLock()
    private var count = 0
    private var images: [Int: CGImage] = [:]

    init() { images[0] = Self.image(tag: 0) }

    static func image(tag: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: CGFloat(tag % 255) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 16))
        return ctx.makeImage()!
    }

    /// A new frame arrives.
    func push() { lock.withLock { count += 1; images[count] = Self.image(tag: count) } }
    func image(_ n: Int) -> CGImage? { lock.withLock { images[n] } }

    var latestFrame: CGImage? { lock.withLock { images[count] } }
    var frameSize: CGSize? { CGSize(width: 8, height: 16) }
    var frameCount: Int { lock.withLock { count } }
    func start() async throws {}
    func stop() {}
}

private final class NullHID: HIDTransport {
    let state = StateChannel<HIDConnectionState>(.connected(hostName: "QA"))
    func start() async throws {}
    func stop() {}
    func send(_ report: HIDReport) async throws {}
}

private final class NullOCR: TextRecognizer {
    func recognize(in image: CGImage) async throws -> [RecognizedText] { [] }
}

final class QAFindingsTests: XCTestCase {
    private func makeController(_ frames: CountingFrames) -> HIDPhoneController {
        let c = HIDPhoneController(frames: frames, renderer: ImageScreenshotRenderer(), recognizer: NullOCR(), hid: NullHID(),
                                   pointer: DotPointerLocator(), calibrationStore: InMemoryCalibrationStore(),
                                   status: StatusModel(), log: Log())
        c.timing = .fast
        c.timing.frameTimeout = 0.3
        return c
    }

    /// FINDING: one 0.3-0.6 s gap without frames (static iPhone screen) flips `_staticFrames` on for good. The reset
    /// branch (`frames.frameCount > count`) compares against a count read a moment earlier, so it practically never
    /// fires; afterwards `freshFrame` / `settledFrame` never wait for a post-move frame again and return the stale one.
    func testFreshFrameStillWaitsAfterOneTimeoutOnARealCountingSource() async throws {
        let frames = CountingFrames()
        let c = makeController(frames)

        // 1. Static screen: no frame arrives within frameTimeout (normal on a still iPhone screen).
        _ = try await c.freshFrame(after: frames.frameCount)

        // 2. Frames flow again at ~60 fps (the pointer moves, the screen changes).
        let ticker = Task.detached {
            for _ in 0..<40 { try? await Task.sleep(nanoseconds: 16_000_000); frames.push() }
        }
        defer { ticker.cancel() }
        try await Task.sleep(nanoseconds: 120_000_000)

        // 3. Like settledFrame(): we need a frame captured *after* now.
        var stale = 0
        for _ in 0..<5 {
            let n = frames.frameCount
            let f = try await c.freshFrame(after: n)
            if f === frames.image(n) { stale += 1 }
        }
        XCTAssertEqual(stale, 0, "freshFrame(after:) returned the already-seen frame \(stale)/5 times: the controller stays in static-frame mode after a single timeout although frames are flowing again")
    }
}
