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

    public init(peers: PeerStore) {
        let reachability = Reachability()
        self.navigation = NavigationRouter()
        self.peers = peers
        self.reachability = reachability
        self.connections = ConnectionStore(peers: peers, reachability: reachability)
    }
}
