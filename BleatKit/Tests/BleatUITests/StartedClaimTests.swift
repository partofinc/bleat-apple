import BleatKit
import Testing
@testable import BleatUI

/// Keeping "this phone is why it is running" honest against stops this phone
/// did not perform.
///
/// **Worth its own suite because the claim is now a guard rather than a gate.**
/// It decides whether the stop confirmation warns that a session is not this
/// phone's, and that sentence is the only thing left in front of `herdr session
/// stop` — so a claim that outlives the session it described does not withhold a
/// button any more, it removes a warning. `forgetStartedSession` alone hears
/// only about a stop the phone itself performed.
@Suite("Reconciling the started-session claim")
@MainActor
struct StartedClaimTests {

    private func stored(_ registry: PeerRegistry, _ hostKey: String) -> PairedPeer? {
        (try? registry.all())?.first { $0.hostKey == hostKey }
    }

    private func peerWith(_ registry: PeerRegistry, started: [String]) throws -> PairedPeer {
        var peer = PairedPeer(
            hostKey: "ssh-ed25519 RECONCILE", name: "mac", username: "robin", endpoints: []
        )
        peer.startedSessions = started
        try registry.save(peer)
        return peer
    }

    /// **The case the fix is for.** The phone started `work`; the Mac rebooted,
    /// or somebody stopped it at the keyboard and attached it again. The next
    /// `session list` that sees it stopped is the only chance to notice.
    @Test("a claimed session the host reports stopped loses the claim")
    func stoppedElsewhereDropsTheClaim() throws {
        let registry = PeerRegistry.sample()
        let peers = PeerStore(registry: registry)
        let peer = try peerWith(registry, started: ["work"])
        peers.reload()
        #expect(stored(registry, peer.hostKey)?.startedHere("work") == true)

        peers.reconcileStartedSessions(
            with: [SessionInfo(name: "work", running: false, isDefault: true)],
            forHostKey: peer.hostKey
        )

        #expect(
            stored(registry, peer.hostKey)?.startedHere("work") == false,
            "a session the host says is stopped kept the claim that it is running because of us"
        )
    }

    /// And the warning it controls comes back with it, which is the point of
    /// the whole exercise rather than a second assertion about a flag.
    @Test("the stop confirmation warns again once the claim has expired")
    func theConfirmationRecovers() throws {
        let registry = PeerRegistry.sample()
        let peers = PeerStore(registry: registry)
        let peer = try peerWith(registry, started: ["work"])
        peers.reload()

        let running = SessionInfo(name: "work", running: true, isDefault: true)
        #expect(!SessionControlModel.confirmation(for: .stop, about: running, on: peer)
            .contains("did not start"))

        peers.reconcileStartedSessions(
            with: [SessionInfo(name: "work", running: false, isDefault: true)],
            forHostKey: peer.hostKey
        )
        let after = try #require(stored(registry, peer.hostKey))
        #expect(
            SessionControlModel.confirmation(for: .stop, about: running, on: after)
                .contains("did not start"),
            "the warning stayed off a session that is no longer ours"
        )
    }

    /// A running session keeps its claim. This is the half that would make the
    /// fix worse than the bug: reconciling on presence rather than on `running`
    /// would drop the claim on every refresh.
    @Test("a claimed session that is still running keeps the claim")
    func stillRunningKeepsIt() throws {
        let registry = PeerRegistry.sample()
        let peers = PeerStore(registry: registry)
        let peer = try peerWith(registry, started: ["work"])
        peers.reload()

        peers.reconcileStartedSessions(
            with: [SessionInfo(name: "work", running: true, isDefault: true)],
            forHostKey: peer.hostKey
        )
        #expect(stored(registry, peer.hostKey)?.startedHere("work") == true)
    }

    /// Stopped sessions this phone never claimed are left alone, and an
    /// unknown host key changes nothing — the same shape `PeerRegistry`'s own
    /// recording methods keep.
    @Test("nothing is touched that was not claimed")
    func unclaimedAndUnknownAreLeftAlone() throws {
        let registry = PeerRegistry.sample()
        let peers = PeerStore(registry: registry)
        let peer = try peerWith(registry, started: ["work"])
        peers.reload()

        peers.reconcileStartedSessions(
            with: [SessionInfo(name: "phone", running: false, isDefault: false)],
            forHostKey: peer.hostKey
        )
        #expect(stored(registry, peer.hostKey)?.startedHere("work") == true)

        peers.reconcileStartedSessions(
            with: [SessionInfo(name: "work", running: false, isDefault: true)],
            forHostKey: "ssh-ed25519 NOSUCHHOST"
        )
        #expect(stored(registry, peer.hostKey)?.startedHere("work") == true)
    }
}
