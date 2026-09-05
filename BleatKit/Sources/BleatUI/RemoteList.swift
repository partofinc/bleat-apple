import BleatKit
import Observation

/// A list fetched from a host: sessions, workspaces, agents.
///
/// One type rather than three, because the loading itself is where the subtle
/// parts are and they are identical for all three — a generation token, a
/// cancelled screen saying nothing, a dead connection being dropped so the
/// retry can re-race, and rows staying on screen through a refresh. Three
/// copies of that would drift, and each way it drifts is a bug the user sees
/// rather than a crash anyone catches.
@Observable
final class RemoteList<Item: Sendable> {
    private(set) var state: Loadable<[Item]> = .loading

    private let connections: ConnectionStore
    /// The Herdr session these items belong to. Applied to the connection
    /// before every fetch, because it is a command prefix — `HERDR_SESSION` —
    /// rather than anything the handshake settles.
    private let session: String?
    private let fetch: @Sendable (HerdrClient) async throws -> [Item]
    /// Bumped by every load, so a slow one that finishes late cannot overwrite
    /// a newer result. Without it an initial load that eventually times out
    /// lands *after* a successful pull-to-refresh and puts an error banner over
    /// rows that arrived perfectly well.
    private var generation = 0

    init(
        connections: ConnectionStore,
        session: String?,
        fetch: @escaping @Sendable (HerdrClient) async throws -> [Item]
    ) {
        self.connections = connections
        self.session = session
        self.fetch = fetch
    }

    /// Connects if needed, then fetches.
    ///
    /// Safe to call again, which is what pull-to-refresh and a retry both do.
    /// `HerdrClient` holds no per-connection state, so re-fetching needs nothing
    /// special — but a connection that has *failed* is dropped rather than
    /// retried, so the next attempt races the peer's addresses again instead of
    /// asking a socket the network moved out from under.
    func load(for peer: PairedPeer) async {
        generation += 1
        let generation = generation

        // Rows already on screen stay there. `refreshable` draws its own
        // spinner above them, and replacing them with a placeholder underneath
        // it is a downgrade twice over.
        if case .loaded = state {} else { state = .loading }

        do {
            let client = try await connections.client(for: peer, session: session)
            let items = try await fetch(client)
            guard generation == self.generation else { return }
            state = .loaded(items)
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
