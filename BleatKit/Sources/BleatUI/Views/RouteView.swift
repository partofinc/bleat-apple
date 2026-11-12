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
                // Every host goes through the herdr-core gate: its terminals
                // once it has hc, and what stands in the way until then.
                HerdrCoreGateView(peer: peer)
            } else {
                unpaired
            }
        case .terminal(let hostKey, let address, let title):
            if let peer = peer(hostKey) {
                HcTerminalScreen(peer: peer, address: address, title: title, connections: context.connections)
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
