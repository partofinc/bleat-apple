import Foundation

/// Carries a value that is not `Sendable` across a concurrency boundary.
///
/// Citadel's `SSHClient` predates strict-concurrency auditing and is not
/// `Sendable`, so it cannot live in an actor or cross into a `Task` on its own.
///
/// What actually makes this safe is narrower than "we hold a lock", and worth
/// stating precisely: the lock guards only the *reference*, not calls made
/// through it. List polling and the pane stream deliberately open channels
/// concurrently, so `SSHClient` is used from several tasks at once. That is
/// sound because the transport dials with `reconnect: .never`, which means the
/// client's `session` is assigned once at connect and never reassigned;
/// opening a channel only reads it. **If reconnect support is ever added,
/// channel opens must be serialized first.**
///
/// This is the only unchecked escape hatch in the package. Do not reach for it
/// to silence a warning on our own types — make those genuinely `Sendable`.
struct UnsafeTransfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
