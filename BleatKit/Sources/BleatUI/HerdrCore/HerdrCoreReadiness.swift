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
        /// This run's check failed on this device, not on the network: the
        /// device key could not be read, or the answer could not be saved.
        case failed(String)
        /// A check is in flight and nothing earlier is known.
        case checking
        /// Bleat is running herdr-core's installer on the host.
        case installing
        /// This run's install reached the host and did not work. The message
        /// is the installer's own reason where it gave one.
        case installFailed(String)
        /// No answer is known and no check is running: a host paired since the
        /// last check, or the watch before the phone has sent an answer.
        case unknown
    }

    /// Checks in flight, and this run's answers that are not worth storing,
    /// by host key.
    private var checking: Set<String> = []
    /// Installs in flight, by host key. Held apart from `checking` so a
    /// foreground's `checkAll` cannot start a check that would race the
    /// install and store "missing" half way through it.
    private var installing: Set<String> = []
    private var problems: [String: State] = [:]

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
        if installing.contains(peer.hostKey) { return .installing }
        if checking.contains(peer.hostKey) {
            // An earlier "missing" stays on screen while it is asked again, so
            // a row does not flicker at every foreground.
            return peer.herdrCore == .missing ? .needsHerdrCore : .checking
        }
        if let problem = problems[peer.hostKey] { return problem }
        if peer.herdrCore == .missing { return .needsHerdrCore }
        // Only `.checking` while a check really runs. Saying it for every
        // unanswered peer showed a spinner that never ended, with no way to
        // retry, for a host paired after the launch check.
        return .unknown
    }

    /// Whether this device can check at all. The watch cannot.
    public var canRetry: Bool { canCheck }

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
        guard canCheck, !checking.contains(peer.hostKey), !installing.contains(peer.hostKey) else { return }
        let deviceKey: SSHKeyPair
        do {
            deviceKey = try peers.deviceKey()
        } catch {
            // The phone's own keychain, not the host: "Not reachable" would
            // send the user to look at the network.
            problems[peer.hostKey] = .failed("this device's key could not be read: \(error)")
            return
        }
        checking.insert(peer.hostKey)
        defer { checking.remove(peer.hostKey) }

        let outcome = await HerdrCoreCheck.run(peer: peer, deviceKey: deviceKey, link: reachability.link)
        switch outcome {
        case .answered(let herdrCore, let endpoint):
            do {
                try peers.recordHerdrCore(herdrCore, reachedAt: endpoint, for: peer)
                problems[peer.hostKey] = nil
            } catch {
                problems[peer.hostKey] = .failed("the answer could not be saved: \(error)")
            }
        case .unreachable(let message):
            problems[peer.hostKey] = .unreachable(message)
        case .cancelled:
            // Nothing was learned; whatever was shown before stands.
            break
        }
    }

    /// Runs herdr-core's official installer on a host that answered
    /// "missing", then looks again. Does nothing while that host is being
    /// checked or installed already, or on the watch.
    ///
    /// The caller is expected to have shown `HerdrCoreInstall.displayCommand`
    /// and had it confirmed: this runs a script from the network on someone's
    /// machine.
    ///
    /// **Not tied to the screen.** The gate starts it in a task of its own, so
    /// leaving the screen does not cancel an installer half way through on
    /// the host; the answer is recorded whenever it comes, and every screen
    /// showing the host reads it from here.
    public func install(_ peer: PairedPeer) async {
        guard canCheck, peer.herdrCore == .missing,
              !checking.contains(peer.hostKey), !installing.contains(peer.hostKey)
        else { return }
        let deviceKey: SSHKeyPair
        do {
            deviceKey = try peers.deviceKey()
        } catch {
            problems[peer.hostKey] = .failed("this device's key could not be read: \(error)")
            return
        }
        installing.insert(peer.hostKey)
        defer { installing.remove(peer.hostKey) }

        switch await HerdrCoreInstall.run(peer: peer, deviceKey: deviceKey, link: reachability.link) {
        case .installed(let herdrCore, let endpoint):
            do {
                try peers.recordHerdrCore(herdrCore, reachedAt: endpoint, for: peer)
                problems[peer.hostKey] = nil
            } catch {
                problems[peer.hostKey] = .failed("herdr-core was installed, but the answer could not be saved: \(error)")
            }
        case .failed(let message):
            problems[peer.hostKey] = .installFailed(message)
        case .unreachable(let message):
            problems[peer.hostKey] = .unreachable(message)
        case .cancelled:
            break
        }
    }
}
