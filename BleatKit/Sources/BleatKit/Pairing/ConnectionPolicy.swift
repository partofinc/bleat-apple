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
    ///
    /// The tunnel is part of that state, because it changes which endpoints are
    /// candidates: a private address is dropped without one and raced with one,
    /// so a connection made before a VPN connected was raced over a strictly
    /// smaller list, and reusing it would pin the phone to that list for as
    /// long as the screen stays open.
    ///
    /// **Compared through `candidateIdentity`, not as a whole.** On the local
    /// link every endpoint is a candidate whatever the tunnel is doing, so a
    /// tunnel change there cannot alter the raced list — and comparing it would
    /// discard a working connection for nothing. An on-demand VPN profile
    /// connecting and dropping while the app sits on Wi-Fi would tear down the
    /// live SSH session and re-handshake on the next request, repeatedly.
    public static func canReuse(
        cachedHostKey: String,
        cachedLink: LinkState,
        for peer: PairedPeer,
        link: LinkState
    ) -> Bool {
        cachedHostKey == peer.hostKey
            && cachedLink.candidateIdentity == link.candidateIdentity
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

    /// Whether an error is the host having run the command and refused it —
    /// rather than the command's fate being unknown.
    ///
    /// The other half of the question above, and it matters for a **write**.
    /// A failed write is not proof that nothing happened: a connection that
    /// drops between herdr running a command and its reply arriving leaves the
    /// work done and the caller none the wiser, which is why `SessionStarter`
    /// polls `session list` and `bleat keys revoke` re-reads the file.
    ///
    /// A `HerdrError` is the one failure that settles it without asking. The
    /// host answered, in its own error envelope, having processed the command
    /// and declined — so nothing was created, stopped or deleted, and a retry
    /// is safe. Treating it as unknown is not merely cautious: it tells the
    /// user something may have happened on their Mac when it demonstrably did
    /// not, and any sensible response to "may have" is to stop and go look.
    ///
    /// A `DecodingError` is deliberately *not* included, and that is the
    /// interesting case: the command succeeded and it is only the reply this
    /// build could not read, so the write almost certainly landed. That one has
    /// to be checked, never assumed away.
    public static func isRefusalByHost(_ error: any Error) -> Bool {
        error is HerdrError
    }
}
