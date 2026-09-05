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
                PeerDetailView(peer: peer, connections: context.connections)
            } else {
                unpaired
            }
        case .workspaces(let hostKey, let session):
            if let peer = peer(hostKey) {
                WorkspacesView(peer: peer, session: session, connections: context.connections)
            } else {
                unpaired
            }
        case .agents(let hostKey, let session, let workspace):
            if let peer = peer(hostKey) {
                AgentsView(
                    peer: peer, session: session, workspace: workspace,
                    connections: context.connections
                )
            } else {
                unpaired
            }
        case .pane(_, _, let target, let title):
            PlaceholderView(title: title, detail: target)
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
