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
        _status = State(wrappedValue: SessionStatus(
            connections: connections, name: session, peers: peers
        ))
        _control = State(wrappedValue: SessionControlModel(connections: connections, peers: peers))
        _newWorkspace = State(wrappedValue: NewWorkspaceModel(connections: connections, session: session))
    }

    #if DEBUG
    /// Preview-only: the workspaces are handed in and nothing is fetched.
    /// `control` parks the session action in a phase — `.confirming` is the
    /// bar with its question already asked.
    init(
        peer: PairedPeer,
        session: String?,
        previewing state: Loadable<[Workspace]>,
        status: SessionInfo? = nil,
        control: SessionControlModel.Phase = .idle
    ) {
        self.peer = peer
        self.session = session
        _workspaces = State(wrappedValue: RemoteList(previewing: state))
        _status = State(wrappedValue: SessionStatus(previewing: status))
        _control = State(wrappedValue: SessionControlModel(previewing: control))
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
                    // The whole reload, not just the list: a retry is what
                    // brings the connection up after a failed first load, and
                    // the host's load is read only once it is.
                    retry: { await reload() },
                    header: { HostLoadSection(peer: peer) },
                    footer: { powerSection }
                ) { list in
                    // Named on a watch, where the host's load is the row
                    // above and a list that simply follows it reads as more
                    // of the same.
                    if WatchLayout.isHere {
                        if !list.isEmpty {
                            Section("Workspaces") { links(to: list) }
                        }
                    } else {
                        links(to: list)
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
        #elseif !os(watchOS)
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { actionButtons } }
        #endif
        // The bar's own buttons ask — see `actionButton`, and `powerSection`
        // on a watch — so the screen does not: two dialogs over one question is one that never appears.
        .sessionControl(control, on: peer, confirmsHere: false) { action in
            // A screen cannot stay inside a session it has just deleted: the
            // route names something the host no longer has, and every refresh
            // from here on would fail against it.
            if action == .delete { context.navigation.pop(); return }
            await reload()
        }
        .hostLoadBar(for: peer)
        .refreshable { await reload(force: true) }
        .task { await reload() }
    }

    /// - Parameter force: a pull-to-refresh, which reads the host's load again
    ///   even if the last reading is seconds old. After the workspaces,
    ///   because it is read only over a connection they have already brought
    ///   up — and beside the status rather than after it: on a watch the load
    ///   is a row above the workspaces, and one that waited a `session list`
    ///   to claim its place pushed them down after they were drawn.
    private func reload(force: Bool = false) async {
        await workspaces.load(for: peer)
        async let load: Void = context.hostLoad.refresh(for: peer, force: force)
        await status.load(for: peer)
        await load
    }

    /// Only for a session known to be stopped — `nil` is "not asked yet", and
    /// covering the list on that would flash over a perfectly good load.
    private var isStopped: Bool { status.info?.running == false }

    /// And the other way round, which is not the negation: `nil` is neither.
    /// The plus is offered only once the host has said the session is up,
    /// because a `workspace create` against a stopped one answers
    /// `server_not_running`.
    private var isRunning: Bool { status.info?.running == true }

    private func links(to list: [Workspace]) -> some View {
        ForEach(list) { workspace in
            WorkspaceLink(peer: peer, session: session, workspace: workspace)
        }
    }

    /// A list on a watch, for the reason `RemoteListView` is one there: the
    /// explanation is longer than the screen, and Start has to be a row
    /// because there is no bar.
    @ViewBuilder
    private var stopped: some View {
        if WatchLayout.isHere {
            List {
                HostLoadSection(peer: peer)
                Section {
                    Label("Session stopped", systemImage: "stop.circle")
                        .font(.headline)
                    Text(stoppedText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                powerSection
            }
        } else {
            ContentUnavailableView(
                "Session stopped",
                systemImage: "stop.circle",
                description: Text(stoppedText)
            )
        }
    }

    /// Says what Start actually does, because it is not obvious and it is not
    /// nothing: measured, a restarted session comes back with its workspaces
    /// and panes and a freshly spawned shell in each — but **agents are not
    /// restarted**. `herdr agent start` is a separate step herdr does not
    /// replay, so a pane that held an agent comes back as a plain shell.
    private var stoppedText: String {
        "Nothing is running in \(session ?? peer.name). Starting it brings back its "
            + "workspaces and a shell in each pane; agents are not restarted."
    }

    /// Start or Stop as the list's last row, on a watch — the phone has them
    /// in its bottom bar, and a watch has no bar.
    ///
    /// **Last, under the workspaces**, so Stop is something scrolled to
    /// rather than the first thing under a thumb, and asks before it acts
    /// like every other Stop. Delete is not here: it stays a swipe on the
    /// session's row, one screen up.
    @ViewBuilder
    private var powerSection: some View {
        if WatchLayout.isHere, let info = status.info, let power {
            Section {
                Button {
                    control.begin(power, about: info, on: peer)
                } label: {
                    HStack {
                        Label(power.title, systemImage: power.symbol)
                            .foregroundStyle(power == .start ? .green : .red)
                        Spacer()
                        // A start is a launch and a poll: seconds, on a
                        // screen that otherwise would not move.
                        if control.isWorking { ProgressView().fixedSize() }
                    }
                }
                .disabled(control.isWorking)
                .sessionConfirmation(control, for: power, on: peer)
            }
        }
    }

    /// What this screen's session offers — see
    /// `SessionControlModel.actions(for:on:)`. Never empty for a running
    /// session: Stop is offered for anyone's.
    private var actions: [SessionControlModel.Action] {
        guard let info = status.info else { return [] }
        return SessionControlModel.actions(for: info, on: peer)
    }

    /// Start or Stop, whichever the session's state allows — the one that
    /// turns it on or off. Nil before the host has said, and for a name this
    /// app cannot address.
    private var power: SessionControlModel.Action? {
        actions.first { $0 != .delete }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let info = status.info {
            ForEach(actions, id: \.self) { action in
                actionButton(action, about: info, prominent: false)
            }
        }
    }

    #if os(iOS)
    /// Start and Stop share the leading corner, and what is left goes to the
    /// trailing one: the plus while the session runs, Delete once it has
    /// stopped.
    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        if let info = status.info {
            // **One item for both, so the button does not move.** Stopping a
            // session and starting it again is the pair most often done in a
            // row, and with Stop on the right and Start on the left the second
            // tap was at the far side of the screen from the first. Start is
            // the prominent one: on a stopped session it is the only thing
            // there is to do. Stop is not, because the thing to do with a
            // running session is add to it.
            if let power {
                ToolbarItem(placement: .bottomBar) {
                    actionButton(power, about: info, prominent: power == .start)
                }
            }
            // **The spacer is what keeps Delete away from Start**, and it is
            // load-bearing rather than layout taste: the two appear together,
            // and one of them removes somebody's session directory. Rendering
            // both inside a single `ToolbarItem` — which a `ForEach` does —
            // puts a destructive action flush against the primary one, a tap's
            // width apart.
            ToolbarSpacer(.flexible, placement: .bottomBar)
            // **The plus is offered only while the session is running**: a
            // `workspace create` against a stopped one answers
            // `server_not_running`. Delete is the other way round — herdr will
            // not delete a running session — so the two never want the corner
            // at once.
            if isRunning {
                ToolbarItem(placement: .bottomBar) {
                    Button("Add Workspace", systemImage: "plus") {
                        // **A whole reset, not just the failure.** The model is
                        // `@State` here rather than on the sheet, so everything
                        // it holds outlives a dismissal — a stale path would
                        // come back prefilled and armed, and a "landed
                        // elsewhere" warning would come back with the button
                        // already spent and no way on the screen to clear it.
                        newWorkspace.reset()
                        isNaming = true
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(control.isWorking)
                }
            } else if actions.contains(.delete) {
                ToolbarItem(placement: .bottomBar) {
                    actionButton(.delete, about: info, prominent: false)
                }
            }
        }
    }
    #endif

    /// One session action as a button that asks its own question.
    ///
    /// **The confirmation is on the button, not on the screen**, because a
    /// dialog opens out of the view it is attached to: here that is the button
    /// under the finger, and attached to the screen it would be nowhere in
    /// particular. Each button names its own action so that Start's — which
    /// asks nothing — and Delete's beside it cannot answer for one another.
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
        .sessionConfirmation(control, for: action, on: peer)

        if prominent {
            button.buttonStyle(.glassProminent)
        } else {
            button
        }
    }
}

#if DEBUG
#Preview("Workspaces", traits: .sampleData) {
    NavigationStack {
        WorkspacesView(peer: .preview, session: "work", previewing: .loaded(Workspace.samples))
    }
}

/// A session this phone started, running — so the bar offers Stop where Start
/// would be, and the plus opposite, because herdr will not delete a running
/// session.
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

/// A session running for somebody else's reasons. The bar offers Stop just as
/// it does for our own — the claim stopped gating that — and what differs is the
/// confirmation behind it, which says the phone did not start this one.
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
