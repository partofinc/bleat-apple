import BleatKit
import SwiftUI

/// The screen a route names.
///
/// A route carries identifiers, not model objects, so this looks the peer up
/// each time: the list beneath a pushed screen is refreshed on every appearance
/// and a captured struct would go stale.
struct RouteView: View {
    @Environment(AppContext.self) private var context
    let route: NavigationRouter.Route

    var body: some View {
        switch route {
        case .peer(let hostKey):
            if let peer = peer(hostKey) {
                PeerDetailView(peer: peer, connections: context.connections, peers: context.peers)
            } else {
                unpaired
            }
        case .workspaces(let hostKey, let session):
            if let peer = peer(hostKey) {
                WorkspacesView(peer: peer, session: session, connections: context.connections)
            } else {
                unpaired
            }
        case .agents(let hostKey, let session, let workspace, let label):
            if let peer = peer(hostKey) {
                AgentsView(
                    peer: peer, session: session, workspace: workspace, title: label,
                    connections: context.connections
                )
            } else {
                unpaired
            }
        case .pane(let hostKey, let session, let target, let title):
            if let peer = peer(hostKey) {
                PaneView(
                    peer: peer, session: session, target: target, title: title,
                    connections: context.connections
                )
            } else {
                unpaired
            }
        }
    }

    private func peer(_ hostKey: String) -> PairedPeer? {
        context.peers.peers.first { $0.hostKey == hostKey }
    }

    /// Reachable: unpairing a host while one of its screens is pushed. Saying
    /// so beats an empty screen that looks like a loading failure.
    private var unpaired: some View {
        ContentUnavailableView(
            "Host not paired",
            systemImage: "desktopcomputer.trianglebadge.exclamationmark",
            description: Text("This host was removed.")
        )
    }
}

#if DEBUG
/// The one state of this view that has no other way in: a host unpaired while
/// one of its screens was pushed. Every other route is previewed on the screen
/// it resolves to.
#Preview("Unpaired", traits: .sampleData) {
    NavigationStack {
        RouteView(route: .peer(peer: "ssh-ed25519 a-host-key-that-is-not-in-the-list"))
    }
}
#endif
