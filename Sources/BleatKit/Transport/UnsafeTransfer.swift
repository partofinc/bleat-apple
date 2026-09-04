import Foundation

/// Carries a value that is not `Sendable` across a concurrency boundary.
///
/// Citadel's `SSHClient` predates strict-concurrency auditing and is not
/// `Sendable`, so it cannot live in an actor or cross into a `Task` on its own.
/// Everything in BleatKit that touches one is serialized through
/// `SSHTransport`'s lock instead, which is what makes this sound.
///
/// This is the only unchecked escape hatch in the package. Do not reach for it
/// to silence a warning on our own types — make those genuinely `Sendable`.
struct UnsafeTransfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
