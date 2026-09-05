import BleatKit
import SwiftUI

/// One agent, led by whatever it needs from the user.
struct AgentRow: View {
    let agent: Agent

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(agent.displayTitle)
                    .lineLimit(1)
                if let directory {
                    Text(directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // A path truncated at the front keeps the part that
                        // distinguishes one checkout from another; truncated at
                        // the end every row reads "/Users/ravil/Developer/…".
                        .truncationMode(.head)
                }
            }
        } icon: {
            Image(systemName: agent.agentStatus.symbolName)
                .foregroundStyle(agent.agentStatus.tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.displayTitle), \(agent.agentStatus.rawValue)")
    }

    /// What the pane is actually working in, which is not always where it
    /// started: `foreground_cwd` follows the running process.
    ///
    /// Shown whole. `abbreviatingWithTildeInPath` was here and did nothing:
    /// it abbreviates against *this device's* home, which on iOS is the app
    /// container, while the path belongs to the host. Head truncation does the
    /// shortening, and it keeps the end of the path — the part that tells two
    /// checkouts apart.
    private var directory: String? {
        let path = agent.foregroundCwd ?? agent.cwd
        guard let path, !path.isEmpty else { return nil }
        return path
    }
}

#if DEBUG
#Preview {
    List {
        AgentRow(agent: Agent(
            paneID: "p1", workspaceID: "w2", tabID: "t1", agentStatus: .blocked,
            agent: "claude", cwd: "/Users/ravil/Developer/rawillk/bleat-apple",
            terminalTitleStripped: "Waiting for approval"
        ))
        AgentRow(agent: Agent(
            paneID: "p2", workspaceID: "w2", tabID: "t1", agentStatus: .working,
            agent: "claude", cwd: "/Users/ravil/Developer/rawillk/herdr"
        ))
    }
}
#endif
