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
/// All five states, and the two title fallbacks: an agent with no title falls
/// back to its kind, one with neither to its pane id. Neither may render blank.
#Preview("Every state", traits: .sampleData) {
    List {
        ForEach(Agent.samples) { agent in
            AgentRow(agent: agent)
        }
    }
}

/// The paths are what this row is mostly made of, and they are truncated at the
/// head so the end — the part that tells two checkouts apart — survives. A
/// narrow width is where that shows.
#Preview("Narrow", traits: .sampleData) {
    List {
        ForEach(Agent.samples) { agent in
            AgentRow(agent: agent)
        }
    }
    .frame(width: 260)
}
#endif
