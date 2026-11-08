import AVFoundation
import CoreGraphics
import CoreMediaIO
import Foundation

/// Owner: capture. iPhone screen over USB via CoreMediaIO (kCMIOHardwarePropertyAllowScreenCaptureDevices = 1)
/// + AVCaptureSession (muxed/video device). Keeps only the latest frame.
public final class ScreenCaptureFrameSource: FrameSource {
    public let state = StateChannel<FrameSourceState>(.idle)
    public private(set) var latestFrame: CGImage?
    public private(set) var frameSize: CGSize?
    public private(set) var frameCount: Int = 0
    private let log: Log

    public init(log: Log) { self.log = log }

    public func start() async throws {
        let e = OpenTapError.notImplemented("iPhone screen capture", module: "Capture")
        state.send(.failed(e))
        throw e
    }

    public func stop() { state.send(.idle) }
}
