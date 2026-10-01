import BleatKit
import SwiftUI

/// What is running in one workspace: the agents, blocked first, and the panes
/// herdr has not recognised an agent in — the plain shells.
///
/// This is the list the whole app is organised around. `agent list` needs no
/// join — each row already carries its pane, workspace and working directory —
/// and `HerdrClient.agents()` has already sorted it by attention, so the
/// ordering the user sees is the one the client and the console tool agree on
/// rather than a rule restated here.
///
/// **`pane list` is asked for as well, and it is not redundant.** A pane is a
/// plain shell until herdr recognises an agent in it, and such a pane is
/// invisible to `agent list` — so before this the phone could create a terminal
/// (the "Add a pane" inside the agent sheet does exactly that) and then have no
/// way back to it. Two commands, serially on the one connection, for the reason
/// `EndpointDiscovery` runs its probes serially: `SSHTransport` wraps a Citadel
/// client that is not `Sendable`-audited and is lock-guarded for it.
struct AgentsView: View {
    @Environment(AppContext.self) private var context
    let peer: PairedPeer
    let session: String?
    /// nil means everything in the session, which is what the host answers
    /// with. A workspace narrows it.
    let workspace: String?
    /// The workspace's label. Its id is opaque — `w2` and `w653998617a6031`
    /// both occur — and belongs in a subtitle at most, never in a title bar.
    let title: String
    @State private var entries: RemoteList<WorkspaceEntry>
    /// Owned here rather than by the sheet, so a start survives the sheet being
    /// dismissed on top of it — herdr can take half a minute, and the reply is
    /// what says whether something is now running on someone's Mac.
    @State private var newAgent: NewAgentModel
    @State private var newTerminal: NewTerminalModel
    @State private var isStarting = false
    /// The pane a blocked agent is waiting in, held until the sheet has gone.
    @State private var paneToAnswer: String?

    init(
        peer: PairedPeer,
        session: String?,
        workspace: String?,
        title: String,
        connections: ConnectionStore
    ) {
        self.peer = peer
        self.session = session
        self.workspace = workspace
        self.title = title
        _entries = State(wrappedValue: RemoteList(connections: connections, session: session) {
            let agents = try await $0.agents()
            // **The second list may fail without taking the first with it —
            // but only while there is a first to protect.** A `HerdrError` or
            // a `DecodingError` is this host declining to describe its panes,
            // and losing the terminals is not worth losing the agents this
            // screen exists for; that is the rule `PaneModel.paneSize` already
            // states. A `TransportError` propagates either way, because that is
            // the connection rather than the command.
            //
            // **With no agents to keep, the failure is reported rather than
            // swallowed**, and that clause is the whole of the difference
            // between honest and confidently wrong. Silence there draws
            // "nothing is running here" over a workspace that may be full of
            // live shells — and `openTerminal`'s answer to a create it could
            // not confirm is "whatever landed is in the list", which an empty
            // list quietly contradicts, inviting the retry that makes a second
            // tab.
            let panes: [Pane]
            do {
                panes = try await $0.panes()
            } catch is HerdrError where !agents.isEmpty {
                panes = []
            } catch is DecodingError where !agents.isEmpty {
                panes = []
            }
            // **Occupancy is judged against every agent in the session, not
            // just this workspace's.** They are the same set here — an agent
            // is in the workspace its pane is — and asking the whole list
            // cannot be wrong, while a filtered one could offer an occupied
            // pane as a free terminal if a row ever disagreed.
            let mine = agents.filter { workspace == nil || $0.workspaceID == workspace }
            let terminals = panes
                .filter { workspace == nil || $0.workspaceID == workspace }
                .withoutAgents(in: agents)
            return mine.map(WorkspaceEntry.agent) + terminals.map(WorkspaceEntry.terminal)
        })
        _newAgent = State(wrappedValue: NewAgentModel(
            connections: connections, session: session, workspace: workspace
        ))
        _newTerminal = State(wrappedValue: NewTerminalModel(
            connections: connections, session: session
        ))
    }

    #if DEBUG
    /// Preview-only: the rows are handed in and nothing is fetched.
    ///
    /// Agents and terminals are taken separately because that is how a preview
    /// reads — the states worth looking at are "agents but no shells", "shells
    /// but no agents" and both at once.
    init(
        peer: PairedPeer,
        session: String?,
        workspace: String?,
        title: String,
        previewing state: Loadable<[Agent]>,
        terminals: [Pane] = []
    ) {
        self.peer = peer
        self.session = session
        self.workspace = workspace
        self.title = title
        let rows = terminals.map(WorkspaceEntry.terminal)
        let combined: Loadable<[WorkspaceEntry]> = switch state {
        case .loading: .loading
        case .loaded(let agents): .loaded(agents.map(WorkspaceEntry.agent) + rows)
        case .failed(let failure): .failed(failure)
        case .stale(let agents, let failure): .stale(agents.map(WorkspaceEntry.agent) + rows, failure)
        }
        _entries = State(wrappedValue: RemoteList(previewing: combined))
        _newAgent = State(wrappedValue: NewAgentModel(previewing: ""))
        _newTerminal = State(wrappedValue: NewTerminalModel(previewing: nil))
    }
    #endif

    var body: some View {
        @Bindable var newTerminal = newTerminal
        return RemoteListView(
            state: entries.state,
            // Named for what this screen can actually do. The session-wide
            // list has no plus for a terminal — a tab belongs to a workspace —
            // so telling that one to open a terminal is advice it refuses to
            // take.
            empty: workspace == nil
                ? "Nothing is running in this session. Open a workspace to start something in it."
                : "Nothing is running here. Open a terminal, or start an agent in one.",
            retry: { await load() }
        ) { list in
            // Each section is drawn only when it has rows: a heading over
            // nothing reads as a list that failed to load its other half.
            let agents = list.compactMap(\.agent)
            let terminals = list.compactMap(\.terminal)
            if !agents.isEmpty {
                Section("Agents") {
                    ForEach(agents) { agent in
                        AgentLink(peer: peer, session: session, agent: agent)
                    }
                }
            }
            if !terminals.isEmpty {
                Section("Terminals") {
                    ForEach(terminals) { pane in
                        TerminalLink(peer: peer, session: session, pane: pane)
                    }
                }
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .toolbar {
            // Nothing to the left of it, and the spacer is there anyway: it is
            // what puts the plus on the trailing side, where every other
            // screen has it.
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                // **A menu only where it has two things in it.** A tab belongs
                // to a workspace, so the session-wide list cannot make a
                // terminal — and a menu of one item is the old button with an
                // extra tap in front of it.
                if let workspace {
                    Menu {
                        Button("New Terminal", systemImage: "terminal") {
                            openTerminal(in: workspace)
                        }
                        .disabled(newTerminal.isCreating)
                        Button("Start Agent…", systemImage: "sparkles") {
                            // A whole reset, not just the failure: the model
                            // outlives the sheet. See `NewWorkspaceModel.reset`.
                            newAgent.reset()
                            isStarting = true
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.glassProminent)
                } else {
                    Button("Start Agent", systemImage: "plus") {
                        newAgent.reset()
                        isStarting = true
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
        // A terminal is one command with no sheet of its own, so anything worth
        // reading has nowhere else to go. `SessionControlFlow` uses an alert
        // for the same reason — and the title comes from the notice, because
        // "that did not happen" is a lie about the tab that was created out of
        // a reply that did not name its pane.
        .alert(
            newTerminal.notice?.title ?? "",
            isPresented: $newTerminal.isShowingNotice,
            presenting: newTerminal.notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        // **The pane is opened from `onDismiss`, not from inside the sheet.**
        // SwiftUI will not act on a navigation raised by a view that is on its
        // way out — the same hazard `PeerSettingsFlow` records for a
        // confirmation dialog presented underneath a sheet, where the dialog was
        // simply never seen. So the sheet asks, this holds the request, and the
        // push happens once the dismissal has finished. Cleared as it is taken,
        // or a later dismissal would open a pane nobody asked about.
        .sheet(isPresented: $isStarting, onDismiss: {
            guard let target = paneToAnswer else { return }
            paneToAnswer = nil
            // **Terminal, not chat.** The button that asked for this said it
            // opens the pane so the dialog can be answered, and a transcript —
            // most likely an empty one, for an agent that has not got past its
            // trust prompt — is the opposite of that.
            context.navigation.push(.pane(
                peer: peer.hostKey, session: session, target: target, title: target,
                mode: .terminal
            ))
        }) {
            NewAgentForm(
                model: newAgent,
                peer: peer,
                onStarted: { Task { await entries.load(for: peer) } },
                onAnswer: { paneToAnswer = $0 }
            )
        }
        // Stands aside for a `bleat://` link — but not mid-start, or a
        // thirty-second start's outcome would have nowhere to be reported. See
        // `PairingYield`.
        .yieldsToPairing(whileBusy: newAgent.isStarting || newAgent.isAddingPane,
                         presenting: $isStarting)
        #endif
        .hostLoadBar(for: peer)
        .refreshable { await load(force: true) }
        .task { await load() }
    }

    /// The rows, then how busy the host is — last, because that is read only
    /// over a connection the rows have already brought up.
    ///
    /// - Parameter force: a pull-to-refresh, which reads the load again even
    ///   if the last reading is seconds old.
    private func load(force: Bool = false) async {
        await entries.load(for: peer)
        await context.hostLoad.refresh(for: peer, force: force)
    }

    #if os(iOS)
    /// Adds a tab to this workspace and opens the shell it brings.
    ///
    /// **The list is reloaded on both paths, and that is the failure path's
    /// whole answer.** A create that threw is not proof that nothing happened:
    /// a connection dropping after herdr ran the command leaves the tab there,
    /// and a plain "that did not happen" invites the retry that makes a second
    /// one. Reloading puts whatever really landed on screen under Terminals,
    /// where it can be opened — or left alone — rather than being invisible.
    ///
    /// The push is straight from the button, not from an `onDismiss`: a menu
    /// has already gone by the time its action runs, so there is no view on its
    /// way out for the navigation to be swallowed by.
    ///
    /// **The pane is pushed before the list is reloaded**, and the order is the
    /// whole of the feedback. A reload keeps the rows it has and draws no
    /// spinner, so reloading first leaves the tap with nothing to show for
    /// itself for a `tab create` plus two list commands — and then navigates on
    /// its own, at a moment the user has stopped expecting it, possibly from a
    /// screen they have since left.
    private func openTerminal(in workspace: String) {
        Task {
            let pane = await newTerminal.create(in: workspace, for: peer)
            if let pane {
                context.navigation.push(.pane(
                    peer: peer.hostKey, session: session, target: pane.target,
                    title: pane.displayTitle, mode: .terminal
                ))
            }
            // After the push, and on the refusal path too: a create that threw
            // is not proof that nothing happened, so whatever really landed is
            // listed rather than invisible behind a retry that would make a
            // second one.
            //
            // It does mean this reload runs while the pane it just opened is
            // streaming, and a `TransportError` here releases the connection
            // under that stream. The pane says so and offers a retry, which is
            // the cheaper failure: reloading first instead leaves every tap
            // with nothing to show for itself until it suddenly navigates.
            await entries.load(for: peer)
        }
    }
    #endif
}

#if DEBUG
#Preview("Agents", traits: .sampleData) {
    NavigationStack {
        AgentsView(
            peer: .preview, session: "work", workspace: "w2", title: "bleat-apple",
            previewing: .loaded(Agent.samples)
        )
    }
}

/// Both kinds, which is the only case that draws the headings.
#Preview("Agents and terminals", traits: .sampleData) {
    NavigationStack {
        AgentsView(
            peer: .preview, session: "work", workspace: "w2", title: "bleat-apple",
            previewing: .loaded(Agent.samples), terminals: Pane.samples
        )
    }
}

/// What a workspace the phone has just made looks like: shells, no agents.
/// Before terminals were listed this screen said "no agents are running here"
/// over panes that were running perfectly well.
#Preview("Terminals only", traits: .sampleData) {
    NavigationStack {
        AgentsView(
            peer: .preview, session: "work", workspace: "w2", title: "bleat-apple",
            previewing: .loaded([]), terminals: Pane.samples
        )
    }
}

#Preview("Empty", traits: .sampleData) {
    NavigationStack {
        AgentsView(
            peer: .preview, session: "work", workspace: "w2", title: "bleat-apple",
            previewing: .loaded([])
        )
    }
}

#Preview("Failed", traits: .sampleData) {
    NavigationStack {
        AgentsView(
            peer: .preview, session: "work", workspace: "w2", title: "bleat-apple",
            previewing: .failed(.unreachable("this host is only reachable over a VPN from here"))
        )
    }
}

/// **The host was reached and said no**, which is a different screen from the
/// one above and used to be titled the same. This is a real message, off a
/// `phone` session whose server was a protocol version behind the client:
/// herdr says exactly what is wrong and how to fix it, and "Could not reach the
/// host" over the top of it sent the user to check their Wi-Fi.
#Preview("Herdr said no", traits: .sampleData) {
    NavigationStack {
        AgentsView(
            peer: .preview, session: "phone", workspace: nil, title: "bleat-apple",
            previewing: .failed(.hostSaidNo(
                "client protocol 22 is newer than server protocol 20; restart the Herdr server "
                + "before using this command. Stopping exits pane processes.\nRun `herdr session "
                + "stop phone`, then run `herdr session attach phone` again."
            ))
        )
    }
}

/// The third class: reached, answered, and the reply did not fit this build.
#Preview("Unreadable reply", traits: .sampleData) {
    NavigationStack {
        AgentsView(
            peer: .preview, session: "work", workspace: nil, title: "bleat-apple",
            previewing: .failed(.unreadable(
                "the host sent a reply Bleat could not read; it may be running a different "
                + "version of herdr"
            ))
        )
    }
}
#endif
