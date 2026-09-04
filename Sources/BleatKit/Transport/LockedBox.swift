import Foundation

/// Minimal mutex-guarded value, for state shared between callback threads and
/// async callers.
///
/// Deliberately **internal**, and deliberately unconstrained: it has to box a
/// non-Sendable `TTYStdinWriter`. That is only sound because every use is
/// audited inside this module. Made public it would be a general-purpose
/// Sendable-laundering box — `LockedBox(someNonSendableModel)` would compile
/// clean and carry a reference across an isolation boundary with the
/// compiler's blessing, which is the opposite of what this package promises.
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
