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
        /// Brings a stopped session back up, with the workspaces it had —
        /// herdr keeps the session directory, so this resumes rather than
        /// recreates. The only one of the three that is not destructive, and
        /// the only one that does not ask first.
        case start
        /// Ends every process in the session. Offered only while it runs.
        case stop
        /// Removes the stopped session and its directory. herdr refuses this
        /// while the session runs, so it is the second of two steps.
        case delete

        /// The verb, used on the swipe, the bar and the dialog's button — one
        /// definition, so a dialog cannot end up asking about a different verb
        /// from the one the user tapped.
        var title: String {
            switch self {
            case .start: "Start"
            case .stop: "Stop"
            case .delete: "Delete"
            }
        }

        var symbol: String {
            switch self {
            case .start: "play.fill"
            case .stop: "stop.fill"
            case .delete: "trash"
            }
        }
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

    /// What to do once something has actually happened: refresh the list, or
    /// leave a screen whose session has just been deleted. Installed by
    /// `SessionControlFlow`.
    ///
    /// **Held here, and called by `perform` itself, because there is more than
    /// one way an action starts and the second one was missed.** The reload
    /// used to hang off the confirmation dialog's button — which meant the one
    /// action that raises no dialog, Start, ran to completion and left the
    /// screen showing the session as stopped. It worked; nothing said so, and
    /// the only way to see it was to go back and come in again. Any caller of
    /// `perform` now gets the same ending.
    var onCompleted: ((Action) async -> Void)?

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
        // **Stop is the guarded one, and it is guarded on `startedHere` rather
        // than on who created the session.** The rule is that the phone may
        // undo what it did: a session it started, it may stop. One that is
        // running because somebody is using it has no Stop, which is the whole
        // point.
        guard !session.running else {
            return peer.startedHere(session.name) ? [.stop] : []
        }
        // **Start is offered for anyone's stopped session.** It restores rather
        // than creates — measured: the workspaces, panes and a fresh shell in
        // each come back at their recorded cwd — so it ends nothing, and it is
        // the only way back when the Mac has rebooted with nothing up, which is
        // the gap CLAUDE.md names. It is also first in the list, so it is what
        // a full swipe reaches: the harmless one.
        //
        // Delete is not, because it removes the session *directory* — for a
        // session somebody else set up, that is their layout and not ours to
        // throw away.
        return peer.createdHere(session.name) ? [.start, .delete] : [.start]
    }

    /// Whether this action must be confirmed before it runs.
    ///
    /// Starting is not: it creates a session that is empty of anyone's work,
    /// and the way back from an unwanted one is the Stop button beside it.
    /// Stopping and deleting both end things that cannot be brought back.
    static func needsConfirmation(_ action: Action) -> Bool { action != .start }

    func ask(_ action: Action, about session: SessionInfo) {
        phase = .confirming(action, session)
    }

    /// The one entry point a button needs: asks first where asking is owed, and
    /// otherwise just does it.
    ///
    /// Kept here rather than written out at each call site so a new action
    /// cannot be added to a bar or a swipe without the question of whether it
    /// needs confirming being answered in one place.
    func begin(_ action: Action, about session: SessionInfo, on peer: PairedPeer) {
        guard Self.needsConfirmation(action) else {
            Task { await perform(action, about: session, on: peer) }
            return
        }
        ask(action, about: session)
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

    /// Carries out `action`. Returns true if the host's list agrees it
    /// happened, so the caller can refresh.
    ///
    /// **The action and session are parameters, not read back out of `phase`,
    /// and that is the whole reason this signature looks redundant.** SwiftUI
    /// sets a `confirmationDialog`'s binding to false *before* running the
    /// tapped button's action, and this model's `isConfirming` setter resets
    /// `phase` to `.idle` on that write — so a version that re-read `phase`
    /// here found nothing armed and returned without doing anything at all.
    /// No error, no alert; Stop simply did nothing and the session stayed up.
    /// `UnpairFlow` carries a comment about this exact hazard, which this code
    /// walked into anyway. The caller captures the values when it builds the
    /// dialog; see `SessionControlFlow`.
    @discardableResult
    func perform(_ action: Action, about session: SessionInfo, on peer: PairedPeer) async -> Bool {
        // **One at a time.** `begin` starts an unstructured task, so two quick
        // taps enqueue two of these; nothing between here and `phase =
        // .working` below suspends, and the main actor runs them in turn, so
        // the second sees the first's claim. Without it a double tap launches
        // two `herdr server`s sharing one truncating log, or raises a failure
        // alert over a stop that had already succeeded. `NewSessionModel.start`
        // has had this guard from the beginning.
        guard !isWorking else { return false }
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
            // Starting is checked by the launcher itself, which has to poll:
            // the launch is detached and its exit status says nothing.
            if action == .start {
                switch try await SessionStarter.start(
                    // Which claims this earns is settled by the starter, off
                    // what the host said before the launch — not by this call
                    // site, which cannot know.
                    name, on: peer, connections: connections, peers: peers
                ) {
                case .started:
                    phase = .idle
                    await onCompleted?(action)
                    return true
                case .failed(let why): phase = .failed(action, session, why); return false
                }
            }

            // Session-agnostic: `session stop` and `session delete` name their
            // session as an argument, so the prefix is irrelevant to them — and
            // setting it would clear the one a workspaces list on the same
            // screen is reading.
            let client = try await connections.sessionAgnosticClient(for: peer)
            switch action {
            case .stop: try await client.stopSession(named: name)
            case .delete: try await client.deleteSession(named: name)
            case .start: break // handled above
            }

            // The reply is not the answer — `deleted: true` comes back for a
            // session that never existed. The list is.
            let sessions = try await client.sessions()
            let after = sessions.first { $0.name == name.text }
            let done = switch action {
            case .stop: after?.running == false
            case .delete: after == nil
            case .start: after?.running == true
            }

            guard done else {
                phase = .failed(action, session, notDone(action, name.text))
                return false
            }
            switch action {
            // The session is gone, so both claims on the name stop being true —
            // and a later session of that name, made at the Mac, must not
            // inherit these actions.
            case .delete: peers?.forgetCreatedSession(name.text, for: peer)
            // "This phone is why it is running" expires the moment it is not.
            // Without this, starting and stopping the user's own session from
            // the phone would leave a standing Stop button over whatever they
            // started next.
            case .stop: peers?.forgetStartedSession(name.text, for: peer)
            case .start: break // recorded by the starter, once the host agreed
            }
            phase = .idle
            await onCompleted?(action)
            return true
        } catch {
            await connections.handle(error)
            phase = .failed(action, session, ErrorMessage.failure(of: error).message)
            return false
        }
    }

    private func notDone(_ action: Action, _ name: String) -> String {
        switch action {
        case .start: "The host did not report \(name) as running."
        case .stop: "The host still reports \(name) as running."
        case .delete: "\(name) is still on the host."
        }
    }

    /// Whether this action is in flight, so a bar can show a spinner and
    /// refuse a second tap.
    var isWorking: Bool { if case .working = phase { true } else { false } }
}
