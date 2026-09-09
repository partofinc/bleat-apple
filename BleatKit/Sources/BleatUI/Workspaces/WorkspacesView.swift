import BleatKit
import SwiftUI

/// The workspaces in one session, most in need of attention first.
///
/// `workspace list` already carries each workspace's `agent_status`, so this
/// list is an attention summary in itself: the user can see which workspace has
/// something blocked without opening it.
struct WorkspacesView: View {
    @Environment(AppContext.self) private var context
    let peer: PairedPeer
    let session: String?
    @State private var workspaces: RemoteList<Workspace>
    /// Whether this session is running, which the route cannot carry — see
    /// `SessionStatus`. It is what decides between Start and Stop.
    @State private var status: SessionStatus
    @State private var control: SessionControlModel
    /// Owned here rather than by the sheet, so a create survives the sheet
    /// being dismissed on top of it — the reply is what says whether there is
    /// now a workspace on someone's Mac, and where.
    @State private var newWorkspace: NewWorkspaceModel
    @State private var isNaming = false

    init(peer: PairedPeer, session: String?, connections: ConnectionStore, peers: PeerStore) {
        self.peer = peer
        self.session = session
        _workspaces = State(wrappedValue: RemoteList(connections: connections, session: session) {
            try await $0.workspaces()
        })
        _status = State(wrappedValue: SessionStatus(connections: connections, name: session))
        _control = State(wrappedValue: SessionControlModel(connections: connections, peers: peers))
        _newWorkspace = State(wrappedValue: NewWorkspaceModel(connections: connections, session: session))
    }

    #if DEBUG
    /// Preview-only: the workspaces are handed in and nothing is fetched.
    init(
        peer: PairedPeer,
        session: String?,
        previewing state: Loadable<[Workspace]>,
        status: SessionInfo? = nil
    ) {
        self.peer = peer
        self.session = session
        _workspaces = State(wrappedValue: RemoteList(previewing: state))
        _status = State(wrappedValue: SessionStatus(previewing: status))
        _control = State(wrappedValue: SessionControlModel(previewing: .idle))
        _newWorkspace = State(wrappedValue: NewWorkspaceModel(previewing: ""))
    }
    #endif

    var body: some View {
        // **Instead of the list, not over it.** A stopped session has no server
        // to answer `workspace list`, so the list's own state is a
        // `server_not_running` failure — true, and useless. An `.overlay` drew
        // this on top of that: two headings and two paragraphs interleaved,
        // both legible, neither readable. Replacing the list is what was meant.
        Group {
            if isStopped {
                stopped
            } else {
                RemoteListView(
                    state: workspaces.state,
                    empty: "No workspaces in this session.",
                    retry: { await workspaces.load(for: peer) }
                ) { list in
                    ForEach(list) { workspace in
                        WorkspaceLink(peer: peer, session: session, workspace: workspace)
                    }
                }
            }
        }
        .navigationTitle(session ?? peer.name)
        #if os(iOS)
        .toolbar { bottomBar }
        // A sheet rather than the cover the session field uses: this one has a
        // path and a label to show, and a list of the host's own directories
        // under them. See `NewWorkspaceForm`.
        .sheet(isPresented: $isNaming) {
            NewWorkspaceForm(
                model: newWorkspace,
                peer: peer,
                known: workspaces.state.value ?? [],
                onCreated: { Task { await workspaces.load(for: peer) } }
            )
        }
        .yieldsToPairing(whileBusy: newWorkspace.isCreating, presenting: $isNaming)
        #else
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { actionButtons } }
        #endif
        .sessionControl(control, on: peer) { action in
            // A screen cannot stay inside a session it has just deleted: the
            // route names something the host no longer has, and every refresh
            // from here on would fail against it.
            if action == .delete { context.navigation.pop(); return }
            await reload()
        }
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        await workspaces.load(for: peer)
        await status.load(for: peer)
    }

    /// Only for a session known to be stopped — `nil` is "not asked yet", and
    /// covering the list on that would flash over a perfectly good load.
    private var isStopped: Bool { status.info?.running == false }

    /// And the other way round, which is not the negation: `nil` is neither.
    /// The plus is offered only once the host has said the session is up,
    /// because a `workspace create` against a stopped one answers
    /// `server_not_running`.
    private var isRunning: Bool { status.info?.running == true }

    private var stopped: some View {
        ContentUnavailableView(
            "Session stopped",
            systemImage: "stop.circle",
            // Says what Start actually does, because it is not obvious and it
            // is not nothing: measured, a restarted session comes back with its
            // workspaces and panes and a freshly spawned shell in each — but
            // **agents are not restarted**. `herdr agent start` is a separate
            // step herdr does not replay, so a pane that held an agent comes
            // back as a plain shell.
            description: Text(
                "Nothing is running in \(session ?? peer.name). Starting it brings back its "
                + "workspaces and a shell in each pane; agents are not restarted."
            )
        )
    }

    /// Empty for a session this phone did not start, which is the guard — see
    /// `SessionControlModel.actions(for:on:)`.
    private var actions: [SessionControlModel.Action] {
        guard let info = status.info else { return [] }
        return SessionControlModel.actions(for: info, on: peer)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let info = status.info {
            ForEach(actions, id: \.self) { action in
                Button(action.title, systemImage: action.symbol) {
                    control.begin(action, about: info, on: peer)
                }
                .disabled(control.isWorking)
            }
        }
    }

    #if os(iOS)
    /// The same shape as the peer screen's bar: the action that does something
    /// on the left, prominent, and the rest to the right. Which action that is
    /// depends on whether the session is up — see below.
    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        // **Which button is prominent follows what the session needs.** While
        // it is running, the useful thing is to add to it and Stop is the
        // afterthought; while it is stopped there is nothing to add *to* — a
        // client command against a dead session answers `server_not_running` —
        // so Start takes the position and the plus is not offered at all.
        if isRunning {
            ToolbarItem(placement: .bottomBar) {
                Button("Add Workspace", systemImage: "plus") {
                    // **A whole reset, not just the failure.** The model is
                    // `@State` here rather than on the sheet, so everything it
                    // holds outlives a dismissal — a stale path would come back
                    // prefilled and armed, and a "landed elsewhere" warning
                    // would come back with the button already spent and no way
                    // on the screen to clear it.
                    newWorkspace.reset()
                    isNaming = true
                }
                .buttonStyle(.glassProminent)
                .disabled(control.isWorking)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            // At most Stop here — herdr will not delete a running session — so
            // there is only ever one thing on the right.
            ToolbarItem(placement: .bottomBar) { trailingAction(prominent: false) }
        } else if let info = status.info, let first = actions.first {
            ToolbarItem(placement: .bottomBar) {
                actionButton(first, about: info, prominent: true)
            }
            // **The spacer is what keeps Delete away from Start**, and it is
            // load-bearing rather than layout taste: the two are the only pair
            // that appear together, and one of them removes somebody's session
            // directory. Rendering both inside a single `ToolbarItem` — which a
            // `ForEach` does — puts a destructive action flush against the
            // primary one, a tap's width apart.
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { trailingAction(prominent: false) }
        }
    }

    /// Whatever action goes to the right of the bar, if any.
    ///
    /// Empty for a session this phone did not start, which is the guard rather
    /// than an oversight: see `SessionControlModel.actions(for:on:)`. Empty too
    /// while the session runs and this phone started it, because the only
    /// action then is Stop and it is already the one on the right.
    @ViewBuilder
    private func trailingAction(prominent: Bool) -> some View {
        if let info = status.info {
            // The second action when the leading one is shown beside it, and
            // the only action when it is not.
            let trailing = isRunning ? actions.first : actions.dropFirst().first
            if let trailing {
                actionButton(trailing, about: info, prominent: prominent)
            }
        }
    }

    @ViewBuilder
    private func actionButton(
        _ action: SessionControlModel.Action,
        about info: SessionInfo,
        prominent: Bool
    ) -> some View {
        let button = Button(action.title, systemImage: action.symbol) {
            control.begin(action, about: info, on: peer)
        }
        .disabled(control.isWorking)

        if prominent {
            button.buttonStyle(.glassProminent)
        } else {
            button
        }
    }
    #endif
}

#if DEBUG
#Preview("Workspaces", traits: .sampleData) {
    NavigationStack {
        WorkspacesView(peer: .preview, session: "work", previewing: .loaded(Workspace.samples))
    }
}

/// A session this phone started, running — so the bar offers Stop, and nothing
/// beside it, because herdr will not delete a running session.
#Preview("Ours, running", traits: .sampleData) {
    NavigationStack {
        WorkspacesView(
            peer: .previewOwningSessions, session: "work",
            previewing: .loaded(Workspace.samples),
            status: SessionInfo(name: "work", running: true, isDefault: true)
        )
    }
}

/// The same session stopped: Start and Delete, over the empty state that says
/// why there are no workspaces rather than the `server_not_running` error the
/// list would otherwise show.
#Preview("Ours, stopped", traits: .sampleData) {
    NavigationStack {
        WorkspacesView(
            peer: .previewOwningSessions, session: "bleat-test",
            previewing: .failed(.hostSaidNo("no herdr server is running at …/bleat-test/herdr.sock")),
            status: SessionInfo(name: "bleat-test", running: false, isDefault: false)
        )
    }
}

/// **The guard.** A session running for somebody else's reasons: the
/// workspaces are there and the bar is empty, because ending it is not on
/// offer.
#Preview("Not ours, running", traits: .sampleData) {
    NavigationStack {
        WorkspacesView(
            peer: .preview, session: "phone",
            previewing: .loaded(Workspace.samples),
            status: SessionInfo(name: "phone", running: true, isDefault: false)
        )
    }
}

/// **And the other half of the guard.** Somebody else's session, stopped: Start
/// is offered — it restores rather than creates, and it is the only way back
/// when the Mac has rebooted — while Delete is not, because the layout it would
/// throw away is theirs.
#Preview("Not ours, stopped", traits: .sampleData) {
    NavigationStack {
        WorkspacesView(
            peer: .preview, session: "default",
            previewing: .failed(.hostSaidNo("no herdr server is running at …/herdr.sock")),
            status: SessionInfo(name: "default", running: false, isDefault: true)
        )
    }
}

#Preview("Empty", traits: .sampleData) {
    NavigationStack {
        WorkspacesView(peer: .preview, session: "work", previewing: .loaded([]))
    }
}

#Preview("Failed", traits: .sampleData) {
    NavigationStack {
        WorkspacesView(
            peer: .preview, session: "work",
            previewing: .failed(.unreachable("none of 3 addresses could be reached"))
        )
    }
}

/// A refresh that failed over rows that had already arrived — the state the
/// four-case `Loadable` exists for, and the one easiest to get wrong.
#Preview("Stale", traits: .sampleData) {
    NavigationStack {
        WorkspacesView(
            peer: .preview, session: "work",
            previewing: .stale(Workspace.samples, .unreachable("the connection closed before this finished"))
        )
    }
}
#endif
