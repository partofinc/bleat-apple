import BleatKit
import SwiftUI

/// A workspace row that pushes its agents.
struct WorkspaceLink: View {
    let peer: PairedPeer
    let session: String?
    let workspace: Workspace

    var body: some View {
        NavigationLink(
            value: NavigationRouter.Route.agents(
                peer: peer.hostKey,
                session: session,
                workspace: workspace.workspaceID,
                label: workspace.label
            )
        ) {
            WorkspaceRow(workspace: workspace)
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("Workspace links", traits: .sampleData) {
    NavigationStack {
        List {
            ForEach(Workspace.samples) { workspace in
                WorkspaceLink(peer: .preview, session: "work", workspace: workspace)
            }
        }
    }
}
#endif
