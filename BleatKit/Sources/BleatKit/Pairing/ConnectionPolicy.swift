import Foundation

/// When a connection may be reused, and when it is finished.
///
/// Two small decisions, and both were wrong once. They live here rather than in
/// the store that applies them because they are about peers and transports, not
/// about screens — and because a decision inside an `@Observable` in `BleatUI`
/// has no test target to be wrong in front of.
public enum ConnectionPolicy {
    /// Whether a cached connection can still serve this peer.
    ///
    /// The host key is the obvious half. The link state is the half that was
    /// missing: a connection is raced once and then pinned to whichever address
    /// won, so one made on Wi-Fi against a `.local` name can only fail after
    /// the phone moves to cellular — and the peer's overlay address, which
    /// would have worked, never gets a turn because the cache answered first.
    public static func canReuse(
        cachedHostKey: String,
        cachedOnLocalLink: Bool,
        for peer: PairedPeer,
        onLocalLink: Bool
    ) -> Bool {
        cachedHostKey == peer.hostKey && cachedOnLocalLink == onLocalLink
    }

    /// Whether an error means the connection itself is over, rather than the
    /// command that ran on it.
    ///
    /// `HerdrError` deliberately does not qualify: the host was reached and
    /// said no. Throwing away a working connection over one failed command
    /// would make every retry pay for a fresh handshake, and it would hide the
    /// real problem behind a reconnection that always succeeds.
    ///
    /// `CancellationError` does not either — the caller went away; the
    /// connection is fine and the next screen will want it.
    public static func isFatalToConnection(_ error: any Error) -> Bool {
        error is TransportError
    }
}
