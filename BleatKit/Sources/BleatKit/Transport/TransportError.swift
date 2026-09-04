import Foundation

/// The network / channel layer failed. Distinct from `HerdrError`, which means
/// the host was reached and said no.
public enum TransportError: Error, Sendable, Equatable {
    case notConnected
    case connectionFailed(String)
    case channelClosed
    case hostKeyMismatch(expected: String, actual: String)
    case authenticationFailed(String)
    case oversizedRecord(limit: Int)
}

/// The `herdr` process ran and reported failure. `stderr` is never discarded.
public struct HerdrError: Error, Sendable, Equatable {
    public let command: [String]
    public let exitCode: Int32
    public let stderr: String
    /// Structured body when the host emitted `{"error": {...}}`.
    public let code: String?
    public let message: String?

    public init(
        command: [String],
        exitCode: Int32,
        stderr: String,
        code: String? = nil,
        message: String? = nil
    ) {
        self.command = command
        self.exitCode = exitCode
        self.stderr = stderr
        self.code = code
        self.message = message
    }
}

extension HerdrError {
    /// Builds an error from a failed `herdr` invocation, preferring the
    /// structured body.
    ///
    /// On failure herdr writes `{"id":…,"error":{"code","message"}}` to
    /// **stderr**, not stdout, and exits non-zero.
    public static func fromStderr(command: [String], exitCode: Int32, stderr: Data) -> HerdrError {
        let text = String(decoding: stderr, as: UTF8.self)
        let body = stderr
            .split(separator: 0x0A)
            .lazy
            .compactMap { try? JSONDecoder().decode(HerdrErrorEnvelope.self, from: Data($0)) }
            .first?
            .error
        return HerdrError(
            command: command,
            exitCode: exitCode,
            stderr: text,
            code: body?.code,
            message: body?.message
        )
    }
}

extension HerdrError: CustomStringConvertible {
    public var description: String {
        let detail = message ?? stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "herdr \(command.joined(separator: " ")) failed (\(exitCode)): \(detail)"
    }
}
