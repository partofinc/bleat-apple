import Foundation

/// An error from the phone's side of the relay, in a form that survives the
/// trip to the watch.
///
/// **The three error classes arrive as themselves.** A screen decides what to
/// say — and whether to drop the connection, and whether a write may have
/// happened — from whether it caught a `HerdrError`, a `ShellError` or a
/// `TransportError`. Flattening them to a sentence on the way through would
/// make every refusal by herdr look like a dead network.
public enum RelayFailure: Sendable, Codable, Equatable {
    case herdr(HerdrError)
    case shell(ShellError)
    case transport(TransportError)
    /// The watch named a host the phone has no record of — unpaired on the
    /// phone since the watch last heard.
    case unknownPeer
    case cancelled
    /// Anything else, as its description.
    case other(String)

    public init(_ error: any Error) {
        switch error {
        case let failure as RelayFailure: self = failure
        case let herdr as HerdrError: self = .herdr(herdr)
        case let shell as ShellError: self = .shell(shell)
        case let transport as TransportError: self = .transport(transport)
        case is CancellationError: self = .cancelled
        default: self = .other(String(describing: error))
        }
    }

    /// What the watch throws for this.
    public var error: any Error {
        switch self {
        case .herdr(let herdr): herdr
        case .shell(let shell): shell
        case .transport(let transport): transport
        case .unknownPeer:
            TransportError.connectionFailed("this host is no longer paired on the iPhone")
        case .cancelled: CancellationError()
        case .other(let detail): TransportError.connectionFailed(detail)
        }
    }
}

extension RelayFailure: Error {}
