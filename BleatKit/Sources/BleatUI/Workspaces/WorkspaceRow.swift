import BleatKit
import SwiftUI

/// One workspace, led by whatever it needs from the user.
struct WorkspaceRow: View {
    let workspace: Workspace

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(workspace.label)
                Text("\(workspace.workspaceID) · ^[\(workspace.paneCount) pane](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            // The symbol differs per state as well as the colour, so the
            // distinction survives for anyone who cannot use colour to tell
            // blocked from working.
            Image(systemName: workspace.agentStatus.symbolName)
                .foregroundStyle(workspace.agentStatus.tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(workspace.label), \(workspace.agentStatus.rawValue)")
    }
}

#if DEBUG
#Preview {
    List {
        WorkspaceRow(workspace: Workspace(
            workspaceID: "w2", label: "bleat-apple", number: 2,
            agentStatus: .blocked, focused: true, paneCount: 3, tabCount: 1, activeTabID: nil
        ))
        WorkspaceRow(workspace: Workspace(
            workspaceID: "w3", label: "herdr", number: 3,
            agentStatus: .working, focused: false, paneCount: 1, tabCount: 1, activeTabID: nil
        ))
    }
}
#endif
