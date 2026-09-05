import BleatKit
import Observation

/// Loads the named sessions on one host.
///
/// A session is Herdr's outermost container, and it is selected by environment
/// rather than by a flag, so it is the first choice the app has to make before
/// any workspace or agent means anything.
@Observable
final class SessionsModel {
    private(set) var state: Loadable<[SessionInfo]> = .loading

    private let connections: ConnectionStore

    init(connections: ConnectionStore) {
        self.connections = connections
    }

    /// Connects if needed, then lists.
    ///
    /// Safe to call again, which is what pull-to-refresh and a retry both do.
    /// `HerdrClient` holds no per-connection state and `SSHTransport` re-dials
    /// on demand, so a socket dropped while the app was backgrounded needs
    /// nothing special here.
    func load(for peer: PairedPeer) async {
        state = .loading
        do {
            state = .loaded(try await connections.client(for: peer).sessions())
        } catch {
            state = .failed(String(describing: error))
        }
    }
}
