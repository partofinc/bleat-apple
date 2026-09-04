import Foundation

/// Mutex-guarded value, for state shared between a `Process`'s callback threads
/// and async callers.
///
/// A near-copy of `BleatKit`'s, kept separate on purpose: that one is internal
/// because it must box a non-`Sendable` writer, and widening it to `public`
/// would have handed the whole package a Sendable-laundering escape hatch. This
/// target only ever boxes `Sendable` values, so it can say so in the signature
/// and be sound rather than merely audited.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }

    var current: Value { withLock { $0 } }
}
