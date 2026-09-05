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
            if let peer = context.peers.peers.first(where: { $0.hostKey == hostKey }) {
                PeerDetailView(peer: peer)
            } else {
                // Reachable: unpairing a host while its screen is pushed. Saying
                // so beats an empty screen that looks like a loading failure.
                ContentUnavailableView(
                    "Host not paired",
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                    description: Text("This host was removed.")
                )
            }
        case .workspaces(let peer, _):
            PlaceholderView(title: "Workspaces", detail: peer)
        case .agents(_, _, let workspace):
            PlaceholderView(title: "Agents", detail: workspace ?? "")
        case .pane(_, _, let target, let title):
            PlaceholderView(title: title, detail: target)
        }
    }
}
