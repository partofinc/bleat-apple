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
/// All five states, in the order the app sorts them — blocked, done, working,
/// idle, unknown. The symbol has to differ as well as the colour, and a row of
/// five side by side is the only way to see whether it does.
#Preview("Every state", traits: .sampleData) {
    List {
        ForEach(Workspace.samples) { workspace in
            WorkspaceRow(workspace: workspace)
        }
    }
}
#endif
