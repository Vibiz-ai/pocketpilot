import Foundation

/// Every failure in OpenTap says what failed, why, and how to fix it.
/// Never throw a generic error: build one of these, ideally via a static helper below.
public struct OpenTapError: Error, Codable, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    public enum Code: String, Codable, Sendable {
        case notImplemented
        case permissionDenied
        case frameworkUnavailable
        case noDevice
        case deviceLocked
        case notPaired
        case captureFailed
        case noFrame
        case bluetoothUnavailable
        case hidNotConnected
        case assistiveTouchOff
        case notCalibrated
        case calibrationFailed
        case pointerNotFound
        case textNotFound
        case appNotOpened
        case invalidArgument
        case timeout
        case io
        case network
        case internalError
    }

    public var code: Code
    /// What failed, e.g. "Couldn't start the iPhone screen capture".
    public var what: String
    /// Why it failed, e.g. "Camera access is denied for OpenTap".
    public var why: String
    /// How to fix it, e.g. "Open System Settings > Privacy & Security > Camera and turn on OpenTap".
    public var fix: String

    public init(_ code: Code, what: String, why: String, fix: String) {
        self.code = code
        self.what = what
        self.why = why
        self.fix = fix
    }

    public var description: String { "\(what): \(why). Fix: \(fix)" }
    public var errorDescription: String? { description }
    public var failureReason: String? { why }
    public var recoverySuggestion: String? { fix }

    /// Wraps any error into an OpenTapError (passes OpenTapError through unchanged).
    public static func wrap(_ error: Error, what: String, fix: String = "Try again; if it keeps failing, check the log in the OpenTap window.") -> OpenTapError {
        if let e = error as? OpenTapError { return e }
        return OpenTapError(.internalError, what: what, why: error.localizedDescription, fix: fix)
    }

    /// Placeholder used by scaffold stubs until a module is implemented.
    public static func notImplemented(_ feature: String, module: String) -> OpenTapError {
        OpenTapError(.notImplemented,
                     what: "\(feature) is not available",
                     why: "The \(module) module has not been implemented in this build",
                     fix: "Update OpenTap to a build that includes \(module)")
    }

    public static func invalidArgument(_ name: String, why: String, fix: String) -> OpenTapError {
        OpenTapError(.invalidArgument, what: "Invalid value for '\(name)'", why: why, fix: fix)
    }
}
