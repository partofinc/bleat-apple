import BleatKit
import SwiftUI

/// The agents in one workspace, blocked first.
///
/// This is the list the whole app is organised around. `agent list` needs no
/// join — each row already carries its pane, workspace and working directory —
/// and `HerdrClient.agents()` has already sorted it by attention, so the
/// ordering the user sees is the one the client and the console tool agree on
/// rather than a rule restated here.
struct AgentsView: View {
    let peer: PairedPeer
    let session: String?
    /// nil means every agent in the session, which is what the host answers
    /// with. A workspace narrows it.
    let workspace: String?
    /// The workspace's label. Its id is opaque — `w2` and `w653998617a6031`
    /// both occur — and belongs in a subtitle at most, never in a title bar.
    let title: String
    @State private var agents: RemoteList<Agent>

    init(
        peer: PairedPeer,
        session: String?,
        workspace: String?,
        title: String,
        connections: ConnectionStore
    ) {
        self.peer = peer
        self.session = session
        self.workspace = workspace
        self.title = title
        _agents = State(wrappedValue: RemoteList(connections: connections, session: session) {
            let all = try await $0.agents()
            guard let workspace else { return all }
            return all.filter { $0.workspaceID == workspace }
        })
    }

    #if DEBUG
    /// Preview-only: the agents are handed in and nothing is fetched.
    init(
        peer: PairedPeer,
        session: String?,
        workspace: String?,
        title: String,
        previewing state: Loadable<[Agent]>
    ) {
        self.peer = peer
        self.session = session
        self.workspace = workspace
        self.title = title
        _agents = State(wrappedValue: RemoteList(previewing: state))
    }
    #endif

    var body: some View {
        RemoteListView(
            state: agents.state,
            empty: "No agents are running here. Herdr reports a pane as an agent once it recognises one.",
            retry: { await agents.load(for: peer) }
        ) { list in
            ForEach(list) { agent in
                AgentLink(peer: peer, session: session, agent: agent)
            }
        }
        .navigationTitle(title)
        .refreshable { await agents.load(for: peer) }
        .task { await agents.load(for: peer) }
    }
}

#if DEBUG
#Preview("Agents", traits: .sampleData) {
    NavigationStack {
        AgentsView(
            peer: .preview, session: "work", workspace: "w2", title: "bleat-apple",
            previewing: .loaded(Agent.samples)
        )
    }
}

#Preview("Empty", traits: .sampleData) {
    NavigationStack {
        AgentsView(
            peer: .preview, session: "work", workspace: "w2", title: "bleat-apple",
            previewing: .loaded([])
        )
    }
}

#Preview("Failed", traits: .sampleData) {
    NavigationStack {
        AgentsView(
            peer: .preview, session: "work", workspace: "w2", title: "bleat-apple",
            previewing: .failed(.unreachable("this host is only reachable over a VPN from here"))
        )
    }
}

/// **The host was reached and said no**, which is a different screen from the
/// one above and used to be titled the same. This is a real message, off a
/// `phone` session whose server was a protocol version behind the client:
/// herdr says exactly what is wrong and how to fix it, and "Could not reach the
/// host" over the top of it sent the user to check their Wi-Fi.
#Preview("Herdr said no", traits: .sampleData) {
    NavigationStack {
        AgentsView(
            peer: .preview, session: "phone", workspace: nil, title: "bleat-apple",
            previewing: .failed(.hostSaidNo(
                "client protocol 22 is newer than server protocol 20; restart the Herdr server "
                + "before using this command. Stopping exits pane processes.\nRun `herdr session "
                + "stop phone`, then run `herdr session attach phone` again."
            ))
        )
    }
}

/// The third class: reached, answered, and the reply did not fit this build.
#Preview("Unreadable reply", traits: .sampleData) {
    NavigationStack {
        AgentsView(
            peer: .preview, session: "work", workspace: nil, title: "bleat-apple",
            previewing: .failed(.unreadable(
                "the host sent a reply Bleat could not read; it may be running a different "
                + "version of herdr"
            ))
        )
    }
}
#endif
