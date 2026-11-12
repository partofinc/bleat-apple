import Foundation

/// One short connection to a paired peer: open, do one thing over its shell,
/// disconnect — on every path.
///
/// The herdr-core check and the install both work this way, and each had its
/// own copy of the lifecycle. One copy, so a fix to how a session is closed
/// cannot land in only one of them: a failed command does not close the
/// channel and neither does cancellation, so returning without the
/// disconnect leaves an SSH session open on someone's machine.
///
/// Not the browsing connection `ConnectionStore` holds.
public enum PeerVisit<Value: Sendable>: Sendable {
    /// Connected, and `body` returned this.
    case reached(Value)
    /// No answer: nothing was reachable, or the host key did not match. The
    /// message is the error's own description.
    case unreachable(String)
    /// Cancelled before a connection was made.
    case cancelled

    /// Connects, runs `body`, disconnects. Never throws.
    ///
    /// Whether a cancellation part way through `body` voids what it returned
    /// is the caller's call: for a read-only check it does, and for an install
    /// that finished it must not.
    @concurrent
    public static func run(
        to peer: PairedPeer,
        deviceKey: SSHKeyPair,
        link: LinkState,
        _ body: @Sendable (PeerConnector.Connection) async -> Value
    ) async -> PeerVisit<Value> {
        let connection: PeerConnector.Connection
        do {
            connection = try await PeerConnection.open(to: peer, deviceKey: deviceKey, link: link)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .unreachable(String(describing: error))
        }
        let value = await body(connection)
        await connection.transport.disconnect()
        return .reached(value)
    }
}
