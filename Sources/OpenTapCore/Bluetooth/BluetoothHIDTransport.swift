import Foundation
import IOBluetooth
import CoreBluetooth

/// Owner: bluetooth. The Mac as a classic Bluetooth HID keyboard + mouse + consumer-control device:
/// publishes the HID SDP record, sets a peripheral class of device, becomes discoverable, accepts the
/// iPhone's L2CAP channels on PSM 0x11 (control) and 0x13 (interrupt), answers HIDP requests, and sends
/// 0xA1 input reports on the interrupt channel, paced on a serial schedule.
///
/// All IOBluetooth objects live on the main thread (its callbacks arrive on the main run loop).
public final class BluetoothHIDTransport: HIDTransport, @unchecked Sendable {
    public let state = StateChannel<HIDConnectionState>(.off)
    /// Minimum time between two reports (iOS drops input that arrives faster than it polls).
    public let minimumReportInterval: TimeInterval
    private let log: Log
    private let pacer: ReportPacer
    private var session: BluetoothHIDSession?   // main thread only
    private let warningsLock = NSLock()
    private var _warnings: [OpenTapError] = []
    public var pairingWarnings: [OpenTapError] { warningsLock.withLock { _warnings } }

    public init(log: Log) {
        self.log = log
        self.minimumReportInterval = 0.008
        self.pacer = ReportPacer(interval: 0.008)
    }

    public func start() async throws {
        try await MainActor.run { try self.startOnMain() }
    }

    public func stop() {
        if Thread.isMainThread { stopOnMain() } else { DispatchQueue.main.async { self.stopOnMain() } }
    }

    public func send(_ report: HIDReport) async throws {
        guard state.value.isConnected else { throw BluetoothHIDErrors.notConnected(state.value) }
        await pacer.waitTurn()
        let packet = report.interruptPacket
        try await MainActor.run {
            guard let session = self.session else { throw BluetoothHIDErrors.notConnected(self.state.value) }
            try session.sendInterrupt(packet)
        }
    }

    // MARK: Main thread

    private func startOnMain() throws {
        if let s = session, s.isRunning { return }
        do {
            try BluetoothHIDErrors.checkPermission()
            guard let host = IOBluetoothHostController.default(),
                  host.powerState == kBluetoothHCIPowerStateON else {
                throw BluetoothHIDErrors.poweredOff
            }
            let s = BluetoothHIDSession(log: log, host: host,
                                        warn: { [weak self] w in self?.warningsLock.withLock { self?._warnings = w } },
                                        publish: { [weak self] newState in self?.state.send(newState) })
            try s.start()
            session = s
        } catch let e as OpenTapError {
            switch e.code {
            case .permissionDenied, .bluetoothUnavailable: state.send(.unavailable(e))
            default: state.send(.failed(e))
            }
            log.error("bluetooth", e)
            throw e
        }
    }

    private func stopOnMain() {
        session?.stop()
        session = nil
        warningsLock.withLock { _warnings = [] }
        state.send(.off)
    }
}

// MARK: - Errors

enum BluetoothHIDErrors {
    static func notConnected(_ state: HIDConnectionState) -> OpenTapError {
        let why: String
        switch state {
        case .off: why = "OpenTap's Bluetooth keyboard and mouse is not started"
        case .advertising: why = "The iPhone has not connected to OpenTap over Bluetooth yet"
        case .connecting: why = "The iPhone is still connecting (only one of the two HID channels is open)"
        case .unavailable(let e), .failed(let e): why = e.why
        case .connected: why = "The Bluetooth link to the iPhone just closed"
        }
        return OpenTapError(.hidNotConnected, what: "Couldn't send input to the iPhone", why: why,
                            fix: "On the iPhone open Settings > Bluetooth and tap this Mac under My Devices (or Other Devices the first time); keep OpenTap running")
    }

    static let poweredOff = OpenTapError(.bluetoothUnavailable, what: "Couldn't start OpenTap's Bluetooth keyboard and mouse",
                                         why: "Bluetooth is turned off on this Mac (or the Mac has no Bluetooth)",
                                         fix: "Turn Bluetooth on in Control Center or System Settings > Bluetooth, then try again")

    static func checkPermission() throws {
        switch CBManager.authorization {
        case .denied:
            throw OpenTapError(.permissionDenied, what: "Couldn't start OpenTap's Bluetooth keyboard and mouse",
                               why: "Bluetooth access is denied for OpenTap",
                               fix: "Open System Settings > Privacy & Security > Bluetooth, turn on OpenTap, then reopen OpenTap")
        case .restricted:
            throw OpenTapError(.permissionDenied, what: "Couldn't start OpenTap's Bluetooth keyboard and mouse",
                               why: "Bluetooth access is restricted on this Mac (by a profile or parental controls)",
                               fix: "Ask the Mac's administrator to allow Bluetooth for OpenTap")
        default: return   // notDetermined: IOBluetooth use triggers the prompt; allowedAlways: fine.
        }
    }

    static func io(_ what: String, _ ret: IOReturn, fix: String) -> OpenTapError {
        OpenTapError(.io, what: what, why: String(format: "macOS Bluetooth returned error 0x%08X", UInt32(bitPattern: ret)), fix: fix)
    }
}

// MARK: - Pacing

/// Hands out send slots at least `interval` apart, in call order.
actor ReportPacer {
    private let interval: Duration
    private var nextSlot: ContinuousClock.Instant?

    init(interval: TimeInterval) { self.interval = .microseconds(Int64(interval * 1_000_000)) }

    func waitTurn() async {
        let now = ContinuousClock.now
        let slot = max(now, nextSlot ?? now)
        nextSlot = slot + interval
        if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
    }
}

// MARK: - Session (main thread)

/// Owns the SDP record, the channel-open notifications and the two L2CAP channels. Main thread only.
final class BluetoothHIDSession: NSObject, IOBluetoothL2CAPChannelDelegate {
    private static let lastHostKey = "OpenTap.bluetooth.lastHostAddress"
    private static let classRefreshSeconds: TimeInterval = 240

    private let log: Log
    private let host: IOBluetoothHostController
    private let publish: (HIDConnectionState) -> Void
    private let warn: ([OpenTapError]) -> Void
    private var record: IOBluetoothSDPServiceRecord?
    private var notifications: [IOBluetoothUserNotification] = []
    private var control: IOBluetoothL2CAPChannel?
    private var interrupt: IOBluetoothL2CAPChannel?
    /// Channels OpenTap dialled itself (ReconnectInitiate). Only for these may we open the interrupt channel:
    /// under the HID profile the side that opened control opens interrupt; the acceptor must not.
    private var outboundControl: IOBluetoothL2CAPChannel?
    private var outboundInterrupt: IOBluetoothL2CAPChannel?
    private var responder = HIDPControlResponder()
    private var previousDiscoverable: Bool?
    private var classTimer: Timer?
    private(set) var isRunning = false
    private var advertisedName: String

    init(log: Log, host: IOBluetoothHostController, warn: @escaping ([OpenTapError]) -> Void,
         publish: @escaping (HIDConnectionState) -> Void) {
        self.log = log
        self.host = host
        self.warn = warn
        self.publish = publish
        self.advertisedName = host.nameAsString() ?? HIDDescriptor.deviceName
    }

    func start() throws {
        guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: HIDDescriptor.serviceRecordDictionary) else {
            throw OpenTapError(.bluetoothUnavailable, what: "Couldn't publish OpenTap's Bluetooth keyboard and mouse service",
                               why: "macOS refused the HID service record",
                               fix: "Turn Bluetooth off and on in Control Center and try again; if it keeps failing, restart the Mac")
        }
        record = rec
        for psm in [HIDDescriptor.controlPSM, HIDDescriptor.interruptPSM] {
            guard let n = IOBluetoothL2CAPChannel.register(forChannelOpenNotifications: self,
                                                           selector: #selector(channelOpened(_:channel:)),
                                                           withPSM: BluetoothL2CAPPSM(psm),
                                                           direction: kIOBluetoothUserNotificationChannelDirectionIncoming) else {
                stop()
                throw OpenTapError(.bluetoothUnavailable, what: "Couldn't listen for the iPhone's Bluetooth connection",
                                   why: String(format: "macOS refused to open L2CAP PSM 0x%02X (another app may be using it)", psm),
                                   fix: "Quit other apps that act as a Bluetooth keyboard or mouse, then try again")
            }
            notifications.append(n)
        }
        isRunning = true
        let classOK = applyClassOfDevice()
        classTimer = Timer.scheduledTimer(withTimeInterval: Self.classRefreshSeconds, repeats: true) { [weak self] _ in
            self?.applyClassOfDevice()
        }
        let discoverableOK = makeDiscoverable(true)
        // Published before .advertising so the UI reads them together with the state change.
        warn((discoverableOK ? [] : [HIDPairingWarnings.notDiscoverable]) + (classOK ? [] : [HIDPairingWarnings.classNotSet]))
        log.info("bluetooth", "HID service published; waiting for the iPhone on PSM 0x11/0x13 as \"\(advertisedName)\"")
        publish(.advertising(name: advertisedName))
        reconnectToLastHost()
    }

    func stop() {
        isRunning = false
        classTimer?.invalidate(); classTimer = nil
        control?.setDelegate(nil); interrupt?.setDelegate(nil)
        _ = interrupt?.close(); _ = control?.close()
        interrupt = nil; control = nil; outboundControl = nil; outboundInterrupt = nil
        notifications.forEach { $0.unregister() }
        notifications.removeAll()
        if let r = record { _ = r.remove() }
        record = nil
        if let prev = previousDiscoverable { setDiscoverable(prev) }
        previousDiscoverable = nil
        log.info("bluetooth", "HID service stopped")
    }

    func sendInterrupt(_ packet: [UInt8]) throws {
        guard let ch = interrupt, control != nil else { throw BluetoothHIDErrors.notConnected(.connecting) }
        try write(packet, on: ch, what: "Couldn't send input to the iPhone")
    }

    private func write(_ bytes: [UInt8], on channel: IOBluetoothL2CAPChannel, what: String) throws {
        var buf = bytes
        let ret = buf.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
        if ret != kIOReturnSuccess {
            throw BluetoothHIDErrors.io(what, ret,
                fix: "Keep the iPhone close to the Mac; if it keeps failing, turn the iPhone's Bluetooth off and on and reconnect to this Mac")
        }
    }

    // MARK: Channels

    @objc func channelOpened(_ note: IOBluetoothUserNotification, channel: IOBluetoothL2CAPChannel) {
        adopt(channel)
    }

    private func adopt(_ channel: IOBluetoothL2CAPChannel) {
        guard isRunning else { _ = channel.close(); return }
        let psm = UInt16(channel.psm)
        let incoming = channel !== outboundControl && channel !== outboundInterrupt
        // A different host than the one already connected replaces it (only when that host dialled us; our own
        // reconnect to an old host never kicks out a live connection).
        if let existing = control ?? interrupt, let d = existing.device, let nd = channel.device,
           d.addressString != nd.addressString {
            if !incoming {
                channel.setDelegate(nil); _ = channel.close()
                if channel === outboundControl { outboundControl = nil } else { outboundInterrupt = nil }
                return
            }
            log.info("bluetooth", "\(nd.nameOrAddress ?? "another device") is connecting; dropping \(d.nameOrAddress ?? "previous host")")
            closeChannels()
        }
        channel.setDelegate(self)
        switch psm {
        case HIDDescriptor.controlPSM:
            if let old = control, old !== channel {
                if !incoming, old !== outboundControl {
                    // Our reconnect finished after the iPhone already opened its own: keep the iPhone's.
                    log.debug("bluetooth", "iPhone already opened the control channel; dropping OpenTap's reconnect")
                    channel.setDelegate(nil); _ = channel.close(); outboundControl = nil
                    return
                }
                old.setDelegate(nil); _ = old.close()
            }
            if incoming, let ours = outboundInterrupt, ours !== interrupt { ours.setDelegate(nil); _ = ours.close(); outboundInterrupt = nil }
            if incoming { outboundControl = nil }
            if control !== channel { responder = HIDPControlResponder() }   // fresh connection, fresh HIDP state
            control = channel
        case HIDDescriptor.interruptPSM:
            if let old = interrupt, old !== channel {
                if !incoming, old !== outboundInterrupt {
                    log.debug("bluetooth", "iPhone already opened the interrupt channel; dropping OpenTap's")
                    channel.setDelegate(nil); _ = channel.close(); outboundInterrupt = nil
                    return
                }
                old.setDelegate(nil); _ = old.close()
                if old === outboundInterrupt { outboundInterrupt = nil }
            }
            interrupt = channel
        default:
            log.warning("bluetooth", String(format: "Ignoring L2CAP channel on unexpected PSM 0x%02X", psm))
            channel.setDelegate(nil); _ = channel.close()
            return
        }
        log.debug("bluetooth", String(format: "L2CAP PSM 0x%02X open from %@", psm, channel.device?.nameOrAddress ?? "?"))
        updateState()
    }

    private func updateState() {
        guard isRunning else { return }
        if let c = control, interrupt != nil {
            let dev = c.device
            if let addr = dev?.addressString { UserDefaults.standard.set(addr, forKey: Self.lastHostKey) }
            log.info("bluetooth", "Connected to \(dev?.nameOrAddress ?? "iPhone") as a keyboard and mouse")
            publish(.connected(hostName: dev?.name))
        } else if control != nil || interrupt != nil {
            publish(.connecting)
        } else {
            publish(.advertising(name: advertisedName))
        }
    }

    private func closeChannels() {
        for ch in [interrupt, control, outboundControl, outboundInterrupt].compactMap({ $0 }) { ch.setDelegate(nil); _ = ch.close() }
        interrupt = nil; control = nil; outboundControl = nil; outboundInterrupt = nil
        responder = HIDPControlResponder()
    }

    func l2capChannelOpenComplete(_ l2capChannel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        guard let ch = l2capChannel else { return }
        if error == kIOReturnSuccess {
            let ours = ch === outboundControl
            adopt(ch)
            // Outbound reconnect only (we opened control, so we open interrupt). Never for the iPhone's channels.
            if ours, ch === control, UInt16(ch.psm) == HIDDescriptor.controlPSM, interrupt == nil, let dev = ch.device {
                openOutbound(HIDDescriptor.interruptPSM, on: dev)
            }
        } else {
            if ch === outboundControl { outboundControl = nil }
            if ch === outboundInterrupt { outboundInterrupt = nil }
            log.debug("bluetooth", String(format: "L2CAP PSM 0x%02X failed to open (0x%08X)", UInt16(ch.psm), UInt32(bitPattern: error)))
        }
    }

    func l2capChannelClosed(_ l2capChannel: IOBluetoothL2CAPChannel!) {
        guard let ch = l2capChannel else { return }
        if ch === control { control = nil }
        if ch === interrupt { interrupt = nil }
        if ch === outboundControl { outboundControl = nil }
        if ch === outboundInterrupt { outboundInterrupt = nil }
        // A new connection starts in report protocol with default idle/LEDs (HIDP state is per connection).
        if control == nil && interrupt == nil { responder = HIDPControlResponder() }
        log.info("bluetooth", String(format: "L2CAP PSM 0x%02X closed", UInt16(ch.psm)))
        updateState()
    }

    func l2capChannelData(_ l2capChannel: IOBluetoothL2CAPChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let ch = l2capChannel, let p = dataPointer, dataLength > 0 else { return }
        let bytes = [UInt8](UnsafeRawBufferPointer(start: p, count: dataLength))
        if ch === control {
            let outcome = responder.handleControl(bytes)
            if let reply = outcome.reply {
                do { try write(reply, on: ch, what: "Couldn't answer the iPhone's HID request") } catch let e as OpenTapError {
                    log.warning("bluetooth", e.description)
                } catch {}
            }
            handle(outcome.event)
        } else if ch === interrupt {
            handle(responder.handleInterrupt(bytes))
        }
    }

    private func handle(_ event: HIDPControlResponder.Event) {
        switch event {
        case .none: break
        case .protocolChanged(let boot):
            log.info("bluetooth", boot ? "iPhone switched to boot protocol (keyboard only)" : "iPhone uses report protocol")
        case .suspend: log.debug("bluetooth", "iPhone suspended the HID link")
        case .exitSuspend: log.debug("bluetooth", "iPhone resumed the HID link")
        case .reset: log.debug("bluetooth", "iPhone asked for a HID reset")
        case .virtualCableUnplug:
            log.info("bluetooth", "iPhone unplugged the virtual cable (forgot or disconnected OpenTap)")
            UserDefaults.standard.removeObject(forKey: Self.lastHostKey)
            closeChannels()
            updateState()
        case .leds(let l): log.debug("bluetooth", String(format: "Keyboard LEDs 0x%02X", l))
        case .ignored(let why): log.debug("bluetooth", "HIDP: \(why)")
        }
    }

    // MARK: Reconnect

    /// ReconnectInitiate: if the iPhone was connected before and is still paired, open the channels ourselves.
    private func reconnectToLastHost() {
        guard let addr = UserDefaults.standard.string(forKey: Self.lastHostKey),
              let dev = IOBluetoothDevice(addressString: addr), dev.isPaired() else { return }
        log.info("bluetooth", "Reconnecting to \(dev.nameOrAddress ?? addr)")
        openOutbound(HIDDescriptor.controlPSM, on: dev)
    }

    private func openOutbound(_ psm: UInt16, on dev: IOBluetoothDevice) {
        var ch: IOBluetoothL2CAPChannel?
        let ret = dev.openL2CAPChannelAsync(&ch, withPSM: BluetoothL2CAPPSM(psm), delegate: self)
        if ret == kIOReturnSuccess, let ch {
            if psm == HIDDescriptor.controlPSM { outboundControl = ch } else { outboundInterrupt = ch }
        }
        if ret != kIOReturnSuccess {
            log.debug("bluetooth", String(format: "Reconnect on PSM 0x%02X not started (0x%08X); waiting for the iPhone", psm, UInt32(bitPattern: ret)))
        }
    }

    // MARK: Class of device / discoverability (best effort, private SPI resolved at runtime)

    @discardableResult
    private func applyClassOfDevice() -> Bool {
        let sel = NSSelectorFromString("setClassOfDevice:forTimeInterval:")
        guard host.responds(to: sel) else {
            log.warning("bluetooth", "Can't set the Bluetooth class to keyboard/mouse on this macOS; the iPhone may list this Mac as a computer")
            return false
        }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt32, Double) -> Int32
        let fn = unsafeBitCast(host.method(for: sel), to: Fn.self)
        let ret = fn(host, sel, HIDDescriptor.classOfDevice, Self.classRefreshSeconds + 60)
        if ret != kIOReturnSuccess {
            log.warning("bluetooth", String(format: "Setting the Bluetooth class of device failed (0x%08X)", UInt32(bitPattern: ret)))
            return false
        }
        return true
    }

    private typealias GetDiscoverable = @convention(c) () -> Int32
    private typealias SetDiscoverable = @convention(c) (Int32) -> Void

    private func makeDiscoverable(_ on: Bool) -> Bool {
        if previousDiscoverable == nil, let get = Self.symbol("IOBluetoothPreferenceGetDiscoverableState", as: GetDiscoverable.self) {
            previousDiscoverable = get() != 0
        }
        if !setDiscoverable(on) {
            log.warning("bluetooth", "Couldn't make this Mac discoverable automatically; keep System Settings > Bluetooth open while pairing")
            return false
        }
        return true
    }

    @discardableResult
    private func setDiscoverable(_ on: Bool) -> Bool {
        guard let set = Self.symbol("IOBluetoothPreferenceSetDiscoverableState", as: SetDiscoverable.self) else { return false }
        set(on ? 1 : 0)
        return true
    }

    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
}
