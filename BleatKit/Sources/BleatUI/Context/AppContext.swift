import BleatKit
import Observation

/// Root state, injected once with `.environment()` and read everywhere.
///
/// It aggregates routers rather than holding every field itself, so a screen
/// depends on the one router it drives instead of on all app state.
@Observable
public final class AppContext {
    public let navigation: NavigationRouter
    public let peers: PeerStore
    public let reachability: Reachability
    public let connections: ConnectionStore
    /// How busy the connected host is. Here rather than in a screen's `@State`
    /// because the bar that shows it is carried down the drill-down — host,
    /// session, workspace — and those are three screens reading one answer.
    public let hostLoad: HostLoadStore
    /// The unpair flow. Here rather than in a screen's `@State` because it
    /// spans two of them — the peer list and a peer's detail — and because
    /// removing a device's access is not something a screen going away should
    /// abandon halfway.
    public let unpair: UnpairModel
    /// The pairing sheet. A router for the same reason `unpair` is one: it can
    /// be started from the peer list *or* by the system handing the app a
    /// `bleat://` link while any screen is on top.
    public let pairing = PairingRouter()
    /// The peer settings sheet. A router for the same reason the two above are:
    /// it is opened from the peer list *and* from a peer's own screen, which
    /// are in the navigation stack at the same time.
    public let peerSettings = PeerSettingsRouter()
    /// Whether iOS is letting the app onto the local network. Owned here, not
    /// by the pairing sheet, because the browser it watches has to outlive any
    /// one sheet — a permission granted after a sheet closed is still the
    /// answer the next one needs.
    public let localNetwork = LocalNetworkAccess()

    public init(peers: PeerStore) {
        let reachability = Reachability()
        let navigation = NavigationRouter()
        self.navigation = navigation
        self.peers = peers
        self.reachability = reachability
        let connections = ConnectionStore(peers: peers, reachability: reachability)
        self.connections = connections
        self.hostLoad = HostLoadStore(connections: connections, peers: peers)
        self.unpair = UnpairModel(peers: peers, connections: connections, navigation: navigation)
    }
}
