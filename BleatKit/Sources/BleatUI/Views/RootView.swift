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
            HostsView()
                .navigationDestination(for: NavigationRouter.Route.self) { route in
                    destination(for: route)
                }
        }
    }

    @ViewBuilder
    private func destination(for route: NavigationRouter.Route) -> some View {
        switch route {
        case .sessions(let host):
            PlaceholderView(title: "Sessions", detail: host)
        case .workspaces(let host, let session):
            PlaceholderView(title: "Workspaces", detail: session ?? host)
        case .agents(let host, _, let workspace):
            PlaceholderView(title: "Agents", detail: workspace ?? host)
        case .pane(_, _, let target, let title):
            PlaceholderView(title: title, detail: target)
        }
    }
}

/// Stands in for a screen that lands in a later PR.
///
/// Explicit rather than an empty `Text("")`, so a route that is wired but not
/// yet built is obvious when tapping through the app.
struct PlaceholderView: View {
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "rectangle.dashed")
        } description: {
            Text("\(detail)\nNot built yet.")
        }
        .navigationTitle(title)
    }
}
