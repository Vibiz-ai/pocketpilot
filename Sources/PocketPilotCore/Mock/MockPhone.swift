import CoreGraphics
import CoreText
import Foundation

/// Owner: qa. A simulated iPhone shared by the Mock* components.
///
/// - Renders a fake iOS screen with CoreGraphics (home screen of labelled app icons, Spotlight, a scrollable
///   Settings list, a Notes app with a text field, generic apps, a lock screen, an AssistiveTouch button and the
///   pointer dot).
/// - Receives HID reports like iOS would: relative mouse moves go through a nonlinear acceleration curve,
///   left-button down/up become taps, long presses and swipes on the mock UI, the wheel scrolls, the keyboard
///   types into the focused field, cmd+space opens Spotlight, cmd+H and consumer AC Home go home.
/// - Has fault toggles (locked, untrusted, AssistiveTouch off, no frames, ...) so every onboarding/controller
///   error path can be exercised without hardware.
///
/// Thread-safe: all state sits behind one lock; reports can arrive from any task.
public final class MockPhone: @unchecked Sendable {

    // MARK: - Public types

    /// A piece of on-screen text (what OCR would return), in screen pixels (frame space), top-left origin.
    public struct Element: Equatable, Sendable {
        public var text: String
        /// Centre of the text.
        public var center: CGPoint
        /// Tappable area (for an app icon: icon + label).
        public var frame: CGRect
        /// Text height in px; OCR boxes are derived from it.
        public var fontSize: CGFloat

        public init(text: String, center: CGPoint, frame: CGRect? = nil, fontSize: CGFloat = 40) {
            self.text = text
            self.center = center
            self.fontSize = fontSize
            let w = max(80, CGFloat(text.count) * fontSize * 0.6)
            self.frame = frame ?? CGRect(x: center.x - w / 2, y: center.y - fontSize, width: w, height: fontSize * 2)
        }

        /// Approximate box of the glyphs (what OCR reports as width/height).
        public var textBox: CGRect {
            let w = CGFloat(text.count) * fontSize * 0.55
            let h = fontSize * 1.2
            return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        }
    }

    public enum Screen: Equatable, Sendable, CustomStringConvertible {
        case home
        case spotlight
        case app(String)
        /// A row opened from the Settings list.
        case settingsDetail(String)

        public var description: String {
            switch self {
            case .home: return "home"
            case .spotlight: return "spotlight"
            case .app(let n): return "app(\(n))"
            case .settingsDetail(let n): return "settings/\(n)"
            }
        }
    }

    /// A completed touch, in frame pixels.
    public enum Gesture: Equatable, Sendable {
        case tap(CGPoint)
        case longPress(CGPoint, durationMs: Int)
        case swipe(from: CGPoint, to: CGPoint, durationMs: Int)
    }

    /// iOS-like pointer acceleration: px = linear*|u| + quadratic*|u|^2 per report of `u` HID units.
    public struct Acceleration: Equatable, Sendable {
        public var linear: Double
        public var quadratic: Double
        public init(linear: Double = 1.2, quadratic: Double = 0.012) { self.linear = linear; self.quadratic = quadratic }
        public func pixels(forUnits units: Int) -> Double {
            let u = Double(abs(units))
            let px = linear * u + quadratic * u * u
            return units < 0 ? -px : px
        }
    }

    /// Named failure scenarios (for `pocketpilot-mock --fault a,b` and tests).
    public enum Fault: String, CaseIterable, Sendable {
        case locked = "locked"
        case untrusted = "untrusted"
        case denyTrust = "deny-trust"
        case assistiveTouchOff = "at-off"
        case assistiveTouchUSBBlocked = "at-usb-blocked"
        case noUSB = "no-usb"
        case noFrames = "no-frames"
        case frozenFrames = "frozen-frames"
        case captureFails = "capture-fails"
        case noBluetooth = "no-bluetooth"
        case bluetoothOff = "bluetooth-off"
        case noMobileDevice = "no-mobiledevice"

        public var help: String {
            switch self {
            case .locked: return "iPhone screen is locked (input ignored, pairing fails with deviceLocked)"
            case .untrusted: return "iPhone attached but not trusted yet (pair() succeeds)"
            case .denyTrust: return "iPhone attached, not trusted, and the user taps \"Don't Trust\""
            case .assistiveTouchOff: return "AssistiveTouch off: no pointer, mouse reports ignored"
            case .assistiveTouchUSBBlocked: return "AssistiveTouch can't be read/toggled over USB (manual fallback)"
            case .noUSB: return "no iPhone plugged in"
            case .noFrames: return "capture device never appears (screen stays waiting)"
            case .frozenFrames: return "capture runs but frames stop arriving"
            case .captureFails: return "capture start fails with captureFailed"
            case .noBluetooth: return "the iPhone never connects over Bluetooth (stays advertising)"
            case .bluetoothOff: return "Mac Bluetooth unavailable"
            case .noMobileDevice: return "MobileDevice.framework missing (device link unavailable)"
            }
        }

        public static func parse(_ list: String) throws -> [Fault] {
            try list.split(whereSeparator: { $0 == "," || $0 == " " }).map { raw in
                let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
                guard let f = Fault(rawValue: name) else {
                    throw PocketPilotError.invalidArgument("fault",
                        why: "'\(name)' is not a mock fault",
                        fix: "Use a comma-separated list of: \(Fault.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                return f
            }
        }
    }

    /// Apps on the home screen (4 columns x 3 rows), in order.
    public static let homeApps = ["Settings", "Notes", "Safari", "Photos",
                                  "Camera", "Messages", "Mail", "Maps",
                                  "Calendar", "Clock", "Weather", "Music"]

    /// Rows of the mock Settings app (long enough to need scrolling; "Developer" is last).
    public static let settingsRows = [
        "Airplane Mode", "Wi-Fi", "Bluetooth", "Cellular", "Personal Hotspot", "Notifications", "Sounds & Haptics",
        "Focus", "Screen Time", "General", "Control Center", "Display & Brightness", "Home Screen", "Accessibility",
        "Wallpaper", "StandBy", "Siri & Search", "Face ID & Passcode", "Emergency SOS", "Battery",
        "Privacy & Security", "App Store", "Wallet", "Passwords", "Contacts", "Reminders", "Freeform",
        "Voice Memos", "Phone", "FaceTime", "News", "Translate", "Compass", "Measure", "Shortcuts", "Health",
        "Fitness", "Journal", "TV", "Books", "Podcasts", "Game Center", "Developer",
    ]

    public static let notesPlaceholder = "Tap to type"
    public static let contextMenuItems = ["Edit Home Screen", "Share App", "Remove App"]

    // MARK: - Configuration

    public let screenSize: CGSize
    public let deviceInfo: DeviceInfo
    /// Extra labels drawn on the home screen (tappable, no action besides being recorded).
    public let extraElements: [Element]
    /// Fires for every report received.
    public let reports = EventChannel<HIDReport>()
    /// Fires when an environment/fault property changes (Mock components refresh their state from it).
    public let changes = EventChannel<Void>()
    /// Injectable clock (long press vs tap). Default: wall clock.
    public var clock: () -> Date = Date.init

    // MARK: - State

    enum Field: Equatable { case spotlight, notes }

    enum Target: Equatable {
        case none, openApp(String), settingsRow(String), back, notesField, spotlightField, spotlightResult(String),
             menuItem(String), search
    }

    struct Item {
        var element: Element
        var target: Target
        var bold = false
        var color: CGColor
    }

    struct State {
        // UI
        var screen: Screen = .home
        var previousScreen: Screen = .home
        var pointer: CGPoint
        var buttons: MouseButtons = []
        var touchStart: CGPoint?
        var touchStartTime: Date?
        var touchMaxDistance: CGFloat = 0
        var pressedKeys: [UInt8] = []
        var consumerUsage: UInt16 = 0
        var focus: Field?
        var spotlightQuery = ""
        var notesDraft = ""
        var notesSaved: [String] = []
        var settingsScroll: CGFloat = 0
        var contextMenuApp: String?
        // History
        var gestures: [Gesture] = []
        var typedText = ""
        var droppedKeystrokes = 0
        var ignoredMouseReports = 0
        var lastTapped: String?
        var receivedReports: [HIDReport] = []
        // Environment / faults
        var acceleration = Acceleration()
        var isLocked = false
        var usbAttached = true
        var trust: TrustState = .paired
        var acceptsTrust = true
        var framesEnabled = true
        var framesFrozen = false
        var captureFailure: PocketPilotError?
        var bluetoothAvailable = true
        var bluetoothAccepts = true
        var hidConnected = false
        var assistiveTouchEnabled = true
        var assistiveTouchSettableOverUSB = true
        var mobileDeviceAvailable = true
    }

    private let lock = NSRecursiveLock()
    private var s: State
    private var version = 0
    private var cachedImage: CGImage?
    private var cachedVersion = -1

    public init(screenSize: CGSize = CGSize(width: 1206, height: 2622),
                deviceInfo: DeviceInfo = DeviceInfo(udid: "00008140-000MOCK0000PHONE", name: "Mock iPhone",
                                                    model: "iPhone", productType: "iPhone17,1", iosVersion: "18.1"),
                elements: [Element] = []) {
        self.screenSize = screenSize
        self.deviceInfo = deviceInfo
        self.extraElements = elements
        self.s = State(pointer: CGPoint(x: screenSize.width / 2, y: screenSize.height / 2))
    }

    // MARK: - Locked accessors

    private func read<T>(_ kp: KeyPath<State, T>) -> T { lock.lock(); defer { lock.unlock() }; return s[keyPath: kp] }

    /// Sets an environment/fault property and notifies `changes`.
    private func write<T>(_ kp: WritableKeyPath<State, T>, _ v: T) {
        lock.lock(); s[keyPath: kp] = v; version += 1; lock.unlock()
        changes.send(())
    }

    @discardableResult
    private func mutate<R>(_ body: (inout State) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        let r = body(&s); version += 1
        return r
    }

    // UI state (read-only from outside)
    public var screen: Screen { read(\.screen) }
    public var pointer: CGPoint { read(\.pointer) }
    public var gestures: [Gesture] { read(\.gestures) }
    public var typedText: String { read(\.typedText) }
    public var notesDraft: String { read(\.notesDraft) }
    public var notesSaved: [String] { read(\.notesSaved) }
    public var spotlightQuery: String { read(\.spotlightQuery) }
    public var settingsScroll: CGFloat { read(\.settingsScroll) }
    public var contextMenuApp: String? { read(\.contextMenuApp) }
    public var droppedKeystrokes: Int { read(\.droppedKeystrokes) }
    public var ignoredMouseReports: Int { read(\.ignoredMouseReports) }
    /// Text of the last element a tap landed on.
    public var lastTapped: String? { read(\.lastTapped) }
    public var receivedReports: [HIDReport] { read(\.receivedReports) }
    public var isTextFieldFocused: Bool { read(\.focus) != nil }

    // Environment / fault toggles
    public var acceleration: Acceleration { get { read(\.acceleration) } set { write(\.acceleration, newValue) } }
    /// Screen locked: all input ignored, lock screen shown, pairing throws deviceLocked.
    public var isLocked: Bool { get { read(\.isLocked) } set { write(\.isLocked, newValue) } }
    public var usbAttached: Bool { get { read(\.usbAttached) } set { write(\.usbAttached, newValue) } }
    /// Lockdown trust state as seen over USB.
    public var trust: TrustState { get { read(\.trust) } set { write(\.trust, newValue) } }
    /// What the user answers to "Trust This Computer?" when `pair()` is called.
    public var acceptsTrust: Bool { get { read(\.acceptsTrust) } set { write(\.acceptsTrust, newValue) } }
    public var framesEnabled: Bool { get { read(\.framesEnabled) } set { write(\.framesEnabled, newValue) } }
    public var framesFrozen: Bool { get { read(\.framesFrozen) } set { write(\.framesFrozen, newValue) } }
    public var captureFailure: PocketPilotError? { get { read(\.captureFailure) } set { write(\.captureFailure, newValue) } }
    public var bluetoothAvailable: Bool { get { read(\.bluetoothAvailable) } set { write(\.bluetoothAvailable, newValue) } }
    /// Whether the iPhone connects to the advertised HID service.
    public var bluetoothAccepts: Bool { get { read(\.bluetoothAccepts) } set { write(\.bluetoothAccepts, newValue) } }
    /// Set by MockHIDTransport; the pointer is only drawn while connected.
    public var hidConnected: Bool { get { read(\.hidConnected) } set { write(\.hidConnected, newValue) } }
    public var assistiveTouchEnabled: Bool { get { read(\.assistiveTouchEnabled) } set { write(\.assistiveTouchEnabled, newValue) } }
    public var assistiveTouchSettableOverUSB: Bool {
        get { read(\.assistiveTouchSettableOverUSB) } set { write(\.assistiveTouchSettableOverUSB, newValue) }
    }
    public var mobileDeviceAvailable: Bool { get { read(\.mobileDeviceAvailable) } set { write(\.mobileDeviceAvailable, newValue) } }

    public func apply(_ faults: [Fault]) {
        lock.lock()
        for f in faults {
            switch f {
            case .locked: s.isLocked = true
            case .untrusted: s.trust = .notPaired
            case .denyTrust: s.trust = .notPaired; s.acceptsTrust = false
            case .assistiveTouchOff: s.assistiveTouchEnabled = false
            case .assistiveTouchUSBBlocked: s.assistiveTouchSettableOverUSB = false
            case .noUSB: s.usbAttached = false
            case .noFrames: s.framesEnabled = false
            case .frozenFrames: s.framesFrozen = true
            case .captureFails:
                s.captureFailure = PocketPilotError(.captureFailed, what: "Couldn't start the iPhone screen capture",
                                                why: "The capture session failed to start (simulated by pocketpilot-mock)",
                                                fix: "Unplug and replug the iPhone, unlock it, then press Retry")
            case .noBluetooth: s.bluetoothAccepts = false
            case .bluetoothOff: s.bluetoothAvailable = false
            case .noMobileDevice: s.mobileDeviceAvailable = false
            }
        }
        version += 1
        lock.unlock()
        changes.send(())
    }

    /// Test hook: puts the pointer somewhere directly (frame px, clamped).
    public func setPointer(_ p: CGPoint) { mutate { $0.pointer = clamp(p) } }

    /// Test hook: jump to a screen.
    public func show(_ screen: Screen) {
        mutate { st in
            st.screen = screen; st.contextMenuApp = nil
            st.focus = screen == .spotlight ? .spotlight : nil
        }
    }

    // MARK: - Acceleration / calibration ground truth

    /// Frame pixels moved by one report of `units` HID units.
    public func pixels(forUnits units: Int) -> Double { read(\.acceleration).pixels(forUnits: units) }

    /// The exact curve this phone uses, expressed in screenshot space (what a perfect calibration would measure).
    public func groundTruthCalibration(screenshotWidth: Double = ScreenGeometry.defaultScreenshotWidth,
                                       steps: [Int] = [1, 2, 4, 8, 16, 32, 64, 127]) -> CalibrationData {
        let geo = ScreenGeometry(frameSize: screenSize, screenshotWidth: screenshotWidth)
        let curve = AxisCurve(samples: steps.map { CurveSample(step: $0, pixelsPerStep: pixels(forUnits: $0) * geo.scale) })
        return CalibrationData(deviceUDID: deviceInfo.udid, screenshotSize: geo.screenshotSize, park: .topLeft,
                               x: curve, y: curve)
    }

    // MARK: - HID input

    public func receive(_ report: HIDReport) {
        lock.lock()
        s.receivedReports.append(report)
        switch report {
        case .mouse(let r): handleMouse(r)
        case .keyboard(let r): handleKeyboard(r)
        case .consumer(let r): handleConsumer(r)
        }
        version += 1
        lock.unlock()
        reports.send(report)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), screenSize.width - 1), y: min(max(p.y, 0), screenSize.height - 1))
    }

    private func handleMouse(_ r: MouseReport) {
        guard s.assistiveTouchEnabled else { s.ignoredMouseReports += 1; return }
        let dx = s.acceleration.pixels(forUnits: Int(r.dx)), dy = s.acceleration.pixels(forUnits: Int(r.dy))
        s.pointer = clamp(CGPoint(x: s.pointer.x + dx, y: s.pointer.y + dy))
        if let start = s.touchStart {
            s.touchMaxDistance = max(s.touchMaxDistance, hypot(s.pointer.x - start.x, s.pointer.y - start.y))
        }
        if r.wheel != 0 { scrollWheel(Int(r.wheel)) }
        let wasDown = s.buttons.contains(.left), isDown = r.buttons.contains(.left)
        s.buttons = r.buttons
        if !wasDown && isDown {
            s.touchStart = s.pointer; s.touchStartTime = clock(); s.touchMaxDistance = 0
        } else if wasDown && !isDown {
            finishTouch()
        }
    }

    private func finishTouch() {
        guard let start = s.touchStart else { return }
        let end = s.pointer
        let ms = Int((((s.touchStartTime.map { clock().timeIntervalSince($0) }) ?? 0) * 1000).rounded())
        let maxDist = s.touchMaxDistance
        s.touchStart = nil; s.touchStartTime = nil; s.touchMaxDistance = 0
        let k = screenSize.width / 1206
        if maxDist < 20 * k {
            if ms >= 500 {
                s.gestures.append(.longPress(start, durationMs: ms))
                guard !s.isLocked else { return }
                longPress(at: start)
            } else {
                s.gestures.append(.tap(start))
                guard !s.isLocked else { return }
                tap(at: start)
            }
        } else {
            s.gestures.append(.swipe(from: start, to: end, durationMs: ms))
            guard !s.isLocked else { return }
            swipe(from: start, to: end)
        }
    }

    private func handleKeyboard(_ r: KeyboardReport) {
        let now = r.keys.filter { $0 != 0 }
        let new = now.filter { !s.pressedKeys.contains($0) }
        s.pressedKeys = now
        for k in new { keyDown(k, r.modifiers) }
    }

    private func handleConsumer(_ r: ConsumerReport) {
        let prev = s.consumerUsage
        s.consumerUsage = r.usage
        guard r.usage != 0, r.usage != prev, !s.isLocked else { return }
        if r.usage == ConsumerUsage.acHome { goHome() }
    }

    private static let reverseLayout: [KeyStroke: Character] = {
        var t: [KeyStroke: Character] = [:]
        for v in 32...126 {
            let c = Character(UnicodeScalar(UInt8(v)))
            if let st = USKeyboardLayout.stroke(for: c) { t[st] = c }
        }
        return t
    }()

    private func keyDown(_ usage: UInt8, _ mods: KeyModifiers) {
        guard !s.isLocked else { s.droppedKeystrokes += 1; return }
        if mods.contains(.command) {
            if usage == KeyUsage.space { openSpotlight() }
            else if usage == KeyUsage.a + 7 /* h */ { goHome() }
            return
        }
        switch usage {
        case KeyUsage.returnKey: submit()
        case KeyUsage.backspace:
            switch s.focus {
            case .spotlight: if !s.spotlightQuery.isEmpty { s.spotlightQuery.removeLast() }
            case .notes: if !s.notesDraft.isEmpty { s.notesDraft.removeLast() }
            case nil: s.droppedKeystrokes += 1
            }
        case KeyUsage.escape:
            if s.screen == .spotlight { s.screen = s.previousScreen; s.focus = nil; s.spotlightQuery = "" }
            s.contextMenuApp = nil
        case KeyUsage.tab, KeyUsage.up, KeyUsage.down, KeyUsage.left, KeyUsage.right, KeyUsage.forwardDelete:
            break
        default:
            guard let c = Self.reverseLayout[KeyStroke(usage, mods.intersection(.shift))] else {
                s.droppedKeystrokes += 1; return
            }
            s.typedText.append(c)
            switch s.focus {
            case .spotlight: s.spotlightQuery.append(c)
            case .notes: s.notesDraft.append(c)
            case nil: s.droppedKeystrokes += 1
            }
        }
    }

    // MARK: - UI behaviour

    private func goHome() {
        s.screen = .home; s.focus = nil; s.contextMenuApp = nil; s.spotlightQuery = ""
    }

    private func openSpotlight() {
        if s.screen != .spotlight { s.previousScreen = s.screen }
        s.screen = .spotlight; s.focus = .spotlight; s.spotlightQuery = ""; s.contextMenuApp = nil
    }

    private func openApp(_ name: String) {
        s.screen = .app(name); s.focus = nil; s.contextMenuApp = nil; s.spotlightQuery = ""
        if name == "Settings" { s.settingsScroll = 0 }
    }

    func spotlightResults(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Array(Self.homeApps.prefix(4)) }
        let prefix = Self.homeApps.filter { $0.lowercased().hasPrefix(q) }
        let contains = Self.homeApps.filter { !$0.lowercased().hasPrefix(q) && $0.lowercased().contains(q) }
        return Array((prefix + contains).prefix(5))
    }

    private func submit() {
        switch s.focus {
        case .spotlight:
            if !s.spotlightQuery.isEmpty, let first = spotlightResults(s.spotlightQuery).first { openApp(first) }
        case .notes:
            if !s.notesDraft.isEmpty { s.notesSaved.append(s.notesDraft); s.notesDraft = "" }
        case nil:
            s.droppedKeystrokes += 1
        }
    }

    private func hit(_ p: CGPoint) -> Item? {
        layout(s).reversed().first { $0.target != .none && $0.element.frame.contains(p) }
    }

    private func tap(at p: CGPoint) {
        guard let item = hit(p) else {
            s.lastTapped = nil
            s.contextMenuApp = nil
            return
        }
        s.lastTapped = item.element.text
        switch item.target {
        case .none: break
        case .openApp(let n): openApp(n)
        case .settingsRow(let n): s.screen = .settingsDetail(n)
        case .back: s.screen = .app("Settings")
        case .notesField: s.focus = .notes
        case .spotlightField: s.focus = .spotlight
        case .spotlightResult(let n): openApp(n)
        case .menuItem: s.contextMenuApp = nil
        case .search: openSpotlight()
        }
    }

    private func longPress(at p: CGPoint) {
        guard s.screen == .home, s.contextMenuApp == nil, let item = hit(p), case .openApp(let name) = item.target else { return }
        s.lastTapped = item.element.text
        s.contextMenuApp = name
    }

    private func swipe(from a: CGPoint, to b: CGPoint) {
        let k = screenSize.width / 1206
        let dx = b.x - a.x, dy = b.y - a.y
        if a.y > screenSize.height - 80 * k && dy < -150 * k { goHome(); return }
        if a.x < 50 * k && dx > 150 * k {
            if case .settingsDetail = s.screen { s.screen = .app("Settings") }
            return
        }
        switch s.screen {
        case .app("Settings"): s.settingsScroll = min(max(0, s.settingsScroll - dy), maxSettingsScroll)
        case .home where s.contextMenuApp == nil && dy > 150 * k && abs(dx) < dy && a.y > 200 * k: openSpotlight()
        default: break
        }
    }

    private func scrollWheel(_ wheel: Int) {
        guard s.screen == .app("Settings"), !s.isLocked else { return }
        let k = screenSize.width / 1206
        // HID convention: positive wheel = scroll up (towards the top of the content).
        s.settingsScroll = min(max(0, s.settingsScroll - CGFloat(wheel) * 60 * k), maxSettingsScroll)
    }

    var maxSettingsScroll: CGFloat {
        let k = screenSize.width / 1206
        return max(0, 400 * k + CGFloat(Self.settingsRows.count) * 132 * k + 40 * k - screenSize.height)
    }

    // MARK: - Layout (what is on screen, where)

    /// Every visible piece of text right now (frame px). This is what MockTextRecognizer returns.
    public var elements: [Element] {
        lock.lock(); defer { lock.unlock() }
        return layout(s).map(\.element)
    }

    private static let white = CGColor(gray: 1, alpha: 1)
    private static let black = CGColor(gray: 0.05, alpha: 1)
    private static let gray = CGColor(gray: 0.5, alpha: 1)
    private static let blue = CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1)

    func homeIconRect(_ index: Int) -> CGRect {
        let k = screenSize.width / 1206
        let col = index % 4, row = index / 4
        let cx = screenSize.width * CGFloat(2 * col + 1) / 8
        let size = 192 * k
        return CGRect(x: cx - size / 2, y: 300 * k + CGFloat(row) * 340 * k, width: size, height: size)
    }

    func layout(_ st: State) -> [Item] {
        let k = screenSize.width / 1206
        let W = screenSize.width, H = screenSize.height
        var items: [Item] = []

        func centered(_ text: String, _ c: CGPoint, _ size: CGFloat, _ target: Target = .none, bold: Bool = false,
                      color: CGColor = MockPhone.white, frame: CGRect? = nil) {
            items.append(Item(element: Element(text: text, center: c, frame: frame, fontSize: size), target: target,
                              bold: bold, color: color))
        }
        func left(_ text: String, x: CGFloat, y: CGFloat, _ size: CGFloat, _ target: Target = .none, bold: Bool = false,
                  color: CGColor = MockPhone.black, frame: CGRect? = nil) {
            let w = MockPhone.textWidth(text, size: size, bold: bold)
            centered(text, CGPoint(x: x + w / 2, y: y), size, target, bold: bold, color: color, frame: frame)
        }

        if st.isLocked {
            centered("9:41", CGPoint(x: W / 2, y: 470 * k), 230 * k, bold: true)
            centered("Sunday, November 8", CGPoint(x: W / 2, y: 250 * k), 52 * k)
            centered("Swipe up to open", CGPoint(x: W / 2, y: H - 200 * k), 40 * k)
            return items
        }

        let statusColor: CGColor
        switch st.screen {
        case .home, .spotlight: statusColor = MockPhone.white
        default: statusColor = MockPhone.black
        }

        switch st.screen {
        case .home:
            for (i, name) in Self.homeApps.enumerated() {
                let icon = homeIconRect(i)
                let labelY = icon.maxY + 50 * k
                let frame = CGRect(x: icon.minX - 20 * k, y: icon.minY - 10 * k, width: icon.width + 40 * k,
                                   height: icon.height + 100 * k)
                centered(name, CGPoint(x: icon.midX, y: labelY), 38 * k, .openApp(name), frame: frame)
            }
            for e in extraElements {
                items.append(Item(element: e, target: .menuItem(e.text), color: MockPhone.white))
            }
            centered("Search", CGPoint(x: W / 2, y: H - 300 * k), 38 * k, .search,
                     frame: CGRect(x: W / 2 - 130 * k, y: H - 345 * k, width: 260 * k, height: 90 * k))
            if let app = st.contextMenuApp, let idx = Self.homeApps.firstIndex(of: app) {
                let icon = homeIconRect(idx)
                let menuX = min(max(40 * k, icon.minX), W - 640 * k)
                let top = icon.maxY + 130 * k
                for (j, label) in Self.contextMenuItems.enumerated() {
                    let rowY = top + CGFloat(j) * 120 * k
                    left(label, x: menuX + 50 * k, y: rowY + 60 * k, 44 * k, .menuItem(label),
                         color: j == 2 ? CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1) : MockPhone.black,
                         frame: CGRect(x: menuX, y: rowY, width: 600 * k, height: 120 * k))
                }
            }

        case .spotlight:
            let fieldText = st.spotlightQuery.isEmpty ? "Search" : st.spotlightQuery
            left(fieldText, x: 150 * k, y: 240 * k, 50 * k, .spotlightField,
                 color: st.spotlightQuery.isEmpty ? CGColor(gray: 0.75, alpha: 1) : MockPhone.white,
                 frame: CGRect(x: 60 * k, y: 180 * k, width: W - 120 * k, height: 120 * k))
            left(st.spotlightQuery.isEmpty ? "Siri Suggestions" : "Top Hits", x: 70 * k, y: 380 * k, 40 * k,
                 bold: true, color: CGColor(gray: 0.8, alpha: 1))
            for (j, name) in spotlightResults(st.spotlightQuery).enumerated() {
                let rowY = 440 * k + CGFloat(j) * 150 * k
                left(name, x: 260 * k, y: rowY + 75 * k, 48 * k, .spotlightResult(name), color: MockPhone.white,
                     frame: CGRect(x: 40 * k, y: rowY, width: W - 80 * k, height: 150 * k))
            }

        case .app("Settings"):
            let off = st.settingsScroll
            let minY = 150 * k
            let titleY = 270 * k - off
            if titleY > minY { left("Settings", x: 60 * k, y: titleY, 90 * k, bold: true) }
            for (i, row) in Self.settingsRows.enumerated() {
                let rowTop = 400 * k + CGFloat(i) * 132 * k - off
                let cy = rowTop + 66 * k
                guard cy - 30 * k > minY, cy + 30 * k < H else { continue }
                left(row, x: 180 * k, y: cy, 46 * k, .settingsRow(row),
                     frame: CGRect(x: 40 * k, y: rowTop, width: W - 80 * k, height: 132 * k))
            }

        case .settingsDetail(let name):
            left("< Settings", x: 50 * k, y: 200 * k, 46 * k, .back, color: MockPhone.blue,
                 frame: CGRect(x: 20 * k, y: 140 * k, width: 400 * k, height: 120 * k))
            left(name, x: 60 * k, y: 340 * k, 80 * k, bold: true)
            left("\(name) settings", x: 60 * k, y: 520 * k, 46 * k, color: CGColor(gray: 0.35, alpha: 1))

        case .app("Notes"):
            left("Notes", x: 70 * k, y: 260 * k, 90 * k, bold: true)
            let draft = st.notesDraft
            left(draft.isEmpty ? Self.notesPlaceholder : draft, x: 100 * k, y: 455 * k, 48 * k, .notesField,
                 color: draft.isEmpty ? MockPhone.gray : MockPhone.black,
                 frame: CGRect(x: 60 * k, y: 380 * k, width: W - 120 * k, height: 150 * k))
            for (j, note) in st.notesSaved.enumerated() {
                left(note, x: 80 * k, y: 640 * k + CGFloat(j) * 110 * k, 44 * k)
            }

        case .app(let name):
            centered(name, CGPoint(x: W / 2, y: 280 * k), 90 * k, bold: true, color: MockPhone.black)
            centered("\(name) is open", CGPoint(x: W / 2, y: H / 2), 52 * k, color: CGColor(gray: 0.35, alpha: 1))
        }

        // Status bar clock goes first in reading order.
        items.insert(Item(element: Element(text: "9:41", center: CGPoint(x: 180 * k, y: 75 * k), fontSize: 44 * k),
                          target: .none, bold: true, color: statusColor), at: 0)
        return items
    }

    // MARK: - Rendering

    /// The current screen as a full-resolution frame (sRGB, top-left origin when displayed). Cached per state change.
    public func render() -> CGImage? {
        lock.lock()
        if cachedVersion == version, let img = cachedImage { lock.unlock(); return img }
        let snapshot = s, v = version
        lock.unlock()
        let img = draw(snapshot)
        lock.lock()
        if v >= cachedVersion { cachedImage = img; cachedVersion = v }
        lock.unlock()
        return img
    }

    static func font(size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    }

    static func line(_ text: String, size: CGFloat, bold: Bool, color: CGColor) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, bold: bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    static func textWidth(_ text: String, size: CGFloat, bold: Bool) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, size: size, bold: bold, color: white), nil, nil, nil))
    }

    private static let iconColors: [CGColor] = [
        CGColor(red: 0.55, green: 0.56, blue: 0.60, alpha: 1), CGColor(red: 0.98, green: 0.80, blue: 0.20, alpha: 1),
        CGColor(red: 0.10, green: 0.55, blue: 0.95, alpha: 1), CGColor(red: 0.95, green: 0.45, blue: 0.30, alpha: 1),
        CGColor(red: 0.30, green: 0.30, blue: 0.33, alpha: 1), CGColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        CGColor(red: 0.15, green: 0.45, blue: 0.95, alpha: 1), CGColor(red: 0.35, green: 0.75, blue: 0.55, alpha: 1),
        CGColor(red: 0.98, green: 0.30, blue: 0.25, alpha: 1), CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1),
        CGColor(red: 0.25, green: 0.60, blue: 0.95, alpha: 1), CGColor(red: 0.98, green: 0.25, blue: 0.40, alpha: 1),
    ]

    private func draw(_ st: State) -> CGImage? {
        let W = Int(screenSize.width), H = Int(screenSize.height)
        let Hf = screenSize.height
        let k = screenSize.width / 1206
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.textMatrix = .identity

        // Top-left-origin helpers (the context itself is bottom-left).
        func cg(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: Hf - r.maxY, width: r.width, height: r.height) }
        func fill(_ r: CGRect, _ color: CGColor, radius: CGFloat = 0) {
            ctx.setFillColor(color)
            let rr = min(radius, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: cg(r), cornerWidth: rr, cornerHeight: rr, transform: nil))
            ctx.fillPath()
        }
        func circle(_ c: CGPoint, _ r: CGFloat, fill color: CGColor, stroke: CGColor? = nil, lineWidth: CGFloat = 0) {
            let rect = cg(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.setFillColor(color); ctx.fillEllipse(in: rect)
            if let stroke { ctx.setStrokeColor(stroke); ctx.setLineWidth(lineWidth); ctx.strokeEllipse(in: rect) }
        }
        func gradient(_ top: CGColor, _ bottom: CGColor) {
            if let g = CGGradient(colorsSpace: space, colors: [bottom, top] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: Hf), options: [])
            }
        }
        func text(_ item: Item) {
            let e = item.element
            let l = MockPhone.line(e.text, size: e.fontSize, bold: item.bold, color: item.color)
            var a: CGFloat = 0, d: CGFloat = 0, lead: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(l, &a, &d, &lead))
            ctx.textPosition = CGPoint(x: e.center.x - w / 2, y: Hf - (e.center.y + (a - d) / 2))
            CTLineDraw(l, ctx)
        }

        let wallTop = CGColor(red: 0.16, green: 0.30, blue: 0.70, alpha: 1)
        let wallBottom = CGColor(red: 0.52, green: 0.24, blue: 0.62, alpha: 1)
        let items = layout(st)
        let darkUI: Bool = {
            guard !st.isLocked else { return false }
            switch st.screen { case .app, .settingsDetail: return true; default: return false }
        }()

        if st.isLocked {
            gradient(CGColor(red: 0.05, green: 0.08, blue: 0.20, alpha: 1), CGColor(red: 0.20, green: 0.10, blue: 0.30, alpha: 1))
        } else {
            switch st.screen {
            case .home:
                gradient(wallTop, wallBottom)
                for i in Self.homeApps.indices {
                    let r = homeIconRect(i)
                    fill(r, Self.iconColors[i % Self.iconColors.count], radius: 44 * k)
                    fill(r.insetBy(dx: 50 * k, dy: 50 * k), CGColor(gray: 1, alpha: 0.35), radius: 20 * k)
                }
                fill(CGRect(x: screenSize.width / 2 - 130 * k, y: Hf - 345 * k, width: 260 * k, height: 90 * k),
                     CGColor(gray: 1, alpha: 0.25), radius: 45 * k)
                if let app = st.contextMenuApp, let idx = Self.homeApps.firstIndex(of: app) {
                    fill(CGRect(origin: .zero, size: screenSize), CGColor(gray: 0, alpha: 0.35))
                    let icon = homeIconRect(idx)
                    fill(icon, Self.iconColors[idx % Self.iconColors.count], radius: 44 * k)
                    let menuX = min(max(40 * k, icon.minX), screenSize.width - 640 * k)
                    fill(CGRect(x: menuX, y: icon.maxY + 130 * k, width: 600 * k, height: 360 * k),
                         CGColor(gray: 0.96, alpha: 1), radius: 36 * k)
                }
            case .spotlight:
                gradient(CGColor(red: 0.08, green: 0.12, blue: 0.28, alpha: 1), CGColor(red: 0.22, green: 0.10, blue: 0.28, alpha: 1))
                fill(CGRect(x: 60 * k, y: 180 * k, width: screenSize.width - 120 * k, height: 120 * k),
                     CGColor(gray: 1, alpha: 0.18), radius: 40 * k)
                if st.focus == .spotlight {
                    let qw = st.spotlightQuery.isEmpty ? 0 : MockPhone.textWidth(st.spotlightQuery, size: 50 * k, bold: false)
                    fill(CGRect(x: 150 * k + qw + 4 * k, y: 205 * k, width: 5 * k, height: 70 * k), MockPhone.blue)
                }
                for (j, name) in spotlightResults(st.spotlightQuery).enumerated() {
                    let idx = Self.homeApps.firstIndex(of: name) ?? j
                    fill(CGRect(x: 100 * k, y: 440 * k + CGFloat(j) * 150 * k + 20 * k, width: 110 * k, height: 110 * k),
                         Self.iconColors[idx % Self.iconColors.count], radius: 26 * k)
                }
            case .app("Settings"):
                fill(CGRect(origin: .zero, size: screenSize), CGColor(gray: 0.95, alpha: 1))
                for i in Self.settingsRows.indices {
                    let top = 400 * k + CGFloat(i) * 132 * k - st.settingsScroll
                    guard top + 132 * k > 150 * k, top < Hf else { continue }
                    fill(CGRect(x: 40 * k, y: top, width: screenSize.width - 80 * k, height: 130 * k), MockPhone.white)
                    fill(CGRect(x: 70 * k, y: top + 26 * k, width: 80 * k, height: 80 * k),
                         Self.iconColors[i % Self.iconColors.count], radius: 18 * k)
                }
                fill(CGRect(x: 0, y: 0, width: screenSize.width, height: 150 * k), CGColor(gray: 0.95, alpha: 1))
            case .settingsDetail:
                fill(CGRect(origin: .zero, size: screenSize), CGColor(gray: 0.95, alpha: 1))
            case .app("Notes"):
                fill(CGRect(origin: .zero, size: screenSize), CGColor(red: 1, green: 0.98, blue: 0.90, alpha: 1))
                let field = CGRect(x: 60 * k, y: 380 * k, width: screenSize.width - 120 * k, height: 150 * k)
                fill(field, st.focus == .notes ? MockPhone.blue : CGColor(gray: 0.8, alpha: 1), radius: 24 * k)
                fill(field.insetBy(dx: 5 * k, dy: 5 * k), MockPhone.white, radius: 20 * k)
                if st.focus == .notes {
                    let w = st.notesDraft.isEmpty ? 0 : MockPhone.textWidth(st.notesDraft, size: 48 * k, bold: false)
                    fill(CGRect(x: 100 * k + w + 4 * k, y: 420 * k, width: 5 * k, height: 70 * k), MockPhone.blue)
                }
            case .app:
                fill(CGRect(origin: .zero, size: screenSize), MockPhone.white)
            }
        }
        // Home indicator + battery glyph.
        let chrome = darkUI ? MockPhone.black : MockPhone.white
        fill(CGRect(x: screenSize.width / 2 - 200 * k, y: Hf - 40 * k, width: 400 * k, height: 14 * k), chrome, radius: 7 * k)
        fill(CGRect(x: screenSize.width - 200 * k, y: 58 * k, width: 90 * k, height: 40 * k), chrome, radius: 10 * k)

        for item in items { text(item) }

        // AssistiveTouch floating button.
        if st.assistiveTouchEnabled {
            let c = assistiveTouchButtonCenter
            fill(CGRect(x: c.x - 85 * k, y: c.y - 85 * k, width: 170 * k, height: 170 * k), CGColor(gray: 0.08, alpha: 0.6), radius: 40 * k)
            circle(c, 62 * k, fill: CGColor(gray: 1, alpha: 0.22))
            circle(c, 47 * k, fill: CGColor(gray: 1, alpha: 0.45))
            circle(c, 32 * k, fill: CGColor(gray: 1, alpha: 0.9))
        }
        // The pointer dot (only with AssistiveTouch on and a HID mouse connected).
        // Like iOS, its shade adapts to what is underneath: dark grey on light UI, light grey on dark UI.
        if st.assistiveTouchEnabled && st.hidConnected {
            if darkUI {
                circle(st.pointer, pointerRadius, fill: CGColor(gray: 0.32, alpha: 0.85),
                       stroke: CGColor(gray: 1, alpha: 0.55), lineWidth: 3 * k)
            } else {
                circle(st.pointer, pointerRadius, fill: CGColor(gray: 0.82, alpha: 0.85),
                       stroke: CGColor(gray: 0.2, alpha: 0.35), lineWidth: 3 * k)
            }
        }
        return ctx.makeImage()
    }

    /// Radius of the drawn pointer dot, frame px.
    public var pointerRadius: CGFloat { 28 * screenSize.width / 1206 }

    /// Centre of the AssistiveTouch floating button, frame px.
    public var assistiveTouchButtonCenter: CGPoint {
        CGPoint(x: screenSize.width - 110 * screenSize.width / 1206, y: screenSize.height * 0.62)
    }
}
