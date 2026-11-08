import Foundation

/// USB / lockdown link over Apple's private MobileDevice.framework (dlopen'd, never linked).
///
/// - Attach/detach notifications arrive on a dedicated CFRunLoop thread owned by the API.
/// - Every AMDevice call is serialized on `queue`.
/// - If the framework or a symbol is missing, `state` becomes `.unavailable(error)` whose `fix` holds manual steps.
/// - Never pairs or writes values on its own: only `pair()` / `setAssistiveTouch(_:)` do, when the app asks.
public final class MobileDeviceLink: DeviceLink, @unchecked Sendable {
    public let state = StateChannel<DeviceLinkState>(.idle)

    /// Every iPhone currently attached over USB, most recent last. Safe to call from any thread.
    public var attachedDevices: [DeviceInfo] { snapshotLock.withLock { snapshot } }

    private let log: Log
    private let apiProvider: () -> Result<MobileDeviceAPI, OpenTapError>
    private let pairTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "OpenTap.MobileDeviceLink")
    private let snapshotLock = NSLock()
    private var snapshot: [DeviceInfo] = []

    // Queue-confined state.
    private var api: MobileDeviceAPI?
    private var loadError: OpenTapError?
    private var running = false
    private var devices: [MDDevice: Entry] = [:]
    private var order: [MDDevice] = []

    private struct Entry { var info: DeviceInfo; var trust: TrustState }

    static let usbInterface = 1
    static let category = "device"

    public convenience init(log: Log) {
        self.init(log: log, apiProvider: { MobileDeviceFramework.load() })
    }

    /// Injectable initializer: tests pass a fake API, or a provider that fails like a missing framework.
    public init(log: Log, apiProvider: @escaping () -> Result<MobileDeviceAPI, OpenTapError>,
                pairTimeout: TimeInterval = 120, pollInterval: TimeInterval = 1.0) {
        self.log = log
        self.apiProvider = apiProvider
        self.pairTimeout = pairTimeout
        self.pollInterval = pollInterval
    }

    deinit {
        if running { api?.unsubscribe() }
        for d in order { api?.release(d) }
    }

    // MARK: DeviceLink

    public func start() async {
        let newState: DeviceLinkState? = queue.sync {
            if running { return nil }
            if api == nil && loadError == nil {
                switch apiProvider() {
                case .success(let a): api = a
                case .failure(let e): loadError = e
                }
            }
            if let e = loadError { return .unavailable(e) }
            guard let api else { return nil }
            do {
                try api.subscribe { [weak self] event in self?.handle(event) }
                running = true
                log.info(Self.category, "Watching for iPhones on USB")
                return order.isEmpty ? .noDevice : nil
            } catch {
                return .unavailable(OpenTapError.wrap(error, what: "Couldn't watch for iPhones on USB",
                                                      fix: MobileDeviceFramework.manualFallback))
            }
        }
        if let newState {
            if case .unavailable(let e) = newState { log.error(Self.category, e) }
            state.send(newState)
        }
    }

    public func stop() {
        let wasRunning: Bool = queue.sync {
            guard running else { return false }
            api?.unsubscribe()
            for d in order { api?.release(d) }
            devices.removeAll(); order.removeAll()
            publishSnapshot()
            running = false
            return true
        }
        if wasRunning { state.send(.idle) }
    }

    public func isPaired() async throws -> Bool {
        try await onQueue { api, dev, entry in
            try self.withConnection(api, dev, entry.info) {
                api.isPaired(dev) && api.validatePairing(dev) == 0
            }
        }
    }

    public func pair() async throws {
        let deadline = Date().addingTimeInterval(pairTimeout)
        var unknownStreak = 0
        var lastLocked = false
        var announced = false
        while true {
            let (result, name) = try await onQueue { api, dev, entry -> (AMDResult, String) in
                guard api.capabilities.canPair else {
                    throw OpenTapError(.frameworkUnavailable, what: "Couldn't ask \(entry.info.name) to trust this Mac",
                                       why: "This macOS version's MobileDevice framework has no AMDevicePair",
                                       fix: ManualSteps.trust)
                }
                return (self.pairAttempt(api, dev), entry.info.name)
            }
            switch result {
            case .ok:
                log.info(Self.category, "\(name) trusts this Mac")
                return
            case .pending:
                lastLocked = false; unknownStreak = 0
                if !announced { log.info(Self.category, "Waiting for Trust on \(name)"); announced = true }
                setTrust(.awaitingUserTrust)
            case .locked:
                lastLocked = true; unknownStreak = 0
                setTrust(.locked)
            case .denied:
                setTrust(.denied)
                let e = OpenTapError(.notPaired, what: "\(name) didn't trust this Mac",
                                     why: "\"Don't Trust\" was tapped on the iPhone", fix: ManualSteps.denied)
                log.error(Self.category, e)
                throw e
            case .notPaired, .other:
                unknownStreak += 1
                if unknownStreak >= 3 {
                    let code: Int32
                    if case .other(let c) = result { code = c } else { code = AMDResult.invalidHostIDCode }
                    let e = AMDResult.error(code, what: "Couldn't pair with \(name)", deviceName: name)!
                    log.error(Self.category, e)
                    throw e
                }
            }
            if Date() >= deadline {
                let e = lastLocked
                    ? OpenTapError(.deviceLocked, what: "Couldn't pair with \(name)",
                                   why: "\(name) stayed locked for \(Int(pairTimeout)) seconds",
                                   fix: ManualSteps.unlock + ", then tap Trust when the alert appears")
                    : OpenTapError(.timeout, what: "Couldn't pair with \(name)",
                                   why: "Nobody tapped Trust on the iPhone within \(Int(pairTimeout)) seconds",
                                   fix: "Unlock \(name), look for \"Trust This Computer?\", tap Trust and enter your passcode. If no alert shows: \(ManualSteps.trust)")
                log.error(Self.category, e)
                throw e
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            } catch {
                throw OpenTapError(.timeout, what: "Pairing with \(name) was cancelled",
                                   why: "OpenTap stopped waiting for the Trust alert", fix: "Start pairing again")
            }
        }
    }

    public func assistiveTouchEnabled() async throws -> Bool {
        try await onQueue { api, dev, entry in
            try self.withSession(api, dev, entry.info, what: "Couldn't read AssistiveTouch on \(entry.info.name)") {
                let v = api.copyValue(dev, domain: LockdownKeys.accessibilityDomain, key: LockdownKeys.assistiveTouchKey)
                // Absent key = never set over USB; treat as off (the pointer check is the real verification).
                return DeviceValueParser.bool(v) ?? false
            }
        }
    }

    public func setAssistiveTouch(_ enabled: Bool) async throws {
        let onOff = enabled ? "on" : "off"
        try await onQueue { api, dev, entry in
            let what = "Couldn't turn \(onOff) AssistiveTouch on \(entry.info.name) automatically"
            let manual = enabled ? ManualSteps.assistiveTouch
                : "On the iPhone open Settings > Accessibility > Touch > AssistiveTouch and turn it off"
            guard api.capabilities.canSetValues else {
                throw OpenTapError(.frameworkUnavailable, what: what,
                                   why: "This macOS version's MobileDevice framework has no AMDeviceSetValue",
                                   fix: manual)
            }
            try self.withSession(api, dev, entry.info, what: what, fallback: manual) {
                let rc = api.setValue(dev, domain: LockdownKeys.accessibilityDomain,
                                      key: LockdownKeys.assistiveTouchKey, value: NSNumber(value: enabled))
                if let e = AMDResult.error(rc, what: what, deviceName: entry.info.name, fallback: manual) {
                    throw Self.withManual(e, manual)
                }
            }
            self.log.info(Self.category, "AssistiveTouch turned \(onOff) on \(entry.info.name)")
        }
    }

    // MARK: Notifications (run-loop thread -> queue)

    private func handle(_ event: MDDeviceEvent) {
        switch event {
        case .attached(let dev):
            api?.retain(dev)   // keep the handle valid past the callback
            queue.async { self.attach(dev) }
        case .detached(let dev):
            queue.async { self.detach(dev) }
        }
    }

    private func attach(_ dev: MDDevice) {
        guard let api else { return }
        guard running, devices[dev] == nil else { api.release(dev); return }
        if api.capabilities.canFilterInterface, let t = api.interfaceType(dev), t != Self.usbInterface {
            log.debug(Self.category, "Ignoring an iPhone seen over Wi-Fi; plug it in with USB")
            api.release(dev)
            return
        }
        let (info, trust) = readDevice(api, dev)
        devices[dev] = Entry(info: info, trust: trust)
        order.removeAll { $0 == dev }
        order.append(dev)
        publishSnapshot()
        log.info(Self.category, "\(info.name) attached (\(info.productType), iOS \(info.iosVersion), \(trust.rawValue))")
        state.send(.attached(info, trust: trust))
    }

    private func detach(_ dev: MDDevice) {
        guard let entry = devices.removeValue(forKey: dev) else { return }
        order.removeAll { $0 == dev }
        api?.release(dev)
        publishSnapshot()
        log.info(Self.category, "\(entry.info.name) detached")
        if let last = order.last, let e = devices[last] {
            state.send(.attached(e.info, trust: e.trust))
        } else {
            state.send(.noDevice)
        }
    }

    private func publishSnapshot() {
        let infos = order.compactMap { devices[$0]?.info }
        snapshotLock.withLock { snapshot = infos }
    }

    /// Reads identity + trust. Never throws: an unreadable device still shows up with fallback values.
    private func readDevice(_ api: MobileDeviceAPI, _ dev: MDDevice) -> (DeviceInfo, TrustState) {
        let udid = api.identifier(dev)
        let rc = api.connect(dev)
        guard rc == 0 else {
            log.warning(Self.category, "Couldn't connect to the iPhone (\(AMDResult.hex(rc))); showing basic info only")
            let trust: TrustState = AMDResult(rc) == .locked ? .locked : .unknown
            return (DeviceValueParser.deviceInfo(udid: udid, values: [:]), trust)
        }
        defer { _ = api.disconnect(dev) }
        return readConnected(api, dev, udid: udid)
    }

    /// Device must be connected. Reads values inside a session when paired (more keys are readable then).
    private func readConnected(_ api: MobileDeviceAPI, _ dev: MDDevice, udid: String?) -> (DeviceInfo, TrustState) {
        var trust: TrustState = .notPaired
        var sessionOpen = false
        if api.isPaired(dev) {
            switch AMDResult(api.validatePairing(dev)) {
            case .ok:
                trust = .paired
                let s = api.startSession(dev)
                if s == 0 { sessionOpen = true } else if AMDResult(s) == .locked { trust = .locked }
            case .locked: trust = .locked
            default: trust = .notPaired
            }
        }
        var values: [String: Any] = [:]
        for key in LockdownKeys.infoKeys {
            if let v = api.copyValue(dev, domain: nil, key: key) { values[key] = v }
        }
        if sessionOpen { _ = api.stopSession(dev) }
        return (DeviceValueParser.deviceInfo(udid: udid, values: values), trust)
    }

    /// One pairing attempt (runs on the queue). Updates the stored entry and state on success.
    private func pairAttempt(_ api: MobileDeviceAPI, _ dev: MDDevice) -> AMDResult {
        let udid = api.identifier(dev)
        let rc = api.connect(dev)
        if rc != 0 { return AMDResult(rc) }
        defer { _ = api.disconnect(dev) }
        if api.isPaired(dev), api.validatePairing(dev) == 0 {
            finishPaired(api, dev, udid: udid)
            return .ok
        }
        let result = AMDResult(api.pair(dev))
        guard result == .ok else { return result }
        let v = AMDResult(api.validatePairing(dev))
        guard v == .ok else { return v }
        finishPaired(api, dev, udid: udid)
        return .ok
    }

    private func finishPaired(_ api: MobileDeviceAPI, _ dev: MDDevice, udid: String?) {
        let (info, _) = readConnected(api, dev, udid: udid)
        devices[dev] = Entry(info: info, trust: .paired)
        publishSnapshot()
        if order.last == dev { state.send(.attached(info, trust: .paired)) }
    }

    private func setTrust(_ trust: TrustState) {
        let s: DeviceLinkState? = queue.sync {
            guard let dev = order.last, var e = devices[dev], e.trust != trust else { return nil }
            e.trust = trust
            devices[dev] = e
            return .attached(e.info, trust: trust)
        }
        if let s { state.send(s) }
    }

    // MARK: Helpers

    /// Appends the manual path to an error's fix unless it already contains it.
    static func withManual(_ e: OpenTapError, _ manual: String) -> OpenTapError {
        e.fix.contains(manual) ? e : OpenTapError(e.code, what: e.what, why: e.why, fix: e.fix + ". Or by hand: \(manual)")
    }

    /// Runs `body` on the queue with the current device, or throws a clear unavailable / no-device error.
    private func onQueue<T>(_ body: @escaping (MobileDeviceAPI, MDDevice, Entry) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    if let e = self.loadError { throw e }
                    guard let api = self.api, self.running else {
                        throw OpenTapError(.noDevice, what: "The iPhone USB link isn't running",
                                           why: "USB device detection hasn't been started",
                                           fix: "Open the OpenTap window (or rerun onboarding) so it starts watching for the iPhone")
                    }
                    guard let dev = self.order.last, let entry = self.devices[dev] else {
                        throw OpenTapError(.noDevice, what: "No iPhone connected",
                                           why: "OpenTap doesn't see an iPhone on USB",
                                           fix: "Plug the iPhone into this Mac with a USB cable and unlock it")
                    }
                    cont.resume(returning: try body(api, dev, entry))
                } catch {
                    cont.resume(throwing: OpenTapError.wrap(error, what: "iPhone USB operation failed"))
                }
            }
        }
    }

    private func withConnection<T>(_ api: MobileDeviceAPI, _ dev: MDDevice, _ info: DeviceInfo,
                                   what: String? = nil, _ body: () throws -> T) throws -> T {
        let rc = api.connect(dev)
        if let e = AMDResult.error(rc, what: what ?? "Couldn't connect to \(info.name)", deviceName: info.name) { throw e }
        defer { _ = api.disconnect(dev) }
        return try body()
    }

    /// Connect + validate pairing + lockdown session, then `body`. Errors say unlock / trust as appropriate.
    private func withSession<T>(_ api: MobileDeviceAPI, _ dev: MDDevice, _ info: DeviceInfo, what: String,
                                fallback: String = ManualSteps.assistiveTouch, _ body: () throws -> T) throws -> T {
        try withConnection(api, dev, info, what: what) {
            guard api.isPaired(dev) else {
                throw OpenTapError(.notPaired, what: what, why: "\(info.name) doesn't trust this Mac yet",
                                   fix: "Finish the Trust step first (\(ManualSteps.trust)), or by hand: \(fallback)")
            }
            for step in [{ api.validatePairing(dev) }, { api.startSession(dev) }] {
                if let e = AMDResult.error(step(), what: what, deviceName: info.name, fallback: fallback) {
                    throw Self.withManual(e, fallback)
                }
            }
            defer { _ = api.stopSession(dev) }
            return try body()
        }
    }
}
