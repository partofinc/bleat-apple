import BleatKit
import Observation

/// Unpairing, which is two things and used to be one.
///
/// Forgetting the peer locally is the easy half and was all the app did. The
/// half that matters is removing this device's key from the host: nothing else
/// can, the phone is the only party that knows the key, and a
/// `bleat-device-…` line left behind grants a full shell to a phone that may by
/// then be lost or sold.
///
/// So the record is dropped **only** once the key is gone, and when the key
/// cannot be reached the user is shown the command that removes it at the Mac
/// — before being offered the chance to forget the record that names it.
@Observable
public final class UnpairModel {
    public enum Phase: Equatable {
        case idle
        /// Asked, not yet started.
        case confirming(PairedPeer)
        /// Connecting, or removing the key.
        case working(PairedPeer)
        /// The peer is still paired and still works. What failed was taking
        /// access away.
        case keyRemains(PairedPeer, reason: String, advice: RevocationAdvice)
        /// The host was **reached** and refused this key.
        ///
        /// Its own case because the advice inverts. The likeliest reading is
        /// that the key has already been removed there, so telling the user it
        /// "is still on that Mac" would be false — and `bleat keys revoke`
        /// would fail with "no Bleat key with that marker", which reads like a
        /// second problem. The other reading is that the key is in the file and
        /// sshd is ignoring it, which is what a `StrictModes` permissions drift
        /// looks like, so the honest screen names both and sends the user to
        /// look.
        case hostRefusedKey(PairedPeer, advice: RevocationAdvice)
    }

    public private(set) var phase: Phase = .idle

    private let peers: PeerStore
    private let connections: ConnectionStore
    private let navigation: NavigationRouter

    public init(peers: PeerStore, connections: ConnectionStore, navigation: NavigationRouter) {
        self.peers = peers
        self.connections = connections
        self.navigation = navigation
    }

    #if DEBUG
    /// Parked in one phase, for `#Preview`.
    ///
    /// The two failure phases are the reason this flow is a sheet rather than
    /// an alert — a command to copy, an explanation of what is still true if it
    /// is not run, and a way out named for what it leaves behind — and neither
    /// can be reached without a host that refuses.
    convenience init(previewing phase: Phase) {
        let peers = PeerStore(registry: .sample())
        let reachability = Reachability()
        self.init(
            peers: peers,
            connections: ConnectionStore(peers: peers, reachability: reachability),
            navigation: NavigationRouter()
        )
        self.phase = phase
    }
    #endif

    public var peerBeingUnpaired: PairedPeer? {
        switch phase {
        case .idle: nil
        case .confirming(let peer), .working(let peer),
             .keyRemains(let peer, _, _), .hostRefusedKey(let peer, _): peer
        }
    }

    /// Whether the confirmation dialog is up.
    ///
    /// Settable so a view can bind to it: SwiftUI owns dismissal of a dialog,
    /// and the model has to hear about a swipe-away as much as about a button.
    public var isConfirming: Bool {
        get { if case .confirming = phase { true } else { false } }
        set { if !newValue, case .confirming = phase { phase = .idle } }
    }

    /// Whether the sheet is up — the spinner while the key is being removed,
    /// and the explanation if it could not be.
    ///
    /// One sheet for both because they are one moment: the explanation is what
    /// the spinner turns into. Two would mean dismissing one to present the
    /// other, which on iOS is a visible flicker and a lost animation.
    public var isShowingProgress: Bool {
        get {
            switch phase {
            case .working, .keyRemains, .hostRefusedKey: true
            case .idle, .confirming: false
            }
        }
        // A dismissal while the work is in flight is refused rather than
        // obeyed. Interactive dismissal is disabled in the view as well, but
        // the model must not depend on a modifier being present to keep its
        // own state consistent.
        set { if !newValue, !isWorking { phase = .idle } }
    }

    /// Opens the confirmation. Unpairing is not a list-management gesture — it
    /// changes what a machine will let in — so nothing happens on a swipe alone.
    public func ask(about peer: PairedPeer) {
        guard case .idle = phase else { return }
        phase = .confirming(peer)
    }

    public func cancel() { phase = .idle }

    /// Removes the key from the host, then forgets the peer.
    ///
    /// That order is the whole point. Forgetting first would discard the
    /// `PairedPeer` — its endpoints, its host key, its device marker — which is
    /// everything needed both to reach the host and to tell the user which line
    /// to delete. There would be nothing left to retry with and nothing to name.
    ///
    /// - Parameter peer: Passed in rather than read back out of `phase`, and
    ///   that is not stylistic. The button lives in a confirmation dialog, and
    ///   dismissing one writes `isConfirming = false`, which returns `phase` to
    ///   `.idle`. If SwiftUI's write-back lands before this task body runs — it
    ///   does whenever the dismissal happens in the same main-actor turn as the
    ///   action — reading the peer from `phase` finds nothing and the tap
    ///   silently does nothing at all: no sheet, no error, no unpairing.
    public func unpair(_ peer: PairedPeer) async {
        guard !isWorking else { return }
        phase = .working(peer)
        do {
            let key = try peers.deviceKey()
            try await Revocation.revokeDeviceKey(key, on: try await connections.shell(for: peer))
            // The connection authenticated with a key that is no longer in the
            // host's `authorized_keys`. sshd does not re-check a live session,
            // so it still works — which is exactly why it must not be left
            // cached for something else to pick up.
            await connections.release()
            // Every screen below the root is a screen *of this peer*, and it
            // has just stopped existing. Popping is not tidying: a pane view
            // left on top would go on asking a connection that is gone.
            navigation.popToRoot()
            peers.remove(peer)
            phase = .idle
        } catch let error as TransportError {
            await connections.handle(error)
            // "Reached and refused" is not "could not reach", and the two need
            // opposite things said about them.
            if case .authenticationFailed = error {
                phase = .hostRefusedKey(peer, advice: adviceToCheck(for: peer))
            } else {
                phase = .keyRemains(peer, reason: ErrorMessage.of(error), advice: advice(for: peer))
            }
        } catch {
            await connections.handle(error)
            phase = .keyRemains(peer, reason: ErrorMessage.of(error), advice: advice(for: peer))
        }
    }

    /// Drops the record with the key still on the host.
    ///
    /// Offered because the alternative is worse: a peer that cannot be reached
    /// — a Mac that has been rebuilt, sold, or is simply on another network for
    /// good — would otherwise be un-removable, and a list that will not let go
    /// of a dead entry teaches people to ignore it. It is deliberately the
    /// third button, named for what it leaves behind, and reachable only from a
    /// screen that has already shown the command that finishes the job.
    public func forgetWithoutRevoking() {
        guard let peer = peerBeingUnpaired, !isWorking, !isConfirming else { return }
        navigation.popToRoot()
        peers.remove(peer)
        phase = .idle
    }

    /// Internal rather than private: the sheet has to refuse interactive
    /// dismissal while this is true.
    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    /// The command that finishes the job at the Mac.
    ///
    /// Built in `BleatKit`, where the marker format and the command surface are
    /// both defined, so the phone cannot drift from what the tool accepts.
    private func advice(for peer: PairedPeer) -> RevocationAdvice {
        .revoke(deviceMarker: peer.deviceMarker, deviceFingerprint: fingerprint)
    }

    private func adviceToCheck(for peer: PairedPeer) -> RevocationAdvice {
        .check(deviceMarker: peer.deviceMarker, deviceFingerprint: fingerprint)
    }

    /// Best effort: the key may be exactly what could not be read, and that is
    /// one of the ways this screen is reached at all.
    private var fingerprint: String? {
        try? peers.deviceKey().fingerprint
    }
}
