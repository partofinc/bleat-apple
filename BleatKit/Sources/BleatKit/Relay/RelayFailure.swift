import Foundation

/// An error from the phone's side of the relay, in a form that survives the
/// trip to the watch.
///
/// **The error classes arrive as themselves.** A screen decides what to say —
/// and whether to drop the connection — from whether it caught a `ShellError`
/// or a `TransportError`. Flattening them to a sentence on the way through
/// would make every refused command look like a dead network.
public enum RelayFailure: Sendable, Codable, Equatable {
    case shell(ShellError)
    case transport(TransportError)
    /// herdr-core said no: the host was reached and refused the call.
    case hc(code: Int, message: String, kind: String?)
    /// The watch named a host the phone has no record of — unpaired on the
    /// phone since the watch last heard.
    case unknownPeer
    case cancelled
    /// Anything else, as its description.
    case other(String)

    public init(_ error: any Error) {
        switch error {
        case let failure as RelayFailure: self = failure
        case let shell as ShellError: self = .shell(shell)
        case let transport as TransportError: self = .transport(transport)
        case let hc as HcError: self = .hc(code: hc.code, message: hc.message, kind: hc.kind)
        case is CancellationError: self = .cancelled
        default: self = .other(String(describing: error))
        }
    }

    /// What the watch throws for this.
    public var error: any Error {
        switch self {
        case .shell(let shell): shell
        case .transport(let transport): transport
        case .hc(let code, let message, let kind): HcError(code: code, message: message, kind: kind)
        case .unknownPeer:
            TransportError.connectionFailed("this host is no longer paired on the iPhone")
        case .cancelled: CancellationError()
        case .other(let detail): TransportError.connectionFailed(detail)
        }
    }
}

extension RelayFailure: Error {}
