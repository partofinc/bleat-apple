import BleatKit
import Observation

/// Root state, injected once with `.environment()` and read everywhere.
///
/// It aggregates routers rather than holding every field itself, so a screen
/// depends on the one router it drives instead of on all app state.
@Observable
public final class AppContext {
    public let navigation: NavigationRouter
    public let hosts: HostStore

    public init(hosts: HostStore) {
        self.navigation = NavigationRouter()
        self.hosts = hosts
    }
}
