import Foundation

/// Owner: architect. Wires every module together. The app uses `.live()`, opentap-mock and tests use `.mock()`.
public final class OpenTapEnvironment {
    public let log: Log
    public let status: StatusModel
    public let permissions: PermissionsProvider
    public let frames: FrameSource
    public let renderer: ScreenshotRenderer
    public let recognizer: TextRecognizer
    public let hid: HIDTransport
    public let device: DeviceLink
    public let pointer: PointerLocator
    public let calibrationStore: CalibrationStore
    public let controller: PhoneController
    public let mcp: MCPServer
    /// Present only in mock environments.
    public let mockPhone: MockPhone?

    private var subscriptions: [Subscription] = []

    public init(log: Log, status: StatusModel, permissions: PermissionsProvider, frames: FrameSource,
                renderer: ScreenshotRenderer, recognizer: TextRecognizer, hid: HIDTransport, device: DeviceLink,
                pointer: PointerLocator, calibrationStore: CalibrationStore,
                mcpHost: String = MCPDefaults.host, mcpPort: UInt16 = MCPDefaults.port, mockPhone: MockPhone? = nil) {
        self.log = log; self.status = status; self.permissions = permissions; self.frames = frames
        self.renderer = renderer; self.recognizer = recognizer; self.hid = hid; self.device = device
        self.pointer = pointer; self.calibrationStore = calibrationStore; self.mockPhone = mockPhone
        let controller = HIDPhoneController(frames: frames, renderer: renderer, recognizer: recognizer, hid: hid,
                                            pointer: pointer, calibrationStore: calibrationStore, status: status, log: log)
        self.controller = controller
        self.mcp = MCPServer(controller: controller, status: status, log: log, host: mcpHost, port: mcpPort)
        bindStatus()
    }

    public static func live(log: Log = Log()) -> OpenTapEnvironment {
        OpenTapEnvironment(log: log, status: StatusModel(), permissions: SystemPermissions(),
                           frames: ScreenCaptureFrameSource(log: log), renderer: ImageScreenshotRenderer(),
                           recognizer: VisionTextRecognizer(), hid: BluetoothHIDTransport(log: log),
                           device: MobileDeviceLink(log: log), pointer: DotPointerLocator(),
                           calibrationStore: FileCalibrationStore())
    }

    public static func mock(log: Log = Log(), phone: MockPhone = MockPhone(), port: UInt16 = MCPDefaults.port,
                            calibrationStore: CalibrationStore = InMemoryCalibrationStore()) -> OpenTapEnvironment {
        OpenTapEnvironment(log: log, status: StatusModel(), permissions: MockPermissions(),
                           frames: MockFrameSource(phone: phone), renderer: ImageScreenshotRenderer(),
                           recognizer: MockTextRecognizer(phone: phone), hid: MockHIDTransport(phone: phone),
                           device: MockDeviceLink(phone: phone), pointer: DotPointerLocator(),
                           calibrationStore: calibrationStore, mcpPort: port, mockPhone: phone)
    }

    /// Maps each module's state channel onto the StatusModel pills.
    private func bindStatus() {
        let s = status
        subscriptions.append(device.state.subscribe { [weak self] st in
            switch st {
            case .unavailable(let e): s.set(.usb, .failed(e))
            case .idle: s.set(.usb, .unknown)
            case .noDevice: s.set(.usb, .pending("Plug in your iPhone with a USB cable"))
            case .attached(let d, let trust):
                s.update { $0.device = d }
                self?.recheckCalibration()
                switch trust {
                case .paired: s.set(.usb, .ok("\(d.name), iOS \(d.iosVersion)"))
                case .locked: s.set(.usb, .pending("Unlock \(d.name)"))
                case .awaitingUserTrust: s.set(.usb, .pending("Tap Trust on \(d.name)"))
                case .denied: s.set(.usb, .failed(OpenTapError(.notPaired, what: "\(d.name) is not trusted",
                    why: "\"Don't Trust\" was tapped on the iPhone",
                    fix: ManualSteps.denied)))
                case .notPaired, .unknown: s.set(.usb, .pending("\(d.name) connected, not trusted yet"))
                }
            }
        })
        subscriptions.append(frames.state.subscribe { [weak self] st in
            switch st {
            case .idle: s.set(.screen, .unknown)
            case .waitingForDevice: s.set(.screen, .pending("Waiting for the iPhone screen"))
            case .starting: s.set(.screen, .pending("Starting screen capture"))
            case .running(let name):
                s.set(.screen, .ok("Live from \(name)"))
                self?.recheckCalibration()
            case .failed(let e): s.set(.screen, .failed(e))
            }
        })
        subscriptions.append(hid.state.subscribe { st in
            switch st {
            case .off: s.set(.bluetooth, .unknown)
            case .unavailable(let e), .failed(let e): s.set(.bluetooth, .failed(e))
            case .advertising(let name): s.set(.bluetooth, .pending("Pair \"\(name)\" in iPhone Settings > Bluetooth"))
            case .connecting: s.set(.bluetooth, .pending("Connecting"))
            case .connected(let host): s.set(.bluetooth, .ok(host.map { "Connected to \($0)" } ?? "Connected"))
            }
        })
        subscriptions.append(mcp.state.subscribe { st in
            switch st {
            case .stopped: s.set(.mcp, .unknown)
            case .starting: s.set(.mcp, .pending("Starting"))
            case .listening(let h, let p): s.set(.mcp, .ok("http://\(h):\(p)\(MCPDefaults.path)"))
            case .failed(let e): s.set(.mcp, .failed(e))
            }
        })
        recheckCalibration()
    }

    /// Sets the Calibration pill from the saved calibration *for the iPhone that is connected now*: a file
    /// measured on another iPhone (or another screen shape) is not "done". Called at launch, on attach and
    /// when the screen starts. Leaves a running calibration and a "previous kept" status alone.
    public func recheckCalibration() {
        let current = status.snapshot.value[.calibration]
        if current.health == .pending, current.detail.hasPrefix("Calibrating") { return }
        guard let cal = try? calibrationStore.load() else {
            status.set(.calibration, .pending("Not calibrated yet"))
            return
        }
        let snap = status.snapshot.value
        if let calUDID = cal.deviceUDID, let d = snap.device, calUDID != d.udid {
            status.set(.calibration, .pending("Calibrated for another iPhone: run calibration for \(d.name)"))
            return
        }
        if let size = frames.frameSize, size.width > 0, cal.screenshotSize.width > 0 {
            let aspect = Double(size.height / size.width)
            let calAspect = Double(cal.screenshotSize.height / cal.screenshotSize.width)
            if abs(aspect - calAspect) > 0.03 * aspect {
                status.set(.calibration, .pending("Calibrated for a different screen shape: run calibration again"))
                return
            }
        }
        if current.health == .ok, current.error != nil { return }
        let ok = ComponentStatus.ok("Calibrated \(cal.createdAt.formatted(date: .abbreviated, time: .shortened))")
        if current != ok { status.set(.calibration, ok) }
    }
}
