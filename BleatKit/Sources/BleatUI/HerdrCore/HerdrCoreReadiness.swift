import BleatKit
import Observation

/// Whether each paired host is ready for Bleat 2, which talks to herdr-core
/// (`hc`) rather than the herdr TUI.
///
/// **The migration gate.** Every peer paired under 1.x is kept as it is — host
/// key, endpoints, device key line — and asked once, over the SSH path it
/// already connects on, whether `hc` is installed. The answer is stored on the
/// peer (`PairedPeer.herdrCore`); a host that could not be reached is held
/// here, for this run only, because it said nothing worth keeping.
///
/// A host that has herdr-core is never asked again. One that does not, or
/// could not be reached, is asked at every launch and every return to the
/// foreground, so installing hc on it is all it takes to move it on.
@Observable
public final class HerdrCoreReadiness {
    /// What the host list shows for a peer.
    public enum State: Equatable {
        /// herdr-core is installed: the peer is ready, and its row says
        /// nothing extra.
        case ready
        /// The host answered and has no herdr-core.
        case needsHerdrCore
        /// This run's check could not reach it. The message is why.
        case unreachable(String)
        /// A check is in flight and nothing earlier is known.
        case checking
        /// Never checked, and no check is coming from this device — the watch,
        /// before the phone has sent an answer.
        case unknown
    }

    /// Checks in flight, and this run's unreachable answers, by host key.
    private var checking: Set<String> = []
    private var unreachable: [String: String] = [:]

    private let peers: PeerStore
    private let reachability: Reachability
    /// False on the watch, which cannot open a connection: it shows what the
    /// phone found, from the mirrored records, and checks nothing.
    private let canCheck: Bool

    public init(peers: PeerStore, reachability: Reachability, canCheck: Bool) {
        self.peers = peers
        self.reachability = reachability
        self.canCheck = canCheck
    }

    public func state(of peer: PairedPeer) -> State {
        if case .installed = peer.herdrCore { return .ready }
        if checking.contains(peer.hostKey) {
            // An earlier "missing" stays on screen while it is asked again, so
            // a row does not flicker at every foreground.
            return peer.herdrCore == .missing ? .needsHerdrCore : .checking
        }
        if let message = unreachable[peer.hostKey] { return .unreachable(message) }
        if peer.herdrCore == .missing { return .needsHerdrCore }
        return canCheck ? .checking : .unknown
    }

    /// Asks every peer that is not ready yet, all at once. A host that does not
    /// answer costs its own timeout and holds up nobody else.
    public func checkAll() async {
        let pending = peers.peers.filter { !($0.herdrCore?.isInstalled ?? false) }
        await withTaskGroup(of: Void.self) { group in
            for peer in pending {
                group.addTask { await self.check(peer) }
            }
        }
    }

    /// Asks one peer. Does nothing while that peer is already being asked.
    public func check(_ peer: PairedPeer) async {
        guard canCheck, !checking.contains(peer.hostKey) else { return }
        let deviceKey: SSHKeyPair
        do {
            deviceKey = try peers.deviceKey()
        } catch {
            unreachable[peer.hostKey] = String(describing: error)
            return
        }
        checking.insert(peer.hostKey)
        defer { checking.remove(peer.hostKey) }

        let outcome = await HerdrCoreCheck.run(peer: peer, deviceKey: deviceKey, link: reachability.link)
        switch outcome {
        case .answered(let herdrCore, let endpoint):
            unreachable[peer.hostKey] = nil
            peers.recordSuccess(endpoint: endpoint, for: peer)
            peers.recordHerdrCore(herdrCore, for: peer)
        case .unreachable(let message):
            unreachable[peer.hostKey] = message
        }
    }
}
