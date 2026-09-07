import BleatKit
import SwiftUI

/// An agent row that opens its pane.
struct AgentLink: View {
    @Environment(AppContext.self) private var context
    let peer: PairedPeer
    let session: String?
    let agent: Agent

    var body: some View {
        Button {
            context.navigation.push(
                .pane(
                    peer: peer.hostKey,
                    session: session,
                    target: agent.target,
                    title: agent.displayTitle
                )
            )
        } label: {
            AgentRow(agent: agent)
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("Agent links", traits: .sampleData) {
    NavigationStack {
        List {
            ForEach(Agent.samples) { agent in
                AgentLink(peer: .preview, session: "work", agent: agent)
            }
        }
    }
}
#endif
