import AppKit
import AVFoundation
import CoreBluetooth
import Foundation

/// Owner: frontend. Camera via AVCaptureDevice.authorizationStatus/requestAccess, Bluetooth via CBManager.authorization.
public final class SystemPermissions: PermissionsProvider {
    /// Kept alive while a Bluetooth prompt is pending (creating a CBCentralManager is what shows the prompt).
    private var bluetoothProbe: BluetoothProbe?

    public init() {}

    public func status(_ p: Permission) -> PermissionStatus {
        switch p {
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        }
    }

    public func request(_ p: Permission) async -> PermissionStatus {
        guard status(p) == .notDetermined else { return status(p) }
        switch p {
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
            return status(.camera)
        case .bluetooth:
            let probe = BluetoothProbe()
            bluetoothProbe = probe
            await probe.waitForDecision(timeout: 120)
            bluetoothProbe = nil
            return status(.bluetooth)
        }
    }

    public func openSettings(_ p: Permission) {
        let anchor: String
        switch p {
        case .camera: anchor = "Privacy_Camera"
        case .bluetooth: anchor = "Privacy_Bluetooth"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Creates a CBCentralManager (which triggers the Bluetooth TCC prompt) and waits until the user decides.
private final class BluetoothProbe: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private var manager: CBCentralManager?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForDecision(timeout: TimeInterval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.withLock { continuation = cont }
            DispatchQueue.main.async {
                self.manager = CBCentralManager(delegate: self, queue: .main)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { self.finish() }
        }
        DispatchQueue.main.async { self.manager = nil }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if CBManager.authorization != .notDetermined { finish() }
    }

    private func finish() {
        let c: CheckedContinuation<Void, Never>? = lock.withLock { let c = continuation; continuation = nil; return c }
        c?.resume()
    }
}
