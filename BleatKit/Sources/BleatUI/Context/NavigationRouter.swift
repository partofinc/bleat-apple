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
    ///
    /// `peer` throughout is a **host key**, which is what identifies a peer —
    /// its addresses change, and a route holding one would break the moment the
    /// phone moved networks.
    public enum Route: Hashable {
        case peer(peer: String)
        case workspaces(peer: String, session: String?)
        // `label` is display text, not an identifier, and it is here for the
        // same reason `pane` carries a title: the alternative is a screen
        // headed `w653998617a6031`. Workspace ids are opaque — CLAUDE.md is
        // explicit that they are not for display — and the label is in hand at
        // the moment the route is made.
        case agents(peer: String, session: String?, workspace: String?, label: String)
        case pane(peer: String, session: String?, target: String, title: String)
    }

    public func push(_ route: Route) { path.append(route) }

    public func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    public func popToRoot() { path = NavigationPath() }
}
