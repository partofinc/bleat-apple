import BleatKit
import Observation
import SwiftUI

/// Where the app is. One path, because Phase 2 is a single drill-down:
/// hosts → session → workspaces → agents → pane.
///
/// A tab router joins this when there is a second tab to route to; adding one
/// now would be a router with a single case.
@Observable
public final class NavigationRouter {
    public var path = NavigationPath()

    public init() {}

    /// A screen reachable by pushing.
    ///
    /// Carries the identifiers a screen needs, not model objects: a pushed
    /// value must survive the list beneath it being refreshed.
    public enum Route: Hashable {
        case sessions(host: String)
        case workspaces(host: String, session: String?)
        case agents(host: String, session: String?, workspace: String?)
        case pane(host: String, session: String?, target: String, title: String)
    }

    public func push(_ route: Route) { path.append(route) }

    public func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    public func popToRoot() { path = NavigationPath() }
}
