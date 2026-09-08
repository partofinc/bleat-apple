import BleatKit
import Foundation
import Observation

/// Stopping and deleting a session, for the sessions this phone started.
///
/// **The most destructive thing Bleat does, and the only one that ends work
/// nobody asked about.** Unpairing takes away this phone's access; stopping a
/// session takes away *the host's processes*. Measured against herdr 0.9.0: a
/// session with one pane was stopped and its shell — pid and all — was gone a
/// second later. On a session holding agents that is their work ending, with
/// no undo and nothing on the Mac to say who did it.
///
/// Three things stand between that and a swipe, and all three are needed:
///
/// - **Only sessions this phone created.** `PairedPeer.createdHere` is checked
///   before the actions are offered at all, so the `work` session someone is
///   sitting in front of has no swipe. The claim is only ever what this install
///   remembers doing — a reinstall forgets, and then offers nothing, which is
///   the safe direction.
/// - **A swipe asks; it does not act.** The same rule as unpairing a peer. A
///   full swipe reaching a confirmation is survivable; one reaching `session
///   stop` is not.
/// - **The result is checked, not assumed.** `deleted: true` comes back for a
///   session that never existed — see `SessionChange` — so the list is read
///   again and the answer is whether the name is really gone.
@Observable
@MainActor
final class SessionControlModel {
    enum Action: Hashable {
        /// Ends every process in the session. Offered only while it runs.
        case stop
        /// Removes the stopped session and its directory. herdr refuses this
        /// while the session runs, so it is the second of two steps.
        case delete
    }

    enum Phase: Equatable {
        case idle
        /// Asked, not yet done.
        case confirming(Action, SessionInfo)
        case working(Action, SessionInfo)
        /// It did not happen, and this is the host's own account of why.
        case failed(Action, SessionInfo, String)
    }

    private(set) var phase: Phase = .idle

    private let connections: ConnectionStore?
    private let peers: PeerStore?

    init(connections: ConnectionStore, peers: PeerStore) {
        self.connections = connections
        self.peers = peers
    }

    #if DEBUG
    /// Parked in one phase, for `#Preview`. Nothing dials.
    init(previewing phase: Phase) {
        self.connections = nil
        self.peers = nil
        self.phase = phase
    }
    #endif

    /// What may be offered for a row, in the order the swipe shows them.
    ///
    /// Empty for a session this phone did not start — which is the whole guard
    /// — and never both at once: herdr refuses to delete a running session, so
    /// offering Delete there would be an action that has already failed before
    /// it is taken.
    static func actions(for session: SessionInfo, on peer: PairedPeer) -> [Action] {
        guard peer.createdHere(session.name) else { return [] }
        return session.running ? [.stop] : [.delete]
    }

    func ask(_ action: Action, about session: SessionInfo) {
        phase = .confirming(action, session)
    }

    /// Bound by the confirmation dialog, which SwiftUI dismisses itself — the
    /// model has to hear about a tap outside as much as about a button.
    var isConfirming: Bool {
        get { if case .confirming = phase { true } else { false } }
        set { if !newValue, case .confirming = phase { phase = .idle } }
    }

    var isShowingFailure: Bool {
        get { if case .failed = phase { true } else { false } }
        set { if !newValue, case .failed = phase { phase = .idle } }
    }

    var pending: (action: Action, session: SessionInfo)? {
        switch phase {
        case .confirming(let action, let session),
             .working(let action, let session),
             .failed(let action, let session, _): (action, session)
        case .idle: nil
        }
    }

    var failureMessage: String? {
        if case .failed(_, _, let message) = phase { message } else { nil }
    }

    /// Carries out what was confirmed. Returns true if the host's list agrees
    /// it happened, so the caller can refresh.
    func confirm(on peer: PairedPeer) async -> Bool {
        guard case .confirming(let action, let session) = phase else { return false }
        guard let connections, let name = SessionName(session.name) else {
            // Unreachable from a row this phone created — `SessionName` is what
            // minted it — but a name herdr accepted and this build will not is
            // better refused than sent as a positional argument it would parse
            // as a flag.
            phase = .failed(action, session, "\(session.name) is not a name this app can act on.")
            return false
        }
        phase = .working(action, session)

        do {
            let client = try await connections.client(for: peer, session: nil)
            switch action {
            case .stop: try await client.stopSession(named: name)
            case .delete: try await client.deleteSession(named: name)
            }

            // The reply is not the answer — `deleted: true` comes back for a
            // session that never existed. The list is.
            let sessions = try await client.sessions()
            let after = sessions.first { $0.name == name.text }
            let done = switch action {
            case .stop: after?.running == false
            case .delete: after == nil
            }

            guard done else {
                phase = .failed(action, session, notDone(action, name.text))
                return false
            }
            // Only on delete: the session is gone, so the claim that this phone
            // created it stops being true — and a later session of that name,
            // made at the Mac, must not inherit these actions.
            if action == .delete { peers?.forgetCreatedSession(name.text, for: peer) }
            phase = .idle
            return true
        } catch {
            await connections.handle(error)
            phase = .failed(action, session, ErrorMessage.failure(of: error).message)
            return false
        }
    }

    private func notDone(_ action: Action, _ name: String) -> String {
        switch action {
        case .stop: "The host still reports \(name) as running."
        case .delete: "\(name) is still on the host."
        }
    }
}
