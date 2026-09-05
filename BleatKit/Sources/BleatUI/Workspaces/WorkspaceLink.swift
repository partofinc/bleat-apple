import BleatKit
import SwiftUI

/// A workspace row that pushes its agents.
struct WorkspaceLink: View {
    @Environment(AppContext.self) private var context
    let peer: PairedPeer
    let session: String?
    let workspace: Workspace

    var body: some View {
        Button {
            context.navigation.push(
                .agents(
                    peer: peer.hostKey,
                    session: session,
                    workspace: workspace.workspaceID,
                    label: workspace.label
                )
            )
        } label: {
            WorkspaceRow(workspace: workspace)
        }
        .buttonStyle(.plain)
    }
}
