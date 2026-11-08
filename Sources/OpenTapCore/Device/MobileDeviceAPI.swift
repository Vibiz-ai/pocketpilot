import CoreFoundation
import Foundation

/// Opaque `am_device*` handle. Stored as bits so fakes can mint handles without real pointers.
public struct MDDevice: Hashable, Sendable {
    public let bits: UInt
    public init(bits: UInt) { self.bits = bits }
    init(_ pointer: UnsafeMutableRawPointer) { bits = UInt(bitPattern: pointer) }
    var pointer: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: bits) }
}

public enum MDDeviceEvent: Equatable, Sendable {
    case attached(MDDevice)
    case detached(MDDevice)
}

/// Which optional parts of MobileDevice were found. Missing ones degrade to manual steps.
public struct MobileDeviceCapabilities: Equatable, Sendable {
    public var canPair: Bool
    public var canSetValues: Bool
    public var canFilterInterface: Bool
    public init(canPair: Bool = true, canSetValues: Bool = true, canFilterInterface: Bool = true) {
        self.canPair = canPair; self.canSetValues = canSetValues; self.canFilterInterface = canFilterInterface
    }
}

/// Thin Swift face of the AMDevice C API. Implemented by `DlopenMobileDeviceAPI` and by test fakes.
/// Calls are synchronous and may block; `MobileDeviceLink` serializes them on its own queue.
public protocol MobileDeviceAPI: AnyObject {
    var capabilities: MobileDeviceCapabilities { get }
    /// Starts attach/detach notifications. `handler` is called on a dedicated run-loop thread.
    /// Devices passed to `handler` are only valid during the call: `retain` them to keep them.
    func subscribe(_ handler: @escaping (MDDeviceEvent) -> Void) throws
    func unsubscribe()
    func retain(_ device: MDDevice)
    func release(_ device: MDDevice)
    func identifier(_ device: MDDevice) -> String?
    /// 1 = USB, 2 = Wi-Fi; nil if unknown.
    func interfaceType(_ device: MDDevice) -> Int?
    func connect(_ device: MDDevice) -> Int32
    func disconnect(_ device: MDDevice) -> Int32
    func isPaired(_ device: MDDevice) -> Bool
    func validatePairing(_ device: MDDevice) -> Int32
    func pair(_ device: MDDevice) -> Int32
    func startSession(_ device: MDDevice) -> Int32
    func stopSession(_ device: MDDevice) -> Int32
    func copyValue(_ device: MDDevice, domain: String?, key: String) -> Any?
    func setValue(_ device: MDDevice, domain: String?, key: String, value: Any) -> Int32
}

/// Loads MobileDevice.framework and resolves the AMDevice* symbols, failing soft with manual steps.
public enum MobileDeviceFramework {
    public static let path = "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"

    /// Symbols without which device detection can't work at all.
    public static let requiredSymbols = [
        "AMDeviceNotificationSubscribe", "AMDeviceCopyDeviceIdentifier", "AMDeviceConnect", "AMDeviceDisconnect",
        "AMDeviceIsPaired", "AMDeviceValidatePairing", "AMDeviceStartSession", "AMDeviceStopSession",
        "AMDeviceCopyValue", "AMDeviceRetain", "AMDeviceRelease",
    ]
    /// Symbols whose absence only disables one feature.
    public static let optionalSymbols = [
        "AMDevicePair", "AMDeviceSetValue", "AMDeviceNotificationUnsubscribe", "AMDeviceGetInterfaceType",
    ]

    static let manualFallback = "Pair manually: \(ManualSteps.trust). Then turn on AssistiveTouch by hand: \(ManualSteps.assistiveTouch)"

    public static func load(loader: DynamicLibraryLoader = DlopenLoader(), path: String = MobileDeviceFramework.path)
        -> Result<MobileDeviceAPI, OpenTapError>
    {
        guard let lib = loader.open(path) else {
            let reason = loader.lastError.map { " (\($0))" } ?? ""
            return .failure(OpenTapError(
                .frameworkUnavailable, what: "Couldn't load Apple's MobileDevice framework",
                why: "This Mac can't load \(path)\(reason), so OpenTap can't detect the iPhone over USB or toggle AssistiveTouch",
                fix: manualFallback + ". Installing Xcode or updating macOS restores the framework."))
        }
        var symbols: [String: UnsafeMutableRawPointer] = [:]
        var missing: [String] = []
        for name in requiredSymbols {
            if let s = loader.symbol(name, in: lib) { symbols[name] = s } else { missing.append(name) }
        }
        guard missing.isEmpty else {
            return .failure(OpenTapError(
                .frameworkUnavailable, what: "MobileDevice framework is missing functions OpenTap needs",
                why: "This macOS version doesn't export \(missing.joined(separator: ", "))",
                fix: manualFallback))
        }
        for name in optionalSymbols {
            if let s = loader.symbol(name, in: lib) { symbols[name] = s }
        }
        return .success(DlopenMobileDeviceAPI(symbols: symbols))
    }
}

// MARK: - Real implementation over dlsym'd function pointers

private typealias NotificationCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
private typealias FnSubscribe = @convention(c) (
    NotificationCallback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>
) -> Int32
private typealias FnPtrToInt = @convention(c) (UnsafeMutableRawPointer?) -> Int32
private typealias FnPtrToVoid = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias FnCopyString = @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFString>?
private typealias FnCopyValue = @convention(c) (UnsafeMutableRawPointer?, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
private typealias FnSetValue = @convention(c) (UnsafeMutableRawPointer?, CFString?, CFString?, CFTypeRef?) -> Int32

/// am_device_notification_callback_info: { am_device *dev; unsigned int msg; am_device_notification *subscription; }
private enum NotificationMessage: UInt32 { case connected = 1, disconnected = 2, unsubscribed = 3 }

public final class DlopenMobileDeviceAPI: MobileDeviceAPI, @unchecked Sendable {
    public let capabilities: MobileDeviceCapabilities

    private let fnSubscribe: FnSubscribe
    private let fnUnsubscribe: FnPtrToInt?
    private let fnCopyIdentifier: FnCopyString
    private let fnInterfaceType: FnPtrToInt?
    private let fnConnect: FnPtrToInt
    private let fnDisconnect: FnPtrToInt
    private let fnIsPaired: FnPtrToInt
    private let fnValidatePairing: FnPtrToInt
    private let fnPair: FnPtrToInt?
    private let fnStartSession: FnPtrToInt
    private let fnStopSession: FnPtrToInt
    private let fnCopyValue: FnCopyValue
    private let fnSetValue: FnSetValue?
    private let fnRetain: FnPtrToVoid
    private let fnRelease: FnPtrToVoid

    private let lock = NSLock()
    private var handler: ((MDDeviceEvent) -> Void)?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var notification: UnsafeMutableRawPointer?

    init(symbols s: [String: UnsafeMutableRawPointer]) {
        func req<T>(_ name: String, _: T.Type) -> T { unsafeBitCast(s[name]!, to: T.self) }
        func opt<T>(_ name: String, _: T.Type) -> T? { s[name].map { unsafeBitCast($0, to: T.self) } }
        fnSubscribe = req("AMDeviceNotificationSubscribe", FnSubscribe.self)
        fnUnsubscribe = opt("AMDeviceNotificationUnsubscribe", FnPtrToInt.self)
        fnCopyIdentifier = req("AMDeviceCopyDeviceIdentifier", FnCopyString.self)
        fnInterfaceType = opt("AMDeviceGetInterfaceType", FnPtrToInt.self)
        fnConnect = req("AMDeviceConnect", FnPtrToInt.self)
        fnDisconnect = req("AMDeviceDisconnect", FnPtrToInt.self)
        fnIsPaired = req("AMDeviceIsPaired", FnPtrToInt.self)
        fnValidatePairing = req("AMDeviceValidatePairing", FnPtrToInt.self)
        fnPair = opt("AMDevicePair", FnPtrToInt.self)
        fnStartSession = req("AMDeviceStartSession", FnPtrToInt.self)
        fnStopSession = req("AMDeviceStopSession", FnPtrToInt.self)
        fnCopyValue = req("AMDeviceCopyValue", FnCopyValue.self)
        fnSetValue = opt("AMDeviceSetValue", FnSetValue.self)
        fnRetain = req("AMDeviceRetain", FnPtrToVoid.self)
        fnRelease = req("AMDeviceRelease", FnPtrToVoid.self)
        capabilities = MobileDeviceCapabilities(canPair: fnPair != nil, canSetValues: fnSetValue != nil,
                                                canFilterInterface: fnInterfaceType != nil)
    }

    public func subscribe(_ handler: @escaping (MDDeviceEvent) -> Void) throws {
        lock.withLock { self.handler = handler }
        if lock.withLock({ thread != nil }) { return }

        let ready = DispatchSemaphore(value: 0)
        var result: Int32 = 0
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: NotificationCallback = { info, arg in
            guard let info, let arg else { return }
            let api = Unmanaged<DlopenMobileDeviceAPI>.fromOpaque(arg).takeUnretainedValue()
            let dev = info.load(as: UnsafeMutableRawPointer?.self)
            let msg = info.load(fromByteOffset: MemoryLayout<UnsafeMutableRawPointer?>.size, as: UInt32.self)
            api.dispatch(device: dev, message: msg)
        }
        let t = Thread { [self] in
            let rl = CFRunLoopGetCurrent()
            // Keep the run loop alive even if the subscription adds no source to this thread.
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0) { _ in }
            CFRunLoopAddTimer(rl, keepAlive, .defaultMode)
            var sub: UnsafeMutableRawPointer?
            result = fnSubscribe(callback, 0, 0, context, &sub)
            lock.withLock { self.runLoop = rl; self.notification = sub }
            ready.signal()
            if result == 0 { CFRunLoopRun() }
            CFRunLoopRemoveTimer(rl, keepAlive, .defaultMode)
        }
        t.name = "OpenTap.MobileDevice"
        t.qualityOfService = .userInitiated
        lock.withLock { thread = t }
        t.start()
        ready.wait()
        if result != 0 {
            lock.withLock { thread = nil; runLoop = nil; notification = nil }
            throw OpenTapError(.frameworkUnavailable, what: "Couldn't watch for iPhones on USB",
                               why: "AMDeviceNotificationSubscribe returned \(AMDResult.hex(result))",
                               fix: "Quit other apps that talk to the iPhone (Xcode, Finder sync), then reopen OpenTap. "
                                   + MobileDeviceFramework.manualFallback)
        }
    }

    public func unsubscribe() {
        let (rl, sub): (CFRunLoop?, UnsafeMutableRawPointer?) = lock.withLock {
            let v = (runLoop, notification)
            handler = nil; runLoop = nil; notification = nil; thread = nil
            return v
        }
        guard let rl else { return }
        let unsub = fnUnsubscribe
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) {
            if let sub, let unsub { _ = unsub(sub) }
            CFRunLoopStop(rl)
        }
        CFRunLoopWakeUp(rl)
    }

    private func dispatch(device: UnsafeMutableRawPointer?, message: UInt32) {
        guard let device, let msg = NotificationMessage(rawValue: message) else { return }
        let h = lock.withLock { handler }
        switch msg {
        case .connected: h?(.attached(MDDevice(device)))
        case .disconnected: h?(.detached(MDDevice(device)))
        case .unsubscribed: break
        }
    }

    public func retain(_ device: MDDevice) { fnRetain(device.pointer) }
    public func release(_ device: MDDevice) { fnRelease(device.pointer) }

    public func identifier(_ device: MDDevice) -> String? {
        fnCopyIdentifier(device.pointer).map { $0.takeRetainedValue() as String }
    }

    public func interfaceType(_ device: MDDevice) -> Int? { fnInterfaceType.map { Int($0(device.pointer)) } }
    public func connect(_ device: MDDevice) -> Int32 { fnConnect(device.pointer) }
    public func disconnect(_ device: MDDevice) -> Int32 { fnDisconnect(device.pointer) }
    public func isPaired(_ device: MDDevice) -> Bool { fnIsPaired(device.pointer) != 0 }
    public func validatePairing(_ device: MDDevice) -> Int32 { fnValidatePairing(device.pointer) }
    public func pair(_ device: MDDevice) -> Int32 {
        guard let fnPair else { return Int32(bitPattern: 0xE800_0001) }
        return fnPair(device.pointer)
    }
    public func startSession(_ device: MDDevice) -> Int32 { fnStartSession(device.pointer) }
    public func stopSession(_ device: MDDevice) -> Int32 { fnStopSession(device.pointer) }

    public func copyValue(_ device: MDDevice, domain: String?, key: String) -> Any? {
        guard let v = fnCopyValue(device.pointer, domain as CFString?, key as CFString) else { return nil }
        return v.takeRetainedValue()
    }

    public func setValue(_ device: MDDevice, domain: String?, key: String, value: Any) -> Int32 {
        guard let fnSetValue else { return Int32(bitPattern: 0xE800_0001) }
        return fnSetValue(device.pointer, domain as CFString?, key as CFString, value as CFTypeRef)
    }
}
