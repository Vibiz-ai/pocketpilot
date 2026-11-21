import CoreGraphics
import Foundation

/// Owner: qa. Mock implementations of the hardware protocols, all backed by one MockPhone.
/// Toggle the phone's fault properties (or `phone.apply([.locked, ...])`) and these components follow live.

// MARK: - Screen

/// The iPhone screen over "USB": frames are `phone.render()`, `frameCount` ticks at `fps` while running.
public final class MockFrameSource: FrameSource, @unchecked Sendable {
    public let phone: MockPhone
    public let state = StateChannel<FrameSourceState>(.idle)
    /// Frame rate of the simulated stream.
    public var fps: Double

    private let lock = NSLock()
    private var started = false
    private var count = 0
    private var timer: DispatchSourceTimer?
    private var sub: Subscription?
    private let queue = DispatchQueue(label: "pocketpilot.mock.frames")

    public init(phone: MockPhone, fps: Double = 60) {
        self.phone = phone
        self.fps = fps
    }

    private var isLive: Bool {
        lock.withLock { started } && phone.usbAttached && phone.framesEnabled && phone.captureFailure == nil
    }

    public var latestFrame: CGImage? {
        guard isLive, lock.withLock({ count }) > 0 else { return nil }
        return phone.render()
    }

    public var frameSize: CGSize? { isLive ? phone.screenSize : nil }

    public var frameCount: Int { lock.withLock { count } }

    public func start() async throws {
        state.send(.starting)
        if let e = phone.captureFailure {
            state.send(.failed(e))
            throw e
        }
        let alreadyStarted: Bool = lock.withLock { let was = started; started = true; return was }
        if !alreadyStarted {
            sub = phone.changes.subscribe { [weak self] in self?.refresh() }
            let t = DispatchSource.makeTimerSource(queue: queue)
            let interval = 1.0 / max(1, fps)
            t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            tick() // first frame is available immediately
        }
        refresh()
    }

    public func stop() {
        lock.withLock { started = false }
        timer?.cancel(); timer = nil
        sub = nil
        state.send(.idle)
    }

    private func tick() {
        guard isLive, !phone.framesFrozen else { return }
        lock.withLock { count += 1 }
    }

    private func refresh() {
        guard lock.withLock({ started }) else { return }
        let next: FrameSourceState
        if let e = phone.captureFailure { next = .failed(e) }
        else if !phone.usbAttached || !phone.framesEnabled { next = .waitingForDevice }
        else { next = .running(deviceName: phone.deviceInfo.name) }
        if state.value != next { state.send(next) }
    }

    deinit { timer?.cancel() }
}

// MARK: - Bluetooth HID

/// The Mac-as-keyboard/mouse link. Connects as soon as it starts (after `connectDelay`) unless
/// `phone.bluetoothAccepts` is false; reports go straight into `phone.receive`.
public final class MockHIDTransport: HIDTransport, @unchecked Sendable {
    public let phone: MockPhone
    public let state = StateChannel<HIDConnectionState>(.off)
    /// Delay between advertising and the iPhone connecting (0 = connect inside `start()`).
    public var connectDelay: TimeInterval
    /// Every report successfully sent, in order.
    public private(set) var sent: [HIDReport] = []

    private let lock = NSLock()
    private var started = false
    private var sub: Subscription?

    public static let advertisedName = "PocketPilot"

    public init(phone: MockPhone, connectDelay: TimeInterval = 0) {
        self.phone = phone
        self.connectDelay = connectDelay
    }

    public func start() async throws {
        guard phone.bluetoothAvailable else {
            let e = Self.bluetoothOffError
            state.send(.unavailable(e))
            throw e
        }
        let already: Bool = lock.withLock { let was = started; started = true; return was }
        if !already { sub = phone.changes.subscribe { [weak self] in self?.refresh() } }
        if !state.value.isConnected { state.send(.advertising(name: Self.advertisedName)) }
        if connectDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + connectDelay) { [weak self] in self?.refresh() }
        } else {
            refresh()
        }
    }

    public func stop() {
        lock.withLock { started = false }
        sub = nil
        phone.hidConnected = false
        state.send(.off)
    }

    public func send(_ report: HIDReport) async throws {
        guard state.value.isConnected, phone.hidConnected else {
            throw PocketPilotError(.hidNotConnected, what: "Couldn't send input to the iPhone",
                               why: "The iPhone is not connected to PocketPilot over Bluetooth",
                               fix: "On the iPhone open Settings > Bluetooth and tap \"\(Self.advertisedName)\" under Other Devices")
        }
        lock.withLock { sent.append(report) }
        phone.receive(report)
    }

    private func refresh() {
        guard lock.withLock({ started }) else { return }
        // State first, then the phone flag: setting the flag re-enters refresh() via phone.changes.
        if !phone.bluetoothAvailable {
            let e = Self.bluetoothOffError
            if state.value != .unavailable(e) { state.send(.unavailable(e)) }
            if phone.hidConnected { phone.hidConnected = false }
            return
        }
        if phone.bluetoothAccepts {
            if !state.value.isConnected {
                state.send(.connecting)
                state.send(.connected(hostName: phone.deviceInfo.name))
            }
            if !phone.hidConnected { phone.hidConnected = true }
        } else {
            if state.value != .advertising(name: Self.advertisedName) { state.send(.advertising(name: Self.advertisedName)) }
            if phone.hidConnected { phone.hidConnected = false }
        }
    }

    static let bluetoothOffError = PocketPilotError(.bluetoothUnavailable, what: "Bluetooth is not available",
                                                why: "Bluetooth is turned off on this Mac (simulated)",
                                                fix: "Turn Bluetooth on in Control Center or System Settings > Bluetooth")
}

// MARK: - USB / lockdown

/// Attach/trust/AssistiveTouch over "USB". Follows `phone.usbAttached`, `phone.trust`, `phone.isLocked`.
public final class MockDeviceLink: DeviceLink, @unchecked Sendable {
    public let phone: MockPhone
    public let state = StateChannel<DeviceLinkState>(.idle)
    /// How long the simulated user takes to answer "Trust This Computer?".
    public var trustDelay: TimeInterval

    private let lock = NSLock()
    private var started = false
    private var sub: Subscription?

    public init(phone: MockPhone, trustDelay: TimeInterval = 0.05) {
        self.phone = phone
        self.trustDelay = trustDelay
    }

    public func start() async {
        let already: Bool = lock.withLock { let was = started; started = true; return was }
        if !already { sub = phone.changes.subscribe { [weak self] in self?.refresh() } }
        refresh()
    }

    public func stop() {
        lock.withLock { started = false }
        sub = nil
        state.send(.idle)
    }

    public func isPaired() async throws -> Bool {
        try requireAttached()
        return phone.trust == .paired
    }

    public func pair() async throws {
        let device = try requireAttached()
        if phone.trust == .paired { return }
        if phone.isLocked {
            phone.trust = .locked
            throw PocketPilotError(.deviceLocked, what: "Couldn't ask \(device.name) to trust this Mac",
                               why: "The iPhone is locked",
                               fix: "Unlock the iPhone with Face ID or your passcode; PocketPilot will ask again")
        }
        phone.trust = .awaitingUserTrust
        if trustDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(trustDelay * 1_000_000_000)) }
        if phone.acceptsTrust {
            phone.trust = .paired
        } else {
            phone.trust = .denied
            throw PocketPilotError(.notPaired, what: "\(device.name) did not trust this Mac",
                               why: "\"Don't Trust\" was tapped on the iPhone",
                               fix: "Unplug and replug the iPhone, then tap Trust and enter your passcode")
        }
    }

    public func assistiveTouchEnabled() async throws -> Bool {
        try requireLockdown()
        return phone.assistiveTouchEnabled
    }

    public func setAssistiveTouch(_ enabled: Bool) async throws {
        try requireLockdown()
        phone.assistiveTouchEnabled = enabled
    }

    @discardableResult
    private func requireAttached() throws -> DeviceInfo {
        if !phone.mobileDeviceAvailable { throw Self.frameworkMissing }
        guard phone.usbAttached else {
            throw PocketPilotError(.noDevice, what: "No iPhone found over USB",
                               why: "No iPhone is plugged into this Mac",
                               fix: "Plug the iPhone in with a USB cable (a data cable, not charge-only) and unlock it")
        }
        return phone.deviceInfo
    }

    private func requireLockdown() throws {
        let device = try requireAttached()
        guard phone.trust == .paired else {
            throw PocketPilotError(.notPaired, what: "Couldn't talk to \(device.name)",
                               why: "This Mac is not trusted by the iPhone yet",
                               fix: "Unlock the iPhone and tap Trust when it asks \"Trust This Computer?\"")
        }
        guard phone.assistiveTouchSettableOverUSB else {
            throw PocketPilotError(.frameworkUnavailable, what: "Couldn't change AssistiveTouch over USB",
                               why: "\(device.name) refused the accessibility setting over USB (simulated)",
                               fix: "On the iPhone open Settings > Accessibility > Touch > AssistiveTouch and turn it on")
        }
    }

    private func refresh() {
        guard lock.withLock({ started }) else { return }
        let next: DeviceLinkState
        if !phone.mobileDeviceAvailable { next = .unavailable(Self.frameworkMissing) }
        else if !phone.usbAttached { next = .noDevice }
        else {
            var trust = phone.trust
            if phone.isLocked && trust == .notPaired { trust = .locked }
            next = .attached(phone.deviceInfo, trust: trust)
        }
        if state.value != next { state.send(next) }
    }

    static let frameworkMissing = PocketPilotError(.frameworkUnavailable,
        what: "Can't read the iPhone over USB",
        why: "MobileDevice.framework is not available on this Mac (simulated)",
        fix: "Install Xcode or open Finder once with the iPhone plugged in; meanwhile, tap Trust on the iPhone and turn on AssistiveTouch in Settings > Accessibility > Touch")
}

// MARK: - OCR

/// Deterministic OCR: returns the phone's visible text scaled into the given image's space (no Vision needed).
public final class MockTextRecognizer: TextRecognizer {
    public let phone: MockPhone
    /// Set to make `recognize` throw (simulated OCR failure).
    public var failure: PocketPilotError?
    public init(phone: MockPhone) { self.phone = phone }

    public func recognize(in image: CGImage) async throws -> [RecognizedText] {
        if let failure { throw failure }
        let sx = Double(image.width) / Double(phone.screenSize.width)
        let sy = Double(image.height) / Double(phone.screenSize.height)
        return phone.elements.map {
            let box = $0.textBox
            return RecognizedText(text: $0.text, x: Double($0.center.x) * sx, y: Double($0.center.y) * sy,
                                  width: Double(box.width) * sx, height: Double(box.height) * sy, confidence: 1)
        }
    }
}

// MARK: - Permissions

public final class MockPermissions: PermissionsProvider {
    public var statuses: [Permission: PermissionStatus]
    /// What a `.notDetermined` permission becomes when requested.
    public var answer: PermissionStatus
    /// Permissions whose Settings pane was opened, in order.
    public private(set) var openedSettings: [Permission] = []

    public init(_ statuses: [Permission: PermissionStatus] = [.camera: .granted, .bluetooth: .granted],
                answer: PermissionStatus = .granted) {
        self.statuses = statuses
        self.answer = answer
    }

    public func status(_ p: Permission) -> PermissionStatus { statuses[p] ?? .notDetermined }

    public func request(_ p: Permission) async -> PermissionStatus {
        if status(p) == .notDetermined { statuses[p] = answer }
        return status(p)
    }

    public func openSettings(_ p: Permission) { openedSettings.append(p) }
}
