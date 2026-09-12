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
    /// Whether the host has actually answered about its panes.
    ///
    /// An empty `available` means two very different things — "every pane is
    /// taken" and "we never found out" — and the form says the first out loud.
    /// Without this it says it over the top of its own connection error, which
    /// is a confident claim about a host that could not be reached.
    private(set) var hasLoadedPanes = false
    /// Adding a tab, which is how another pane is obtained. See `addPane`.
    private(set) var isAddingPane = false
    /// Where a new pane would open: the directory this workspace's panes are
    /// in, which a new tab inherits. Shown before the tap, per the rule
    /// CLAUDE.md sets for creating panes.
    private(set) var workspaceDirectory: String?

    /// Whether an agent started here will be able to read the login keychain.
    ///
    /// A session whose server was started over SSH — which is every session
    /// this phone has started — puts its panes in a different macOS audit
    /// session, and an agent there cannot reach the credentials it signs in
    /// with. Worth saying *before* the tap: the failure otherwise costs a
    /// 30-second `agent start`, and the agent that comes up looks healthy while
    /// being unable to do anything. See `SecuritySession`.
    ///
    /// `.unknown` until the host has answered, and the form shows nothing for
    /// it — a diagnosis nobody asked for must not be guessed at.
    private(set) var keychainReach: SecuritySession.Reach = .unknown

    /// A pane of this session, used only to ask which audit session its panes
    /// are in. Any of them answers; see `loadPanes`.
    private var probePane: String?

    private let connections: ConnectionStore?
    private let session: String?
    /// nil means every pane in the session, which is what the agents screen
    /// shows when it is not narrowed to one workspace.
    private let workspace: String?

    /// The workspace a new tab would join, when there is one.
    var addTo: String? {
        #if DEBUG
        workspace ?? previewWorkspace
        #else
        workspace
        #endif
    }

    #if DEBUG
    /// Preview-only override, because `workspace` is otherwise set only by the
    /// screen. Without it a parked model can never show the "add a pane"
    /// affordance, and the previews for the state that most needs looking at —
    /// no free panes — would show the dead end rather than the way out.
    private var previewWorkspace: String?
    #endif

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
        workspace: String? = nil,
        available: [Pane] = [],
        takenNames: Set<String> = [],
        workspaceDirectory: String? = nil,
        hasLoadedPanes: Bool = true,
        failure: String? = nil,
        warning: String? = nil,
        isStarting: Bool = false,
        isAddingPane: Bool = false,
        keychainReach: SecuritySession.Reach = .unknown
    ) {
        self.connections = nil
        self.session = nil
        self.workspace = nil
        self.previewWorkspace = workspace
        self.name = name
        self.kind = kind
        self.pane = pane
        self.available = available
        self.takenNames = takenNames
        self.workspaceDirectory = workspaceDirectory
        self.hasLoadedPanes = hasLoadedPanes
        self.failure = failure
        self.warning = warning
        self.isStarting = isStarting
        self.isAddingPane = isAddingPane
        self.keychainReach = keychainReach
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
            && pane != nil && !isStarting && !isAddingPane && warning == nil
    }

    /// Whether another pane can be asked for.
    ///
    /// **Only when the screen is inside one workspace.** A tab belongs to a
    /// workspace, and the session-wide agents list is not in one — there would
    /// be no honest answer to which workspace the pane should join, and
    /// guessing puts a pane in somebody's project.
    var canAddPane: Bool { addTo != nil && !isAddingPane && !isStarting && warning == nil }

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

    /// Adds a tab to this workspace, and selects the pane it brings.
    ///
    /// **This is the way out of the dead end this screen otherwise has.** A
    /// workspace made from the phone holds exactly one pane; one agent fills
    /// it; and then there is nothing to start a second agent in. Measured on
    /// the dev Mac, every workspace in the live `work` session has one pane and
    /// every one of them is occupied — so "add a workspace to get another pane"
    /// is true and useless.
    ///
    /// **A tab, not a `pane split`.** Both give a pane an agent can start in
    /// immediately, but measured in a 120-column session a split pane is 60
    /// columns wide against a tab's 120 — and a narrow grid is exactly what
    /// this codebase spends pages on, because the program wraps to its pty and
    /// no client can reflow it. A split also narrows the pane it came from,
    /// which belongs to whoever is at the Mac.
    ///
    /// The new pane is selected, because asking for a pane and then having to
    /// find it in a list is a step that exists for no reason.
    func addPane(for peer: PairedPeer) async {
        guard let connections, let workspace = addTo, !isAddingPane else { return }
        isAddingPane = true
        failure = nil
        defer { isAddingPane = false }
        do {
            let client = try await connections.client(for: peer, session: session)
            let created = try await client.createTab(inWorkspace: workspace)
            await loadPanes(for: peer)
            // **Matched on the new tab, never on "whichever sorts last".** The
            // fallback here fires exactly when `TabCreated` dropped a malformed
            // `root_pane`, and in a workspace that already had a free pane
            // `available.last` is some *pre-existing* pane — which the form
            // would then silently aim at, possibly a shell somebody at the Mac
            // is using, since `agent list` cannot see a pane merely busy. The
            // tab id is required and did decode, so it identifies the newcomer
            // exactly.
            pane = created.rootPane?.paneID
                ?? available.first { $0.tabID == created.tab.tabID }?.paneID
        } catch {
            await connections.handle(error)
            failure = ErrorMessage.failure(of: error).message
        }
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
            hasLoadedPanes = true
            let mine = panes.filter { workspace == nil || $0.workspaceID == workspace }
            available = mine.filter { !occupied.contains($0.paneID) }
            // What a new tab would inherit — the workspace's own directory,
            // which its panes are the only record of here.
            workspaceDirectory = mine.compactMap(\.cwd).first
            // Any pane of this session will do: they are all children of the
            // one server, so they share its audit session. Deliberately taken
            // from `mine` rather than `available`, because a session whose
            // every pane is occupied is exactly when the user is about to add
            // a tab and start an agent in it.
            probePane = mine.first?.paneID
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

    /// Asks whether this session's panes share the Mac's login session.
    ///
    /// Run after `loadPanes` rather than inside it, so the pane list — which is
    /// what the user came here for — is not held up behind a diagnostic.
    ///
    /// **Failures are swallowed, which is the opposite of the rule elsewhere in
    /// this model, and deliberately.** `loadPanes` runs first and reports a
    /// dead connection itself, so there is nothing here the user has not
    /// already been told; and releasing the connection over a *diagnosis* would
    /// spend the handshake the user's actual next action needs. An unanswered
    /// probe stays `.unknown`, which shows nothing.
    func checkKeychainReach(for peer: PairedPeer) async {
        guard let connections, let target = probePane else { return }
        do {
            let client = try await connections.client(for: peer, session: session)
            guard let pid = try await client.paneProcessInfo(target: target).shellPID,
                  let command = SecuritySession.command(paneShellPid: pid)
            else { return }
            // Plain shell, not a herdr command: this asks launchd about a
            // process, which has nothing to do with sessions. `shell` leaves
            // `useSession` alone for exactly that reason.
            let shell = try await connections.shell(for: peer)
            let answer = try await shell.run(shell: command)
            keychainReach = SecuritySession(inOutput: answer).reach
        } catch {
            keychainReach = .unknown
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
            guard AgentStart.isRefusalBeforeTyping(error) else {
                // **Anything that is not herdr refusing has to be checked.**
                // This call blocks on the host for up to thirty seconds while
                // herdr types the executable in — so a dropped connection or a
                // reply this build could not read says nothing about whether
                // the command ran, and an agent may be in that pane. An earlier
                // version asked "was it a timeout" instead, which sent exactly
                // those two cases back to the user as "nothing happened, try
                // again" — and the retry lands on `agent_pane_busy` over an
                // agent nobody named.
                return await settle(in: target, on: peer)
            }
            // herdr answered, before it typed anything: the pane is untouched,
            // so say what it said and leave the button armed.
            failure = ErrorMessage.failure(of: error).message
            return .failed
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
              let client = try? await connections.client(for: peer, session: session)
        else {
            warning = unknownMessage
            return .warned
        }

        // **Polled, not read once, and the reason is what timed out.** herdr
        // gave up waiting for *its own detection*, so an agent whose binary is
        // up but not yet recognised is absent from `agent list` at this instant
        // — and reading once would report "it did not start" about a pane that
        // is filling up as we ask. Every other write in this app that reads
        // back polls; `SessionStarter` does the same over `session list`.
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(700)) }
            guard let agents = try? await client.agents() else {
                warning = unknownMessage
                return .warned
            }
            if let landed = agents.first(where: { $0.paneID == target }) {
                warning = "\(landed.agent ?? kind.label) is running in \(target), but it took "
                    + "longer than herdr waited — so it has no name. It will show in the list "
                    + "without one."
                return .warned
            }
        }

        // Nothing has appeared in the pane after several seconds, so nothing
        // started and the pane is free again.
        //
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

    private var unknownMessage: String {
        "herdr stopped waiting for \(kind.label) to start, and the host could not be asked what "
            + "happened. Pull the list down to see whether it came up."
    }
}
