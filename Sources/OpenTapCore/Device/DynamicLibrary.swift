import Darwin
import Foundation

/// Opaque handle to a loaded dynamic library.
public struct LibraryHandle: @unchecked Sendable {
    public let raw: UnsafeMutableRawPointer
    public init(_ raw: UnsafeMutableRawPointer) { self.raw = raw }
}

/// Injectable dlopen/dlsym so the soft-fail paths can be tested without the private framework.
public protocol DynamicLibraryLoader: AnyObject {
    /// Returns nil when the library can't be loaded; `lastError` then says why.
    func open(_ path: String) -> LibraryHandle?
    func symbol(_ name: String, in library: LibraryHandle) -> UnsafeMutableRawPointer?
    /// Human-readable reason for the last failed `open`/`symbol`, if any.
    var lastError: String? { get }
}

/// The real loader: dlopen(RTLD_NOW | RTLD_LOCAL) + dlsym.
public final class DlopenLoader: DynamicLibraryLoader {
    public private(set) var lastError: String?
    public init() {}

    public func open(_ path: String) -> LibraryHandle? {
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            lastError = dlerror().map { String(cString: $0) }
            return nil
        }
        lastError = nil
        return LibraryHandle(h)
    }

    public func symbol(_ name: String, in library: LibraryHandle) -> UnsafeMutableRawPointer? {
        guard let s = dlsym(library.raw, name) else {
            lastError = dlerror().map { String(cString: $0) }
            return nil
        }
        return s
    }
}
