import Foundation

/// Everything a connection to one host can be asked for, whatever carries it.
///
/// `ConnectionStore` holds one of these rather than an `SSHTransport`, which is
/// what lets a device that cannot open a socket of its own — the watch — put a
/// relay through the phone in the same place. See `RelayTransport`.
public protocol PeerLink: HerdrTransport, ShellRunner {
    /// Selects the session every later `run(_:)` is prefixed with.
    func useSession(_ session: String?)

    /// Runs one `herdr` command in a named session, leaving the selection
    /// `useSession` made alone.
    ///
    /// For a caller that answers on behalf of somebody else: the phone relays
    /// a watch's commands, each naming its own session, and setting the shared
    /// prefix for one of them would change which session the next one reads.
    func run(_ args: [String], inSession session: String?) async throws -> Data

    /// Drops the connection. The next call reconnects.
    func disconnect() async
}
