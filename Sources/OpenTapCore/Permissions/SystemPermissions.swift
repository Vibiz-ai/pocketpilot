import AppKit
import AVFoundation
import CoreBluetooth
import Foundation

/// Owner: frontend. Camera via AVCaptureDevice.authorizationStatus/requestAccess, Bluetooth via CBManager.authorization.
public final class SystemPermissions: PermissionsProvider {
    public init() {}
    public func status(_ p: Permission) -> PermissionStatus { .notDetermined }
    public func request(_ p: Permission) async -> PermissionStatus { .notDetermined }
    public func openSettings(_ p: Permission) {}
}
