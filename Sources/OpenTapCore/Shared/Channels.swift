import Foundation

/// Keeps a subscription alive. Cancels automatically when deallocated, so store it.
public final class Subscription: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (() -> Void)?
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() {
        let c: (() -> Void)? = lock.withLock { let c = onCancel; onCancel = nil; return c }
        c?()
    }
    deinit { cancel() }
}

/// A thread-safe current value with multiple subscribers (like a tiny CurrentValueSubject).
/// Handlers are called synchronously on the thread that calls `send`; hop to the main actor yourself for UI.
public final class StateChannel<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value
    private var handlers: [UUID: (Value) -> Void] = [:]

    public init(_ initial: Value) { current = initial }

    public var value: Value { lock.withLock { current } }

    public func send(_ newValue: Value) {
        let hs: [(Value) -> Void] = lock.withLock { current = newValue; return Array(handlers.values) }
        hs.forEach { $0(newValue) }
    }

    /// Calls `handler` immediately with the current value, then on every change.
    public func subscribe(_ handler: @escaping (Value) -> Void) -> Subscription {
        let id = UUID()
        let v: Value = lock.withLock { handlers[id] = handler; return current }
        handler(v)
        return Subscription { [weak self] in self?.lock.withLock { _ = self?.handlers.removeValue(forKey: id) } }
    }

    /// Async sequence of values, starting with the current one.
    public func values() -> AsyncStream<Value> {
        AsyncStream { cont in
            let sub = self.subscribe { cont.yield($0) }
            cont.onTermination = { _ in sub.cancel() }
        }
    }
}

/// A thread-safe event stream with no current value (log lines, HID reports, ...).
public final class EventChannel<Event>: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: (Event) -> Void] = [:]
    public init() {}

    public func send(_ event: Event) {
        let hs = lock.withLock { Array(handlers.values) }
        hs.forEach { $0(event) }
    }

    public func subscribe(_ handler: @escaping (Event) -> Void) -> Subscription {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return Subscription { [weak self] in self?.lock.withLock { _ = self?.handlers.removeValue(forKey: id) } }
    }
}
