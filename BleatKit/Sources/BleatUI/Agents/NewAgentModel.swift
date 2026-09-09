import BleatKit
import Foundation
import Observation

/// Starting an agent in a pane, from the phone.
///
/// The third thing Bleat creates on someone's Mac, and the first that starts a
/// *program* rather than a container for one. It ends nothing — herdr refuses a
/// pane that already holds an agent, instantly — so like a workspace it needs
/// no ownership claim and no confirmation.
///
/// **What shapes this screen is that one failure is slow and ambiguous while
/// every other is instant and final.** Measured against herdr 0.9.0:
///
/// - a missing pane, a busy pane, a bad name, a taken name and a bad timeout
///   are all refused in under 30ms, before herdr types anything. The pane is
///   untouched and a retry is safe.
/// - a `timeout` is not a refusal. herdr types the executable and waits, so
///   when it gives up the agent may be booting still: a `claude` given 3.5s
///   against a 4.9s cold start timed out, and the pane then held a running,
///   detected claude with `name: null`.
///
/// So the fast refusals are simply reported, and a timeout is followed by
/// reading the host back — the same shape as `NewWorkspaceModel.settle`, and
/// the same reason `SessionStarter` polls `session list`.
@Observable
@MainActor
final class NewAgentModel {
    /// Bound to the field. Not `private(set)`: the text field owns it.
    var name = ""
    /// Defaulted to Claude Code, which is what a host running Herdr is most
    /// likely to have — and the only kind this app can be sure exists, since
    /// nothing here can see which binaries are installed.
    var kind: AgentKind = .claude
    /// The pane to start in. Nil until the panes have loaded and one is picked.
    var pane: String?

    private(set) var isStarting = false
    /// Nothing was started, and this is why. Safe to try again.
    private(set) var failure: String?
    /// **Something may be running in that pane now.** herdr stopped waiting,
    /// which is not the same as nothing having happened. Kept apart from
    /// `failure` because a retry would land on `agent_pane_busy` — over the
    /// agent the user was just told had not started.
    private(set) var warning: String?

    /// Panes with no agent in them, which are the only ones herdr will accept.
    private(set) var available: [Pane] = []
    /// Names already in use in this session. herdr refuses a duplicate.
    private(set) var takenNames: Set<String> = []
    private(set) var isLoadingPanes = false

    private let connections: ConnectionStore?
    private let session: String?
    /// nil means every pane in the session, which is what the agents screen
    /// shows when it is not narrowed to one workspace.
    private let workspace: String?

    init(connections: ConnectionStore, session: String?, workspace: String?) {
        self.connections = connections
        self.session = session
        self.workspace = workspace
    }

    #if DEBUG
    /// Parked, for `#Preview`: nothing dials and nothing is started.
    init(
        previewing name: String,
        kind: AgentKind = .claude,
        pane: String? = nil,
        available: [Pane] = [],
        takenNames: Set<String> = [],
        failure: String? = nil,
        warning: String? = nil,
        isStarting: Bool = false
    ) {
        self.connections = nil
        self.session = nil
        self.workspace = nil
        self.name = name
        self.kind = kind
        self.pane = pane
        self.available = available
        self.takenNames = takenNames
        self.failure = failure
        self.warning = warning
        self.isStarting = isStarting
    }
    #endif

    enum Outcome: Equatable {
        case started
        /// herdr stopped waiting. Something may be running in the pane; the
        /// screen stays up, because it is the only thing that will say so.
        case warned
        /// Nothing was started. Safe to try again.
        case failed
    }

    /// What is wrong with the name as typed, or nil.
    ///
    /// Nil while the field is empty as well as while it is valid: an empty
    /// field is the resting state, not an error to shout about.
    var nameProblem: String? {
        guard !name.isEmpty else { return nil }
        if let problem = AgentName.problem(with: name) { return problem.message }
        // herdr's own refusal, brought forward: `agent_name_taken`. Instant
        // either way, so this only saves a tap — but it is the same tap that
        // otherwise looks like the feature not working.
        if takenNames.contains(name) { return "There is already an agent called \(name) here." }
        return nil
    }

    var canStart: Bool {
        AgentName(name) != nil && !takenNames.contains(name)
            && pane != nil && !isStarting && warning == nil
    }

    /// A failure is about the attempt that produced it; left standing while the
    /// user edits the name it reads as a verdict on the new one.
    ///
    /// Deliberately does **not** clear `warning`, for the reason
    /// `NewWorkspaceModel.clearFailure` does not: that one says something may
    /// be running on the host, which editing a text field does not undo.
    func clearFailure() { failure = nil }

    /// Back to an empty form, called when the sheet is opened.
    ///
    /// The model is `@State` on the screen rather than on the sheet, so
    /// everything it holds outlives a dismissal — see `NewWorkspaceModel.reset`
    /// for the bug that taught this.
    func reset() {
        name = ""
        kind = .claude
        pane = nil
        failure = nil
        warning = nil
    }

    /// The panes that can take an agent, and the names that are spoken for.
    ///
    /// **Occupancy comes from `agent list`, not from a pane's own fields.**
    /// Both lists are the host's, and the agent list is the one that decides:
    /// a pane holds an agent exactly when a row names it. It also carries the
    /// names, so one pass answers both questions the form needs.
    ///
    /// It cannot see a pane merely *busy* with an ordinary command — herdr
    /// refuses those too, with `agent_pane_busy`, and there is no field for it.
    /// That refusal is instant, so it is a tap wasted rather than a wait.
    func loadPanes(for peer: PairedPeer) async {
        guard let connections else { return }
        isLoadingPanes = true
        defer { isLoadingPanes = false }
        do {
            let client = try await connections.client(for: peer, session: session)
            let agents = try await client.agents()
            let panes = try await client.panes()

            let occupied = Set(agents.map(\.paneID))
            takenNames = Set(agents.compactMap(\.name))
            available = panes
                .filter { !occupied.contains($0.paneID) }
                .filter { workspace == nil || $0.workspaceID == workspace }
            // Picking the only candidate is not a decision the user has to be
            // asked to make; leaving it unselected is a tap for nothing.
            if pane == nil, available.count == 1 { pane = available.first?.paneID }
        } catch {
            // Released rather than swallowed, for the reason
            // `NewWorkspaceModel.loadSuggestions` does it: this is the first
            // thing the sheet does, so a dead connection surfaces here, and
            // leaving it installed spends the user's next action on the same
            // discovery.
            await connections.handle(error)
            failure = ErrorMessage.failure(of: error).message
        }
    }

    /// Starts the agent, and works out what a failure meant.
    func start(on peer: PairedPeer) async -> Outcome {
        guard let connections, let agentName = AgentName(name), let target = pane, !isStarting
        else { return .failed }
        isStarting = true
        failure = nil
        defer { isStarting = false }

        do {
            let client = try await connections.client(for: peer, session: session)
            _ = try await client.startAgent(named: agentName, kind: kind, pane: target)
            return .started
        } catch {
            await connections.handle(error)
            guard AgentStart.isUnknownOutcome(error) else {
                // Refused before anything was typed: the pane is untouched, so
                // say what herdr said and leave the button armed.
                failure = ErrorMessage.failure(of: error).message
                return .failed
            }
            return await settle(in: target, on: peer)
        }
    }

    /// What to say when herdr stopped waiting.
    ///
    /// Three answers, and only the middle one is a plain failure:
    ///
    /// - the pane now holds an agent — it started late, and herdr never
    ///   recorded the name. Nothing to retry; say so.
    /// - the pane holds nothing — the agent never came up, and the pane itself
    ///   is where the reason is written. Safe to try again.
    /// - the host cannot be asked — genuinely unknown, which must disarm.
    private func settle(in target: String, on peer: PairedPeer) async -> Outcome {
        guard let connections,
              let client = try? await connections.client(for: peer, session: session),
              let agents = try? await client.agents()
        else {
            warning = "herdr stopped waiting for \(kind.label) to start, and the host could not "
                + "be asked what happened. Pull the list down to see whether it came up."
            return .warned
        }

        if let landed = agents.first(where: { $0.paneID == target }) {
            warning = "\(landed.agent ?? kind.label) is running in \(target), but it took longer "
                + "than herdr waited — so it has no name. It will show in the list without one."
            return .warned
        }

        // Nothing in the pane, so nothing started and the pane is free again.
        // **The pane is the only place the cause is written**: herdr's own
        // answer is "timed out waiting for agent startup", which names nothing,
        // while the pane holds the shell's own complaint.
        let lines = (try? await client.paneText(target: target, lines: 40)) ?? []
        if let cause = AgentStart.diagnosis(inPane: lines, kind: kind) {
            failure = cause
        } else {
            failure = "\(kind.label) did not start in \(target) within 30 seconds."
        }
        return .failed
    }
}
