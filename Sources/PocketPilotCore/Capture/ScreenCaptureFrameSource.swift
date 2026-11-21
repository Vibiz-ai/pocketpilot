@preconcurrency import AVFoundation
import CoreGraphics
import CoreMediaIO
import CoreVideo
import Foundation

/// Owner: capture. iPhone screen over USB via CoreMediaIO (kCMIOHardwarePropertyAllowScreenCaptureDevices = 1)
/// + AVCaptureSession (muxed/video device). Keeps only the latest frame.
///
/// Lifecycle:
/// - `start()` checks Camera permission (requesting it if undetermined), opts this process in to screen-capture
///   devices, and looks for an attached iPhone. If none is visible yet it does **not** throw: state becomes
///   `.waitingForDevice` and capture starts by itself when the iPhone is plugged in (and stops/waits again on unplug).
/// - State is `.starting` until the first frame arrives, then `.running(deviceName:)`. If no frame arrives within
///   `firstFrameTimeout`, state becomes `.failed(.noFrame ...)` with steps to fix (unlock / Trust); capture keeps
///   listening and flips to `.running` as soon as frames show up.
/// - Throws only for permission denial (`.permissionDenied`) or a capture session that can't be built (`.captureFailed`).
///
/// Frames are kept as the latest CVPixelBuffer and converted to a CGImage lazily (once per new frame) when
/// `latestFrame` is read, so 60 fps capture doesn't cost a full copy per frame.
public final class ScreenCaptureFrameSource: FrameSource {
    public let state = StateChannel<FrameSourceState>(.idle)

    /// Seconds to wait for the first frame after a session starts before reporting `.noFrame`.
    public var firstFrameTimeout: TimeInterval = 5
    /// Seconds `start()` keeps looking for the iPhone right after enabling screen-capture devices (they appear asynchronously).
    public var discoveryGrace: TimeInterval = 3
    /// If set, prefer the capture device whose uniqueID matches (iPhone UDID, with or without dashes).
    public var preferredDeviceID: String?

    private let log: Log
    private let lock = NSLock()
    private let sessionQueue = DispatchQueue(label: "pocketpilot.capture.session")
    private let outputQueue = DispatchQueue(label: "pocketpilot.capture.frames", qos: .userInteractive)

    // Guarded by `lock`.
    private var pixelBuffer: CVPixelBuffer?
    private var count = 0
    private var cachedImage: CGImage?
    private var cachedCount = -1
    private var size: CGSize?
    private var frameTimes: [CFTimeInterval] = []
    private var sessionFrameCount = 0
    private var currentName: String?

    // Touched on `sessionQueue` (and start/stop).
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private var delegate: FrameDelegate?
    private var observers: [NSObjectProtocol] = []
    private var active = false
    private var watchdog: DispatchWorkItem?

    public init(log: Log) { self.log = log }

    deinit {
        // No queue hops here: the last reference may be dropped on sessionQueue itself.
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        watchdog?.cancel()
        if let s = session, s.isRunning { s.stopRunning() }
    }

    // MARK: FrameSource

    public var latestFrame: CGImage? {
        let (pb, n, cached, cachedN): (CVPixelBuffer?, Int, CGImage?, Int) = lock.withLock { (pixelBuffer, count, cachedImage, cachedCount) }
        if cachedN == n { return cached }
        guard let pb, let img = Self.makeImage(from: pb) else { return cached }
        lock.withLock { if count == n || cachedCount < n { cachedImage = img; cachedCount = n } }
        return img
    }

    public var frameSize: CGSize? { lock.withLock { size } }
    public var frameCount: Int { lock.withLock { count } }

    /// Frames per second over the last second (0 when idle).
    public var fps: Double {
        lock.withLock {
            let now = CACurrentMediaTime()
            let recent = frameTimes.filter { now - $0 <= 1.0 }
            return Double(recent.count)
        }
    }

    /// Name of the capture device in use, if any.
    public var deviceName: String? { lock.withLock { currentName } }

    public func start() async throws {
        // Already active with a healthy session: nothing to do. Active but failed/without a session (runtime error,
        // attach refused, no-frame watchdog): fall through and look for the device again.
        let healthy: Bool = sessionQueue.sync { active && session != nil }
        if healthy, case .failed = state.value {
            sessionQueue.sync { detachLocked() }
        } else if healthy {
            return
        }
        state.send(.starting)

        try await ensureCameraPermission()

        if let err = Self.enableScreenCaptureDevices() {
            // Not fatal on its own: the device may already be visible if another app enabled it for us.
            log.warning("capture", err.description)
        }

        sessionQueue.sync { active = true }
        installObservers()

        // Screen-capture devices show up a moment after opting in; give discovery a short grace period.
        let deadline = Date().addingTimeInterval(discoveryGrace)
        var found = findScreenDevice()
        while found == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard sessionQueue.sync(execute: { active }) else { return }
            found = findScreenDevice()
        }

        guard let dev = found else {
            log.info("capture", "No iPhone screen visible yet; waiting for one to be plugged in")
            state.send(.waitingForDevice)
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do { try self.attach(dev); cont.resume() } catch { cont.resume(throwing: error) }
            }
        }
    }

    public func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        sessionQueue.sync {
            active = false
            detachLocked()
        }
        lock.withLock {
            pixelBuffer = nil; cachedImage = nil; cachedCount = -1; size = nil; frameTimes.removeAll()
        }
        if state.value != .idle { state.send(.idle) }
    }

    // MARK: Permission

    private func ensureCameraPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted { return }
            fallthrough
        case .denied:
            let e = PocketPilotError(.permissionDenied, what: "Couldn't start the iPhone screen capture",
                                 why: "Camera access is turned off for PocketPilot (macOS treats the iPhone screen as a camera)",
                                 fix: "Open System Settings > Privacy & Security > Camera, turn on PocketPilot, then restart PocketPilot")
            state.send(.failed(e)); throw e
        case .restricted:
            let e = PocketPilotError(.permissionDenied, what: "Couldn't start the iPhone screen capture",
                                 why: "Camera access is restricted on this Mac (by Screen Time or a device-management profile)",
                                 fix: "Ask your administrator to allow camera access for PocketPilot, or remove the Screen Time camera restriction")
            state.send(.failed(e)); throw e
        @unknown default:
            return
        }
    }

    // MARK: CoreMediaIO opt-in

    /// Sets kCMIOHardwarePropertyAllowScreenCaptureDevices = 1 so iOS devices plugged in by USB appear as capture devices.
    /// Returns an error description on failure (nil on success).
    @discardableResult
    public static func enableScreenCaptureDevices() -> PocketPilotError? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                               UInt32(MemoryLayout<UInt32>.size), &allow)
        guard status == 0 else {
            return PocketPilotError(.frameworkUnavailable, what: "Couldn't turn on iPhone screen capture",
                                why: "CoreMediaIO refused to allow screen-capture devices (status \(status))",
                                fix: "Restart the Mac, or open QuickTime Player > File > New Movie Recording once so macOS lists the iPhone, then retry")
        }
        return nil
    }

    // MARK: Discovery

    /// True when a capture device looks like an iOS screen (QuickTime-style muxed USB device), not a webcam,
    /// Continuity Camera, or display camera.
    public static func isScreenCaptureDevice(modelID: String, manufacturer: String, hasMuxedMedia: Bool) -> Bool {
        if modelID.range(of: "iOS Device", options: .caseInsensitive) != nil { return true }
        return hasMuxedMedia && manufacturer.hasPrefix("Apple")
    }

    static func normalizedID(_ s: String) -> String { s.replacingOccurrences(of: "-", with: "").lowercased() }

    private func findScreenDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: nil, position: .unspecified)
        let candidates = discovery.devices.filter {
            Self.isScreenCaptureDevice(modelID: $0.modelID, manufacturer: $0.manufacturer, hasMuxedMedia: $0.hasMediaType(.muxed))
        }
        if let want = preferredDeviceID.map(Self.normalizedID),
           let match = candidates.first(where: { Self.normalizedID($0.uniqueID).contains(want) || want.contains(Self.normalizedID($0.uniqueID)) }) {
            return match
        }
        return candidates.first
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let dev = note.object as? AVCaptureDevice,
                  Self.isScreenCaptureDevice(modelID: dev.modelID, manufacturer: dev.manufacturer, hasMuxedMedia: dev.hasMediaType(.muxed))
            else { return }
            self.sessionQueue.async {
                guard self.active, self.session == nil else { return }
                self.log.info("capture", "iPhone screen connected: \(dev.localizedName)")
                do { try self.attach(dev) } catch {
                    let e = PocketPilotError.wrap(error, what: "Couldn't start the iPhone screen capture")
                    self.log.error("capture", e)
                    self.state.send(.failed(e))
                }
            }
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let dev = note.object as? AVCaptureDevice else { return }
            self.sessionQueue.async {
                guard self.active, let cur = self.device, cur.uniqueID == dev.uniqueID else { return }
                self.log.warning("capture", "iPhone screen disconnected: \(dev.localizedName)")
                self.detachLocked()
                self.state.send(.waitingForDevice)
            }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let s = note.object as? AVCaptureSession else { return }
            self.sessionQueue.async {
                guard s === self.session else { return }
                let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                let e = PocketPilotError(.captureFailed, what: "The iPhone screen capture stopped",
                                     why: "macOS reported a capture error: \(err?.localizedDescription ?? "unknown error")",
                                     fix: "Unplug and re-plug the iPhone; if it keeps happening, quit other apps that show the iPhone screen (QuickTime Player)")
                self.log.error("capture", e)
                // Tear the broken session down so Restart (or a replug, via wasConnected) can attach afresh.
                self.detachLocked()
                self.state.send(.failed(e))
            }
        })
    }

    // MARK: Session (call on sessionQueue)

    private func attach(_ dev: AVCaptureDevice) throws {
        detachLocked()
        let session = AVCaptureSession()
        session.beginConfiguration()
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: dev) } catch {
            session.commitConfiguration()
            let e = PocketPilotError(.captureFailed, what: "Couldn't open the iPhone screen (\(dev.localizedName))",
                                 why: "macOS refused the capture device: \(error.localizedDescription)",
                                 fix: "Unlock the iPhone, tap Trust if asked, then unplug and re-plug the cable")
            state.send(.failed(e)); throw e
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            let e = PocketPilotError(.captureFailed, what: "Couldn't open the iPhone screen (\(dev.localizedName))",
                                 why: "The capture session can't use this device (it may be in use by another app)",
                                 fix: "Quit other apps showing the iPhone screen (QuickTime Player), then unplug and re-plug the iPhone")
            state.send(.failed(e)); throw e
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let delegate = FrameDelegate { [weak self] pb in self?.receive(pb) }
        output.setSampleBufferDelegate(delegate, queue: outputQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            let e = PocketPilotError(.captureFailed, what: "Couldn't read frames from the iPhone screen",
                                 why: "The capture session rejected the video output",
                                 fix: "Restart PocketPilot; if it persists, restart the Mac")
            state.send(.failed(e)); throw e
        }
        session.addOutput(output)
        session.commitConfiguration()

        self.session = session; self.device = dev; self.delegate = delegate
        lock.withLock { sessionFrameCount = 0; currentName = dev.localizedName }
        state.send(.starting)
        log.info("capture", "Starting capture from \(dev.localizedName) [\(dev.modelID)]")
        session.startRunning()
        armWatchdog(deviceName: dev.localizedName)
    }

    private func detachLocked() {
        watchdog?.cancel(); watchdog = nil
        if let s = session, s.isRunning { s.stopRunning() }
        session = nil; device = nil; delegate = nil
        // Drop the last picture too: once the device is gone it is stale and must not be served as live.
        lock.withLock {
            currentName = nil
            pixelBuffer = nil; cachedImage = nil; cachedCount = -1; size = nil; frameTimes.removeAll()
        }
    }

    private func armWatchdog(deviceName: String) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.session != nil else { return }
            let got = self.lock.withLock { self.sessionFrameCount }
            guard got == 0 else { return }
            let e = PocketPilotError(.noFrame, what: "No picture from \(deviceName) yet",
                                 why: "The iPhone is connected but sent no screen frames in \(Int(self.firstFrameTimeout))s; it is usually locked or hasn't trusted this Mac",
                                 fix: "Unlock the iPhone and keep it on the Home Screen; if it asks \"Trust This Computer?\", tap Trust. If nothing changes, unplug and re-plug the cable")
            self.log.warning("capture", e.description)
            self.state.send(.failed(e))
        }
        watchdog = item
        sessionQueue.asyncAfter(deadline: .now() + firstFrameTimeout, execute: item)
    }

    // MARK: Frames (outputQueue)

    private func receive(_ pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let now = CACurrentMediaTime()
        let (first, name): (Bool, String) = lock.withLock {
            pixelBuffer = pb
            count += 1
            sessionFrameCount += 1
            size = CGSize(width: w, height: h)
            frameTimes.append(now)
            if frameTimes.count > 240 { frameTimes.removeFirst(frameTimes.count - 240) }
            return (sessionFrameCount == 1, currentName ?? "iPhone")
        }
        // Never hop to sessionQueue here: stopRunning() there can wait on this queue.
        if first || !isRunningState(state.value) {
            if first { log.info("capture", "First frame from \(name): \(w)x\(h)") }
            if !isRunningState(state.value) { state.send(.running(deviceName: name)) }
        }
    }

    private func isRunningState(_ s: FrameSourceState) -> Bool {
        if case .running = s { return true }
        return false
    }

    // MARK: Pixel conversion

    /// Copies a BGRA (32BGRA) pixel buffer into an independent sRGB CGImage (top-left origin).
    /// Returns nil for unsupported pixel formats or locked/empty buffers.
    public static func makeImage(from pb: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let data = Data(bytes: base, count: bpr * h)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr, space: space,
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// Internal state is guarded by `lock` / `sessionQueue`.
extension ScreenCaptureFrameSource: @unchecked Sendable {}

private final class FrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let onFrame: (CVPixelBuffer) -> Void
    init(_ onFrame: @escaping (CVPixelBuffer) -> Void) { self.onFrame = onFrame }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(pb)
    }
}
