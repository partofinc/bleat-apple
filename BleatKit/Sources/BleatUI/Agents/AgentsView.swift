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
            let panes = try await $0.panes()
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
            empty: "Nothing is running here. Open a terminal, or start an agent in one.",
            retry: { await entries.load(for: peer) }
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
            ToolbarItem(placement: .bottomBar) {
                Menu {
                    // **Only from inside a workspace.** A tab belongs to one,
                    // and the session-wide list is not in one — guessing which
                    // workspace should gain a pane puts one in somebody's
                    // project.
                    if let workspace {
                        Button("New Terminal", systemImage: "terminal") {
                            openTerminal(in: workspace)
                        }
                        .disabled(newTerminal.isCreating)
                    }
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
            }
        }
        // A terminal is one command with no sheet of its own, so a refusal has
        // nowhere else to be read. `SessionControlFlow` says the same sentence
        // for the same reason.
        .alert("That did not happen", isPresented: $newTerminal.isShowingFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(newTerminal.failure ?? "The host did not say why.")
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
        .refreshable { await entries.load(for: peer) }
        .task { await entries.load(for: peer) }
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
    private func openTerminal(in workspace: String) {
        Task {
            let pane = await newTerminal.create(in: workspace, for: peer)
            await entries.load(for: peer)
            guard let pane else { return }
            context.navigation.push(.pane(
                peer: peer.hostKey, session: session, target: pane.target,
                title: pane.displayTitle, mode: .terminal
            ))
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
