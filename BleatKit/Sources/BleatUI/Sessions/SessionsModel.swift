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
    /// Bumped by every load, so a slow one that finishes late cannot overwrite
    /// a newer result. Without it an initial load that eventually times out
    /// lands *after* a successful pull-to-refresh and puts an error banner over
    /// rows that arrived perfectly well.
    private var generation = 0

    init(connections: ConnectionStore) {
        self.connections = connections
    }

    /// Connects if needed, then lists.
    ///
    /// Safe to call again, which is what pull-to-refresh and a retry both do.
    /// `HerdrClient` holds no per-connection state, so re-listing needs nothing
    /// special — but a connection that has *failed* is dropped rather than
    /// retried, so the next attempt races the peer's addresses again instead of
    /// asking a socket that the network moved out from under.
    func load(for peer: PairedPeer) async {
        generation += 1
        let generation = generation

        // Rows already on screen stay there. `refreshable` draws its own
        // spinner above them, and replacing them with "Reaching…" underneath it
        // is a downgrade twice over.
        if case .loaded = state {} else { state = .loading }

        do {
            let sessions = try await connections.client(for: peer).sessions()
            guard generation == self.generation else { return }
            state = .loaded(sessions)
        } catch is CancellationError {
            // The screen went away, or a newer load replaced this one. There is
            // nobody to tell and nothing to correct.
        } catch {
            await connections.handle(error)
            guard generation == self.generation else { return }
            state = .failed(ErrorMessage.of(error))
        }
    }
}
