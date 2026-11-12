import BleatKit
import Observation
#if os(iOS)
import UIKit
#endif

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

    /// Checks in flight, by host key, held as tasks so an install can wait
    /// for one to finish rather than refuse.
    private var checks: [String: Task<Void, Never>] = [:]
    /// Installs in flight, by host key. Held apart from `checks` so a
    /// foreground's `checkAll` cannot start a check that would race the
    /// install and store "missing" half way through it.
    private var installing: Set<String> = []
    /// This run's answers that are not worth storing, by host key.
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
        let problem = problems[peer.hostKey]
        if checks[peer.hostKey] != nil {
            // A failed install's reason stays up while the host is asked
            // again; it is what the user needs to act on.
            if case .installFailed? = problem { return problem! }
            // An earlier "missing" stays on screen while it is asked again, so
            // a row does not flicker at every foreground.
            return peer.herdrCore == .missing ? .needsHerdrCore : .checking
        }
        if let problem { return problem }
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
    ///
    /// **Cancelling the caller cancels the check.** It runs in a task of its
    /// own so an install can wait on it, and an unstructured task does not
    /// inherit cancellation: without the handler, a list that went away left
    /// its check running, holding an SSH session on the host, and a phone
    /// suspended part way stored "Not reachable" for a host that was fine.
    public func check(_ peer: PairedPeer) async {
        let key = peer.hostKey
        guard canCheck, checks[key] == nil, !installing.contains(key) else { return }
        let task = Task { await self.ask(peer) }
        checks[key] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        checks[key] = nil
    }

    private func ask(_ peer: PairedPeer) async {
        guard let deviceKey = deviceKey(for: peer.hostKey) else { return }
        switch await HerdrCoreCheck.run(peer: peer, deviceKey: deviceKey, link: reachability.link) {
        case .answered(let herdrCore, let endpoint):
            record(herdrCore, reachedAt: endpoint, for: peer, unsaved: "the answer could not be saved")
        case .unreachable(let message):
            problems[peer.hostKey] = .unreachable(message)
        case .cancelled:
            // Nothing was learned; whatever was shown before stands.
            break
        }
    }

    /// Runs herdr-core's official installer on a host that answered
    /// "missing", then looks again. Does nothing while that host is being
    /// installed already, or on the watch.
    ///
    /// **A check in flight is waited for, not a reason to refuse.** The gate
    /// keeps showing "missing" while the host is asked again — at launch and
    /// at every return to the foreground — so Install is on screen during
    /// the check, and refusing made a tap in those seconds do nothing at
    /// all. Found driving the install end to end, 12 Nov 2026. The screen
    /// reads "Installing" from the tap; the check's answer decides whether
    /// the installer still runs.
    ///
    /// The caller is expected to have shown `HerdrCoreInstall.displayCommand`
    /// and had it confirmed: this runs a script from the network on someone's
    /// machine.
    ///
    /// **Not tied to the screen.** The gate starts it in a task of its own, so
    /// leaving the screen does not cancel an installer half way through on
    /// the host; the answer is recorded whenever it comes, and every screen
    /// showing the host reads it from here. **Nor, as far as iOS allows, to
    /// the foreground**: it asks for background time, since a suspended app's
    /// socket drops and takes the installer's channel with it.
    public func install(_ peer: PairedPeer) async {
        let key = peer.hostKey
        guard canCheck, !installing.contains(key) else { return }
        installing.insert(key)
        defer { installing.remove(key) }
        await checks[key]?.value

        // The stored record, not the one the screen held: the check may have
        // just found herdr-core (installed by hand), and then there is
        // nothing to run.
        guard let peer = peers.peers.first(where: { $0.hostKey == key }), peer.herdrCore == .missing,
              let deviceKey = deviceKey(for: key)
        else { return }

        let outcome = await withBackgroundTime("Installing herdr-core") {
            await HerdrCoreInstall.run(peer: peer, deviceKey: deviceKey, link: self.reachability.link)
        }
        switch outcome {
        case .installed(let herdrCore, let endpoint):
            record(herdrCore, reachedAt: endpoint, for: peer, unsaved: "herdr-core was installed, but the answer could not be saved")
        case .failed(let message):
            problems[key] = .installFailed(message)
        case .interrupted(let message):
            problems[key] = .installFailed(
                "the connection dropped while the installer was running (\(message)). It may not have finished; installing again finishes it."
            )
        case .unreachable(let message):
            problems[key] = .unreachable(message)
        case .cancelled:
            break
        }
    }

    // MARK: - Shared by the check and the install

    /// This device's key, or nil with the reason shown on the host. The
    /// phone's own keychain, not the host: "Not reachable" would send the
    /// user to look at the network.
    private func deviceKey(for key: String) -> SSHKeyPair? {
        do {
            return try peers.deviceKey()
        } catch {
            problems[key] = .failed("this device's key could not be read: \(error)")
            return nil
        }
    }

    /// Stores what the host said and settles this run's problem for it.
    private func record(_ herdrCore: HerdrCore, reachedAt endpoint: Endpoint, for peer: PairedPeer, unsaved: String) {
        do {
            try peers.recordHerdrCore(herdrCore, reachedAt: endpoint, for: peer)
            problems[peer.hostKey] = Self.problem(after: herdrCore, was: problems[peer.hostKey])
        } catch {
            problems[peer.hostKey] = .failed("\(unsaved): \(error)")
        }
    }

    /// What is left of a problem once the host has answered.
    ///
    /// **"Missing" does not clear a failed install.** The next foreground's
    /// check answers "missing" — of course it does — and wiping the
    /// installer's reason then put plain "Install herdr-core" back, inviting a
    /// retry of an install that cannot work (`hc: no build for armv7l`). Only
    /// herdr-core being found clears it.
    static func problem(after answer: HerdrCore, was problem: State?) -> State? {
        if answer.isInstalled { return nil }
        if case .installFailed? = problem { return problem }
        return nil
    }

    /// Runs `work` with iOS's leave to finish it in the background.
    ///
    /// A suspended app's socket drops, and with it the installer's channel
    /// part way through. The time iOS gives is enough for a download of a few
    /// megabytes; past it the install reads as interrupted. No-op elsewhere.
    private func withBackgroundTime<T>(_ name: String, _ work: () async -> T) async -> T {
        #if os(iOS)
        let application = UIApplication.shared
        let leave = BackgroundLeave()
        leave.identifier = application.beginBackgroundTask(withName: name) {
            // Out of time: give the leave back, as iOS requires. The
            // connection goes with the suspension and the install reports
            // itself interrupted.
            leave.end(in: application)
        }
        defer { leave.end(in: application) }
        #endif
        return await work()
    }
}

#if os(iOS)
/// The background task's identifier, shared by the expiration handler and the
/// normal end so whichever comes first ends it, once.
private final class BackgroundLeave {
    var identifier = UIBackgroundTaskIdentifier.invalid

    func end(in application: UIApplication) {
        guard identifier != .invalid else { return }
        application.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
