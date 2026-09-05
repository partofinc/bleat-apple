import Foundation

/// Runs a shell command on the host.
///
/// Deliberately narrower than `HerdrTransport`, and deliberately separate from
/// it: pairing does not speak Herdr at all. Installing a key in
/// `authorized_keys` and finding where `herdr` lives are plain shell, and they
/// happen before the app knows whether the host can answer a `herdr` command.
///
/// A protocol rather than a concrete SSH type so the enrollment sequence — the
/// part where a mistake locks the phone out of the host, or leaves a live key
/// behind — is exercised by tests that touch no network.
public protocol ShellRunner: Sendable {
    /// Runs `command` through the host's shell and returns stdout.
    ///
    /// - Throws: `ShellError` on a non-zero exit, carrying stderr. Never
    ///   swallow it: the failures that actually happen here are an unwritable
    ///   `~/.ssh`, a full disk and a refused `chmod`, and each arrives as a
    ///   bare status with the explanation on stderr.
    func run(shell command: String) async throws -> String
}

/// A shell command ran on the host and failed.
///
/// Distinct from `HerdrError` (herdr was reached and said no) and from
/// `TransportError` (the connection itself). Pairing produces this one.
public struct ShellError: Error, Sendable, Equatable {
    public let command: String
    public let exitCode: Int32
    public let stderr: String

    public init(command: String, exitCode: Int32, stderr: String) {
        self.command = command
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

extension ShellError: CustomStringConvertible {
    public var description: String {
        // The status is carried alongside the text because the lock wrapper
        // signals an unwritable `~/.ssh` with exit 75 specifically, and a
        // reader who knows that can tell it apart from a generic failure.
        let detail = stderr.isEmpty ? "no output on stderr" : stderr
        return "the host rejected a command (exit \(exitCode)): \(detail)"
    }
}
