import BleatKit
import SwiftUI

/// The workspaces in one session, most in need of attention first.
///
/// `workspace list` already carries each workspace's `agent_status`, so this
/// list is an attention summary in itself: the user can see which workspace has
/// something blocked without opening it.
struct WorkspacesView: View {
    let peer: PairedPeer
    let session: String?
    @State private var workspaces: RemoteList<Workspace>

    init(peer: PairedPeer, session: String?, connections: ConnectionStore) {
        self.peer = peer
        self.session = session
        _workspaces = State(wrappedValue: RemoteList(connections: connections, session: session) {
            try await $0.workspaces()
        })
    }

    #if DEBUG
    /// Preview-only: the workspaces are handed in and nothing is fetched.
    init(peer: PairedPeer, session: String?, previewing state: Loadable<[Workspace]>) {
        self.peer = peer
        self.session = session
        _workspaces = State(wrappedValue: RemoteList(previewing: state))
    }
    #endif

    var body: some View {
        RemoteListView(
            state: workspaces.state,
            empty: "No workspaces in this session.",
            retry: { await workspaces.load(for: peer) }
        ) { list in
            ForEach(list) { workspace in
                WorkspaceLink(peer: peer, session: session, workspace: workspace)
            }
        }
        .navigationTitle(session ?? peer.name)
        .refreshable { await workspaces.load(for: peer) }
        .task { await workspaces.load(for: peer) }
    }
}

#if DEBUG
#Preview("Workspaces", traits: .sampleData) {
    NavigationStack {
        WorkspacesView(peer: .preview, session: "work", previewing: .loaded(Workspace.samples))
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
