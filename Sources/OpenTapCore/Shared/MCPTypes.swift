import Foundation

public enum MCPServerState: Equatable, Sendable {
    case stopped
    case starting
    case listening(host: String, port: UInt16)
    case failed(OpenTapError)
}

public enum MCPDefaults {
    public static let host = "127.0.0.1"
    public static let port: UInt16 = 47900
    public static let path = "/mcp"
    public static let protocolVersion = "2025-06-18"
    public static let serverName = "opentap"
    public static var url: String { "http://\(host):\(port)\(path)" }
    public static var claudeAddCommand: String { "claude mcp add --transport http --scope user opentap \(url)" }
}
