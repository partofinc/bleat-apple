import BleatKit
import Observation
import SwiftUI

/// Where the app is: which host is being browsed, and how far into it.
///
/// **Two pieces, because the screen has two columns.** `NavigationSplitView`
/// puts the host list in the sidebar and everything below a host in the detail
/// column's stack, so the host is a *selection* and the rest is a path. On a
/// phone the split view collapses and the two behave as the single drill-down
/// they always were — hosts → session → workspaces → agents → pane — with the
/// selection acting as the first push.
///
/// A tab router joins this when there is a second tab to route to; adding one
/// now would be a router with a single case.
@Observable
public final class NavigationRouter {
    /// The host on display: the sidebar's selection and the detail column's
    /// root. A **host key**, for the reason every route carries one.
    ///
    /// Computed over a stored property so that **changing it clears the stack
    /// in the same write**. Everything on the path is a screen *of the host
    /// being left* — its sessions, its workspaces, one of its panes — and
    /// SwiftUI evaluates the detail column from the new selection and the old
    /// path together. Clearing it afterwards in an `onChange` would draw one
    /// host's workspaces under another host's name for a frame first.
    public var selectedPeer: String? {
        get { browsing }
        set {
            guard newValue != browsing else { return }
            browsing = newValue
            path = NavigationPath()
        }
    }

    private var browsing: String?

    /// The detail column: everything below the selected host.
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
        /// The detail column's **root**, and the one route that is never
        /// pushed: it is what `selectedPeer` names. It stays a route so that
        /// `RouteView` remains the single place a route becomes a screen —
        /// including its answer for a host that has been unpaired while its
        /// screens were up.
        case peer(peer: String)
        case workspaces(peer: String, session: String?)
        // `label` is display text, not an identifier, and it is here for the
        // same reason `pane` carries a title: the alternative is a screen
        // headed `w653998617a6031`. Workspace ids are opaque — CLAUDE.md is
        // explicit that they are not for display — and the label is in hand at
        // the moment the route is made.
        case agents(peer: String, session: String?, workspace: String?, label: String)
        /// `mode` is the reading the pane opens in. It is part of the route
        /// rather than a default inside the screen because the two entrances want
        /// different ones: an agent row opens the chat, which is the reading that
        /// reflows to a phone, while "Open the pane" on a blocked agent has to
        /// show the dialog — and a transcript is exactly what that user does not
        /// need. It is part of the route's identity, which is correct: the same
        /// pane opened two ways is two screens.
        case pane(
            peer: String, session: String?, target: String, title: String, mode: PaneMode = .chat
        )
    }

    public func push(_ route: Route) { path.append(route) }

    public func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    /// Leaves a host's screens — but only if they are the ones on display.
    ///
    /// **The guard is what the sidebar made necessary.** Unpairing pops,
    /// because a pane view left on top would go on asking a connection that is
    /// gone; but with the host list permanently on screen a host can be
    /// unpaired by a swipe *while a different one is being browsed*, and an
    /// unconditional pop would throw away that host's screens for something
    /// that did not happen to it.
    public func leave(_ hostKey: String) {
        guard browsing == hostKey else { return }
        selectedPeer = nil
    }
}
