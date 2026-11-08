import CoreGraphics
import Foundation

/// Owner: control. Taps (park + curve move + closed-loop correction + click), swipes, typing, keys, open_app,
/// calibration, screenshots (+OCR).
public final class HIDPhoneController: PhoneController {
    public let frames: FrameSource
    public let renderer: ScreenshotRenderer
    public let recognizer: TextRecognizer
    public let hid: HIDTransport
    public let pointer: PointerLocator
    public let calibrationStore: CalibrationStore
    public let statusModel: StatusModel
    public let log: Log

    public init(frames: FrameSource, renderer: ScreenshotRenderer, recognizer: TextRecognizer, hid: HIDTransport,
                pointer: PointerLocator, calibrationStore: CalibrationStore, status: StatusModel, log: Log) {
        self.frames = frames; self.renderer = renderer; self.recognizer = recognizer; self.hid = hid
        self.pointer = pointer; self.calibrationStore = calibrationStore; self.statusModel = status; self.log = log
    }

    public func screenshot(includeText: Bool) async throws -> Screenshot {
        throw OpenTapError.notImplemented("Screenshots", module: "Control")
    }

    public func perform(_ action: PhoneAction) async throws -> ActionResult {
        throw OpenTapError.notImplemented("The \(action.name) action", module: "Control")
    }

    public func performBatch(_ actions: [PhoneAction]) async throws -> ActionResult {
        throw OpenTapError.notImplemented("Batch actions", module: "Control")
    }

    public func calibrate(progress: @escaping (CalibrationProgress) -> Void) async throws -> CalibrationData {
        throw OpenTapError.notImplemented("Calibration", module: "Control")
    }

    public func status() async -> StatusSnapshot { statusModel.snapshot.value }
}
