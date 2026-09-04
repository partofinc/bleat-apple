import Foundation

/// Minimal mutex-guarded value, for state shared between a `Process`'s
/// callback threads and async callers.
///
/// `NSLock` cannot be locked directly from an async context under strict
/// concurrency; keeping every acquisition inside a synchronous method is what
/// makes this safe to use from one.
final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }

    var current: Value { withLock { $0 } }
}
