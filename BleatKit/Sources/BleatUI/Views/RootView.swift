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
    }
}
