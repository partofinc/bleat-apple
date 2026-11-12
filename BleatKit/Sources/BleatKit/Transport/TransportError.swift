import Foundation

/// The network / channel layer failed. Distinct from `HcError`, which means
/// herdr-core was reached and said no, and `ShellError`, a command that ran and
/// failed.
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
    /// `HcError`, `ShellError` and `PairingError` already describe themselves; this was
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
