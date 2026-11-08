import AppKit
import CoreGraphics
import OpenTapCore
import SwiftUI

/// The app's single source of UI state. Composes the core modules through the Shared protocols
/// (constructor-injected via OpenTapEnvironment, so previews and tests use the mocks).
@MainActor
final class AppModel: ObservableObject {
    static let onboardingDoneKey = "onboardingDone"

    let env: OpenTapEnvironment
    private let defaults: UserDefaults

    // Mirrors of the core state channels (always updated on the main actor).
    @Published private(set) var status = StatusSnapshot()
    @Published private(set) var permissions: [Permission: PermissionStatus] = [:]
    @Published private(set) var deviceState: DeviceLinkState = .idle
    @Published private(set) var frameState: FrameSourceState = .idle
    @Published private(set) var hidState: HIDConnectionState = .off
    @Published private(set) var mcpState: MCPServerState = .stopped

    // Live preview.
    @Published private(set) var preview: CGImage?
    @Published private(set) var frameSize: CGSize?
    /// Last tap in screenshot space (what agents use), for the preview overlay.
    @Published private(set) var lastTap: CGPoint?
    @Published private(set) var lastTapAt: Date?
    @Published private(set) var logEntries: [LogEntry] = []

    // Onboarding.
    @Published var currentStep: OnboardingStep = .permissions
    @Published private(set) var stepErrors: [OnboardingStep: OpenTapError] = [:]
    @Published private(set) var working: Set<OnboardingStep> = []
    @Published private(set) var skipped: Set<OnboardingStep> = []
    @Published private(set) var pointerDetected = false
    @Published private(set) var assistiveTouchAutoEnabled: Bool?
    @Published private(set) var calibrationProgress: CalibrationProgress?
    @Published private(set) var agentTest: AgentTestState = .idle
    @Published private(set) var claudeInstall: ClaudeInstallState = .idle
    @Published var showOnboarding: Bool
    @Published private(set) var onboardingDone: Bool {
        didSet { defaults.set(onboardingDone, forKey: Self.onboardingDoneKey) }
    }
    @Published var clickToTap = false

    private var subscriptions: [OpenTapCore.Subscription] = []
    private var timers: [Timer] = []
    private var lastPreviewFrame = -1
    private var advanceTask: Task<Void, Never>?
    private var pointerProbe: Task<Void, Never>?
    private var pairRequestedFor: String?
    private var started: Set<String> = []

    init(environment: OpenTapEnvironment, defaults: UserDefaults = .standard, autostart: Bool = true) {
        env = environment
        self.defaults = defaults
        let done = defaults.bool(forKey: Self.onboardingDoneKey)
        onboardingDone = done
        showOnboarding = !done
        logEntries = Array(environment.log.entries.suffix(300))
        bindChannels()
        refreshPermissions()
        if autostart {
            startServices()
            if showOnboarding { enter(currentStep) }
        }
    }

    static func live() -> AppModel { AppModel(environment: .live()) }

    // MARK: - Wiring

    private func bindChannels() {
        func onMain<V>(_ channel: StateChannel<V>, _ apply: @escaping @MainActor (AppModel, V) -> Void) {
            subscriptions.append(channel.subscribe { [weak self] value in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { if let self { apply(self, value) } }
                } else {
                    DispatchQueue.main.async { if let self { apply(self, value) } }
                }
            })
        }
        onMain(env.status.snapshot) { m, v in m.status = v; m.evaluate() }
        onMain(env.device.state) { m, v in m.deviceState = v; m.deviceChanged(v); m.evaluate() }
        onMain(env.frames.state) { m, v in m.frameState = v; m.evaluate() }
        onMain(env.hid.state) { m, v in m.hidState = v; m.evaluate() }
        onMain(env.mcp.state) { m, v in m.mcpState = v; m.evaluate() }

        subscriptions.append(env.log.updates.subscribe { [weak self] entry in
            DispatchQueue.main.async { self?.append(entry) }
        })

        // Preview: poll the frame counter (~15 fps) rather than pushing every frame through Combine.
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullFrame() }
        })
        // Permissions can change in System Settings at any time.
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        })
    }

    private func pullFrame() {
        let count = env.frames.frameCount
        guard count != lastPreviewFrame, let frame = env.frames.latestFrame else { return }
        lastPreviewFrame = count
        preview = frame
        frameSize = env.frames.frameSize ?? CGSize(width: frame.width, height: frame.height)
        if case .screen = currentStep { evaluate() }
    }

    private func append(_ entry: LogEntry) {
        logEntries.append(entry)
        if logEntries.count > 300 { logEntries.removeFirst(logEntries.count - 300) }
        if let p = Self.tapPoint(in: entry) { noteTap(p) }
    }

    /// Best effort: picks up taps performed by agents from the control log ("Tapped (120, 340) ...").
    static func tapPoint(in entry: LogEntry) -> CGPoint? {
        guard entry.category == "control" else { return nil }
        let msg = entry.message
        guard msg.lowercased().hasPrefix("tap") || msg.lowercased().hasPrefix("long") else { return nil }
        guard let open = msg.firstIndex(of: "("), let close = msg[open...].firstIndex(of: ")") else { return nil }
        let parts = msg[msg.index(after: open)..<close].split(separator: ",")
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let x = parts[0], let y = parts[1] else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func noteTap(_ p: CGPoint) {
        lastTap = p
        lastTapAt = Date()
    }

    func refreshPermissions() {
        var next: [Permission: PermissionStatus] = [:]
        for p in Permission.allCases { next[p] = env.permissions.status(p) }
        if next != permissions {
            permissions = next
            if allPermissionsGranted { startCaptureIfNeeded() }
            evaluate()
        }
    }

    // MARK: - Services

    /// Safe to call repeatedly; each service starts at most once (use the restart actions to retry).
    func startServices() {
        once("device") { await self.env.device.start() }
        startMCP()
        startCaptureIfNeeded()
        if onboardingDone { startBluetooth() }
    }

    private func once(_ key: String, _ work: @escaping @MainActor () async -> Void) {
        guard !started.contains(key) else { return }
        started.insert(key)
        Task { await work() }
    }

    func startCaptureIfNeeded() {
        guard permissions[.camera] == .granted else { return }
        switch frameState {
        case .running, .starting: return
        default: break
        }
        guard !started.contains("capture") else { return }
        restartCapture()
    }

    func restartCapture() {
        started.insert("capture")
        stepErrors[.screen] = nil
        Task {
            do { try await env.frames.start() } catch { fail(.screen, error, what: "Couldn't start the iPhone screen") }
        }
    }

    func startBluetooth() {
        switch hidState {
        case .advertising, .connecting, .connected: return
        default: break
        }
        stepErrors[.bluetooth] = nil
        working.insert(.bluetooth)
        Task {
            defer { working.remove(.bluetooth) }
            do { try await env.hid.start() } catch { fail(.bluetooth, error, what: "Couldn't make this Mac a Bluetooth keyboard") }
        }
    }

    func restartBluetooth() {
        env.hid.stop()
        startBluetooth()
    }

    func startMCP() {
        switch mcpState {
        case .listening, .starting: return
        default: break
        }
        stepErrors[.agent] = nil
        Task {
            do { try await env.mcp.start() } catch { fail(.agent, error, what: "Couldn't start the MCP server") }
        }
    }

    func stopMCP() { env.mcp.stop() }

    var mcpRunning: Bool { if case .listening = mcpState { return true }; return false }

    func shutdown() {
        pointerProbe?.cancel()
        env.mcp.stop()
        env.hid.stop()
        env.frames.stop()
        env.device.stop()
    }

    private func fail(_ step: OnboardingStep, _ error: Error, what: String) {
        let e = OpenTapError.wrap(error, what: what)
        stepErrors[step] = e
        env.log.error("app", e)
    }

    // MARK: - Step 1: permissions

    var allPermissionsGranted: Bool { Permission.allCases.allSatisfy { permissions[$0] == .granted } }

    func request(_ p: Permission) {
        Task {
            let s = await env.permissions.request(p)
            refreshPermissions()
            if s == .denied || s == .restricted { env.permissions.openSettings(p) }
        }
    }

    func openSettings(_ p: Permission) { env.permissions.openSettings(p) }

    func permissionError(_ p: Permission) -> OpenTapError? {
        switch permissions[p] ?? .notDetermined {
        case .granted, .notDetermined: return nil
        case .denied, .restricted:
            let pane = p == .camera ? "Camera" : "Bluetooth"
            let why = p == .camera
                ? "macOS delivers the iPhone screen as a camera-like device, and Camera access is off for OpenTap"
                : "OpenTap acts as a Bluetooth keyboard and mouse, and Bluetooth access is off for OpenTap"
            return OpenTapError(.permissionDenied, what: "\(pane) access is turned off", why: why,
                                fix: "Open System Settings > Privacy & Security > \(pane), turn on OpenTap, then come back (it is detected automatically)")
        }
    }

    // MARK: - Step 2: USB / trust

    private func deviceChanged(_ s: DeviceLinkState) {
        guard case .attached(let d, let trust) = s else { pairRequestedFor = nil; return }
        if trust == .paired { stepErrors[.usb] = nil }
        if trust == .notPaired || trust == .unknown, pairRequestedFor != d.udid, showOnboarding {
            pairRequestedFor = d.udid
            requestTrust()
        }
    }

    var deviceLinkUnavailable: Bool { if case .unavailable = deviceState { return true }; return false }

    func requestTrust() {
        stepErrors[.usb] = nil
        working.insert(.usb)
        Task {
            defer { working.remove(.usb) }
            do { try await env.device.pair() } catch { fail(.usb, error, what: "Couldn't ask the iPhone to trust this Mac") }
        }
    }

    func restartDeviceLink() {
        env.device.stop()
        stepErrors[.usb] = nil
        Task { await env.device.start() }
    }

    // MARK: - Step 5: AssistiveTouch

    func enableAssistiveTouchOverUSB() {
        stepErrors[.assistiveTouch] = nil
        working.insert(.assistiveTouch)
        Task {
            defer { working.remove(.assistiveTouch) }
            do {
                try await env.device.setAssistiveTouch(true)
                assistiveTouchAutoEnabled = (try? await env.device.assistiveTouchEnabled()) ?? true
            } catch {
                assistiveTouchAutoEnabled = false
                env.log.warning("app", "AssistiveTouch couldn't be turned on over USB: \(OpenTapError.wrap(error, what: "AssistiveTouch").description)")
            }
            startPointerProbe()
        }
    }

    /// Wiggles the mouse and looks for the pointer dot until it is found or the step is left.
    func startPointerProbe() {
        pointerProbe?.cancel()
        pointerProbe = Task { [weak self] in
            var dx: Int8 = 24
            while !Task.isCancelled {
                guard let self else { return }
                if self.pointerDetected { return }
                if await self.probePointerOnce(dx: dx) { return }
                dx = -dx
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }

    private func probePointerOnce(dx: Int8) async -> Bool {
        guard hidState.isConnected else {
            stepErrors[.assistiveTouch] = OpenTapError(.hidNotConnected, what: "Can't move the pointer yet",
                why: "The iPhone isn't connected to OpenTap over Bluetooth",
                fix: "Finish step 4 (Bluetooth pairing) first")
            return false
        }
        let before = env.frames.latestFrame
        let count = env.frames.frameCount
        do {
            try await env.hid.send(.mouse(MouseReport(dx: dx, dy: dx)))
            try await env.hid.send(.mouse(MouseReport()))
            let after = try await env.frames.waitForFrame(after: count, timeout: 1.5)
            if let hit = env.pointer.locate(in: after, hint: nil, previous: before), hit.confidence >= 0.5 {
                pointerDetected = true
                stepErrors[.assistiveTouch] = nil
                if env.status.snapshot.value[.assistiveTouch].health != .ok {
                    env.status.set(.assistiveTouch, .ok("Pointer visible"))
                }
                env.log.info("app", "Pointer detected at (\(Int(hit.point.x)), \(Int(hit.point.y)))")
                return true
            }
            stepErrors[.assistiveTouch] = OpenTapError(.pointerNotFound, what: "No pointer on the iPhone screen yet",
                why: "A mouse move was sent but no pointer dot appeared, so AssistiveTouch is probably off",
                fix: "On the iPhone open Settings > Accessibility > Touch > AssistiveTouch and turn it on")
        } catch {
            stepErrors[.assistiveTouch] = OpenTapError.wrap(error, what: "Couldn't check for the pointer")
        }
        return false
    }

    // MARK: - Step 6: calibration

    var isCalibrating: Bool { calibrationProgress != nil }

    func calibrate() {
        guard !isCalibrating else { return }
        stepErrors[.calibration] = nil
        calibrationProgress = CalibrationProgress(fraction: 0, message: "Starting")
        working.insert(.calibration)
        Task {
            defer { working.remove(.calibration); calibrationProgress = nil }
            do {
                let data = try await env.controller.calibrate { [weak self] p in
                    DispatchQueue.main.async { self?.calibrationProgress = p }
                }
                env.log.info("app", "Calibrated: x \(data.x.samples.count) samples, y \(data.y.samples.count) samples")
                if env.status.snapshot.value[.calibration].health != .ok {
                    env.status.set(.calibration, .ok("Calibrated just now"))
                }
            } catch {
                fail(.calibration, error, what: "Calibration failed")
            }
        }
    }

    // MARK: - Step 7: agent

    func copyMCPCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MCPDefaults.claudeAddCommand, forType: .string)
        env.log.info("app", "Copied the claude mcp add command")
    }

    func addToClaudeCode() {
        claudeInstall = .running
        Task {
            do { claudeInstall = .done(try await ClaudeInstaller.install()) } catch {
                claudeInstall = .failed(OpenTapError.wrap(error, what: "Couldn't add OpenTap to Claude Code"))
            }
        }
    }

    func testAgentConnection() {
        startMCP()
        agentTest = .running
        Task {
            do { agentTest = .passed(try await MCPSelfTest.run()) } catch {
                agentTest = .failed(OpenTapError.wrap(error, what: "The MCP test failed"))
            }
            evaluate()
        }
    }

    // MARK: - Manual control (main window)

    /// Converts a point in the full-res frame to screenshot space and taps it.
    func tap(atFramePoint p: CGPoint) {
        guard let size = frameSize else { return }
        let geo = ScreenGeometry(frameSize: size)
        let s = geo.toScreenshot(p)
        noteTap(s)
        Task {
            do {
                let r = try await env.controller.perform(.tap(x: Double(s.x), y: Double(s.y)))
                env.log.info("app", r.summary)
            } catch {
                env.log.error("app", OpenTapError.wrap(error, what: "Tap failed"))
            }
        }
    }

    func pressHome() {
        Task {
            do { _ = try await env.controller.perform(.pressKey(key: "home")) } catch {
                env.log.error("app", OpenTapError.wrap(error, what: "Home failed"))
            }
        }
    }

    // MARK: - Onboarding flow

    func isVerified(_ step: OnboardingStep) -> Bool {
        switch step {
        case .permissions: return allPermissionsGranted
        case .usb:
            if case .attached(_, .paired) = deviceState { return true }
            if deviceLinkUnavailable, case .running = frameState { return true }
            return false
        case .screen:
            if case .running = frameState { return preview != nil }
            return false
        case .bluetooth: return hidState.isConnected
        case .assistiveTouch: return pointerDetected || status[.assistiveTouch].health == .ok
        case .calibration: return status[.calibration].health == .ok && !isCalibrating
        case .agent:
            if case .passed = agentTest { return true }
            return false
        }
    }

    func error(for step: OnboardingStep) -> OpenTapError? {
        if let e = stepErrors[step] { return e }
        if step == .permissions { return Permission.allCases.lazy.compactMap { self.permissionError($0) }.first }
        if let c = step.component, let e = status[c].error { return e }
        if step == .usb, case .unavailable(let e) = deviceState { return e }
        return nil
    }

    func state(of step: OnboardingStep) -> StepState {
        if isVerified(step) { return .done }
        if skipped.contains(step) { return .skipped }
        if working.contains(step) { return .working }
        if error(for: step) != nil, step.rawValue <= currentStep.rawValue { return .failed }
        if step == currentStep { return .needsYou }
        return .pending
    }

    /// Whether "Skip for now" is offered: never for things nothing works without.
    func canSkip(_ step: OnboardingStep) -> Bool {
        switch step {
        case .permissions, .screen, .bluetooth: return false
        case .usb: return deviceLinkUnavailable || error(for: .usb) != nil
        case .assistiveTouch, .calibration, .agent: return true
        }
    }

    func skip(_ step: OnboardingStep) {
        skipped.insert(step)
        env.log.info("app", "Skipped onboarding step \(step.number) (\(step.title))")
        goToNext(after: step)
    }

    func select(_ step: OnboardingStep) {
        advanceTask?.cancel()
        currentStep = step
        enter(step)
    }

    private func goToNext(after step: OnboardingStep) {
        if let n = OnboardingStep.allCases.first(where: { $0.rawValue > step.rawValue && !isVerified($0) }) ?? step.next {
            select(n)
        } else {
            finishOnboarding()
        }
    }

    /// Side effects when a step becomes current: kick off whatever can be done automatically.
    private func enter(_ step: OnboardingStep) {
        switch step {
        case .permissions: refreshPermissions()
        case .usb:
            if case .attached(_, let trust) = deviceState, trust == .notPaired || trust == .unknown { requestTrust() }
        case .screen: startCaptureIfNeeded()
        case .bluetooth: startBluetooth()
        case .assistiveTouch:
            if !isVerified(.assistiveTouch) {
                if deviceState.device != nil, assistiveTouchAutoEnabled == nil { enableAssistiveTouchOverUSB() } else { startPointerProbe() }
            }
        case .calibration: break
        case .agent: startMCP()
        }
    }

    /// Re-checks the current step after any state change; auto-advances once it is verified.
    func evaluate() {
        guard showOnboarding, advanceTask == nil, isVerified(currentStep), currentStep != .agent else { return }
        let step = currentStep
        advanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self else { return }
            self.advanceTask = nil
            if !Task.isCancelled, self.currentStep == step, self.isVerified(step) { self.goToNext(after: step) }
        }
    }

    func beginOnboarding() {
        skipped = []
        stepErrors = [:]
        agentTest = .idle
        showOnboarding = true
        let first = OnboardingStep.allCases.first { !isVerified($0) } ?? .permissions
        select(first)
    }

    func finishOnboarding() {
        advanceTask?.cancel(); advanceTask = nil
        pointerProbe?.cancel()
        onboardingDone = true
        showOnboarding = false
        startBluetooth()
        env.log.info("app", "Onboarding finished")
    }

    /// Steps the user skipped or never verified; shown as a reminder in the main window.
    var unfinishedSteps: [OnboardingStep] { OnboardingStep.allCases.filter { !isVerified($0) && $0 != .agent } }
}
