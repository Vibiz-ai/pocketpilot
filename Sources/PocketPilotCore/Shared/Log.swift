import Foundation

public enum LogLevel: String, Codable, Sendable, Comparable, CaseIterable {
    case debug, info, warning, error
    private var rank: Int { LogLevel.allCases.firstIndex(of: self)! }
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

public struct LogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var date: Date
    public var level: LogLevel
    /// Module name: "capture", "vision", "bluetooth", "device", "control", "mcp", "app", "mock".
    public var category: String
    public var message: String
}

/// Shared, thread-safe ring-buffer logger. Named `Log` to avoid clashing with os.Logger.
public final class Log: @unchecked Sendable {
    public let updates = EventChannel<LogEntry>()
    public var minimumLevel: LogLevel
    public var echoToStderr: Bool

    private let lock = NSLock()
    private var buffer: [LogEntry] = []
    private var nextID = 0
    private let capacity: Int

    public init(capacity: Int = 2000, minimumLevel: LogLevel = .debug, echoToStderr: Bool = false) {
        self.capacity = capacity
        self.minimumLevel = minimumLevel
        self.echoToStderr = echoToStderr
    }

    public var entries: [LogEntry] { lock.withLock { buffer } }

    public func log(_ level: LogLevel, _ category: String, _ message: String) {
        guard level >= minimumLevel else { return }
        let entry: LogEntry = lock.withLock {
            let e = LogEntry(id: nextID, date: Date(), level: level, category: category, message: message)
            nextID += 1
            buffer.append(e)
            if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
            return e
        }
        if echoToStderr {
            FileHandle.standardError.write(Data("[\(level.rawValue)] \(category): \(message)\n".utf8))
        }
        updates.send(entry)
    }

    public func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    public func info(_ category: String, _ message: String) { log(.info, category, message) }
    public func warning(_ category: String, _ message: String) { log(.warning, category, message) }
    public func error(_ category: String, _ message: String) { log(.error, category, message) }
    public func error(_ category: String, _ error: PocketPilotError) { log(.error, category, error.description) }
}
