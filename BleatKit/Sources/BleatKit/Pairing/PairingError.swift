import Foundation

/// Pairing went wrong. Distinct from `TransportError`: these all happen before
/// or around the connection, not on it.
public enum PairingError: Error, Sendable, Equatable {
    /// Scanned something that is not a Bleat pairing code at all — most likely
    /// a Wi-Fi QR or a URL. Worth distinguishing from a corrupt code so the UI
    /// can say "that is not a Bleat code" rather than "that code is damaged".
    case notAPairingCode
    /// A Bleat code that will not decode: truncated scan, wrong field types, a
    /// seed that is not 32 bytes, or an endpoint that will not parse.
    case malformedPairingCode
    /// A newer tool made this code. Decoding what we recognise would be worse
    /// than stopping: a later version may move the enrollment key or change
    /// what the fingerprint covers.
    case unsupportedVersion(Int)
    /// The host answered with a host key other than the one the QR named.
    /// Never a prompt — the fingerprint travelled out of band precisely so this
    /// can be a hard stop.
    case hostKeyMismatch(expected: String, actual: String)
    /// The host has no `herdr`, so pairing it would produce an app that can
    /// list nothing.
    case herdrNotFound
    /// Enrollment did not finish: the phone never swapped its own key in.
    case enrollmentIncomplete(String)
}

extension PairingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notAPairingCode:
            "that is not a Bleat pairing code"
        case .malformedPairingCode:
            "the pairing code could not be read; try scanning again"
        case .unsupportedVersion(let version):
            "this pairing code needs a newer version of Bleat (format \(version))"
        case .hostKeyMismatch(let expected, let actual):
            "the host key does not match the pairing code (expected \(expected), got \(actual))"
        case .herdrNotFound:
            "herdr is not installed on that host"
        case .enrollmentIncomplete(let reason):
            "pairing did not complete: \(reason)"
        }
    }
}
