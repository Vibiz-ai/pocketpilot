import Foundation

public enum Permission: String, Codable, Sendable, CaseIterable { case camera, bluetooth }

public enum PermissionStatus: String, Codable, Sendable { case notDetermined, granted, denied, restricted }

/// TCC permissions. Implemented in Permissions/ (AVCaptureDevice + CBManager) and Mock/.
public protocol PermissionsProvider: AnyObject {
    func status(_ p: Permission) -> PermissionStatus
    /// Shows the system prompt if not determined; returns the resulting status.
    func request(_ p: Permission) async -> PermissionStatus
    /// Opens System Settings at the right Privacy pane.
    func openSettings(_ p: Permission)
}
