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

    init(peer: PairedPeer, session: String?, connections: ConnectionStore, peers: PeerStore) {
        self.peer = peer
        self.session = session
        _workspaces = State(wrappedValue: RemoteList(connections: connections, session: session) {
            try await $0.workspaces()
        })
        _status = State(wrappedValue: SessionStatus(connections: connections, name: session))
        _control = State(wrappedValue: SessionControlModel(connections: connections, peers: peers))
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
    /// on the left, prominent, and the rest to the right.
    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        if let info = status.info, let first = actions.first {
            ToolbarItem(placement: .bottomBar) {
                Button(first.title, systemImage: first.symbol) {
                    control.begin(first, about: info, on: peer)
                }
                .buttonStyle(.glassProminent)
                .disabled(control.isWorking)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                // Only ever Delete, and only for a stopped session — herdr
                // refuses to delete a running one, so there is nothing to show
                // beside Stop.
                if let second = actions.dropFirst().first {
                    Button(second.title, systemImage: second.symbol) {
                        control.begin(second, about: info, on: peer)
                    }
                    .disabled(control.isWorking)
                }
            }
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
