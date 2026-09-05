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
