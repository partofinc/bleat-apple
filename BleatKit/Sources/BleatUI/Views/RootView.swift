import BleatKit
import SwiftUI

/// The app's single navigation stack.
///
/// Route destinations are registered here so every screen that can push one has
/// somewhere to send it.
public struct RootView: View {
    @Environment(AppContext.self) private var context

    public init() {}

    public var body: some View {
        // Bind the router, not the context: `navigation` is a `let`, and the
        // path is what actually changes.
        @Bindable var navigation = context.navigation
        NavigationStack(path: $navigation.path) {
            PeersView()
                .navigationDestination(for: NavigationRouter.Route.self) { route in
                    RouteView(route: route)
                }
        }
        // On the stack, not on a screen inside it: the peer list and a peer's
        // detail can both start an unpair, and a modifier on each would bind
        // two presentations to one piece of state.
        .unpairFlow()
        // Here too, and not on `PeersView`: a `bleat://` link can arrive
        // while the user is inside a host, where that screen is not being
        // evaluated and its `onOpenURL` would never fire.
        .pairingFlow()
    }
}
