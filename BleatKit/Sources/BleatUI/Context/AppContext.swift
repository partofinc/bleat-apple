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
    /// The unpair flow. Here rather than in a screen's `@State` because it
    /// spans two of them — the peer list and a peer's detail — and because
    /// removing a device's access is not something a screen going away should
    /// abandon halfway.
    public let unpair: UnpairModel

    public init(peers: PeerStore) {
        let reachability = Reachability()
        let navigation = NavigationRouter()
        self.navigation = navigation
        self.peers = peers
        self.reachability = reachability
        let connections = ConnectionStore(peers: peers, reachability: reachability)
        self.connections = connections
        self.unpair = UnpairModel(peers: peers, connections: connections, navigation: navigation)
    }
}
