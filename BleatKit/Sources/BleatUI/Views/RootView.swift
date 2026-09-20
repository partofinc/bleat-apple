import BleatKit
import SwiftUI

/// The app's navigation: the hosts in a sidebar, and one host's drill-down in
/// the detail column.
///
/// **Two columns, not three.** The drill-down is five screens deep — hosts →
/// sessions → workspaces → agents → pane — and a split view has at most three
/// columns, so something has to stay a stack. Apple's shape for that is a
/// selection in the sidebar and a `NavigationStack` in the detail, which is
/// also the arrangement that collapses predictably: on a phone the split view
/// folds into the single stack this app already was, with picking a host
/// standing in for the first push.
///
/// Route destinations are registered here so every screen that can push one has
/// somewhere to send it.
public struct RootView: View {
    @Environment(AppContext.self) private var context
    /// Both columns where there is room for both. The default hides the
    /// sidebar in portrait, which on an iPad is most of the time — and the host
    /// list being on screen is the whole point of the change.
    @State private var columns = NavigationSplitViewVisibility.all

    public init() {}

    public var body: some View {
        // Bind the router, not the context: `navigation` is a `let`, and the
        // selection and the path are what actually change.
        @Bindable var navigation = context.navigation
        NavigationSplitView(columnVisibility: $columns) {
            PeersView()
        } detail: {
            NavigationStack(path: $navigation.path) {
                detail
                    .navigationDestination(for: NavigationRouter.Route.self) { route in
                        RouteView(route: route)
                    }
            }
        }
        // **Releasing the connection moved here, off `PeersView.task`.** The
        // rule has not changed — nothing should hold an SSH session open on
        // someone's Mac while no host is being browsed — but with the sidebar
        // permanently on screen the list appearing no longer means that. On an
        // iPad it appears once, at launch, and would then never release; worse,
        // a rotation or a Slide Over resize that re-mounted it would release a
        // connection out from under a live pane. The selection clearing is what
        // actually means "no host is being browsed", in both layouts.
        //
        // Switching straight from one host to another needs nothing here:
        // `ConnectionStore.connection(for:)` already releases before dialling a
        // different host key.
        .onChange(of: navigation.selectedPeer) { _, peer in
            guard peer == nil else { return }
            Task { await context.connections.release() }
        }
        // On the split view, not on a screen inside it: the peer list and a
        // peer's detail can both start an unpair, and a modifier on each would
        // bind two presentations to one piece of state.
        .unpairFlow()
        // Here too, and not on `PeersView`: a `bleat://` link can arrive
        // while the user is inside a host, where that screen is not being
        // evaluated and its `onOpenURL` would never fire.
        .pairingFlow()
        // And here, for the third time and the same reason: a swipe on the
        // peer list and the gear on a peer's own screen open one sheet.
        .peerSettingsSheet()
    }

    /// The detail column's root: the selected host's sessions.
    ///
    /// Through `RouteView` rather than building `PeerDetailView` here, so that
    /// resolving a host key to a screen — including the answer for one that has
    /// been unpaired — stays in one place.
    @ViewBuilder
    private var detail: some View {
        if let hostKey = context.navigation.selectedPeer {
            RouteView(route: .peer(peer: hostKey))
        } else {
            // Only ever seen on a wide screen. Collapsed, the sidebar *is* the
            // root and there is no detail column to fill.
            ContentUnavailableView(
                "No host selected",
                systemImage: "desktopcomputer",
                description: Text("Pick a host to see the sessions running on it.")
            )
        }
    }
}

#if DEBUG
/// The whole app, from the top. The split view, the unpair flow and the pairing
/// sheet are all attached here, so this is the only preview in which a push, a
/// host selection or a `bleat://` link behaves the way it does on the device.
#Preview("Root", traits: .sampleData) {
    RootView()
}

#Preview("Fresh install", traits: .noHosts) {
    RootView()
}
#endif
