import Foundation

/// The network / channel layer failed. Distinct from `HerdrError`, which means
/// the host was reached and said no.
public enum TransportError: Error, Sendable, Equatable, Codable {
    case notConnected
    case connectionFailed(String)
    /// Nothing answered, and every address that could have been tried was a
    /// mesh VPN's. Separate from `connectionFailed` because the remedy is
    /// different — check the tunnel, not the network — and because callers
    /// classify on the case rather than on the sentence: `PairingModel` treats
    /// a plain `connectionFailed` as possibly iOS's local network permission,
    /// which cannot be the cause when no local address was dialled at all.
    case overlayUnreachable(String)
    case channelClosed
    case hostKeyMismatch(expected: String, actual: String)
    case authenticationFailed(String)
    case oversizedRecord(limit: Int)
}

extension TransportError: CustomStringConvertible {
    /// `HerdrError` and `PairingError` already describe themselves; this was
    /// the odd one out, and the console tool's private rendering could not be
    /// reached from the app — so a failed connection reached the user as
    /// `connectionFailed("…")`, enum case and all.
    ///
    /// A caller with more to say still can: the tool adds what to do about a
    /// changed host key, which is advice only it can give.
    public var description: String {
        switch self {
        case .notConnected:
            "not connected"
        case .connectionFailed(let detail):
            "could not connect: \(detail)"
        case .overlayUnreachable(let detail):
            "could not connect: \(detail)"
        case .channelClosed:
            "the connection closed"
        case .hostKeyMismatch:
            "the host key changed — refusing to connect"
        case .authenticationFailed(let detail):
            "the host refused this key: \(detail)"
        case .oversizedRecord(let limit):
            "the host sent a record longer than \(limit) bytes without a newline"
        }
    }
}

/// The `herdr` process ran and reported failure. `stderr` is never discarded.
public struct HerdrError: Error, Sendable, Equatable, Codable {
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
