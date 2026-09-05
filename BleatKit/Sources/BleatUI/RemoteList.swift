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
        let previous = state.value
        if previous == nil { state = .loading }

        do {
            let client = try await connections.client(for: peer, session: session)
            let items = try await fetch(client)
            guard generation == self.generation else { return }
            state = .loaded(items)
        } catch is CancellationError {
            guard generation == self.generation else { return }
            // Our own task going away is silence: the screen has gone and there
            // is nobody to tell. A cancellation while this screen is still on
            // it came from the connection being released underneath us — and a
            // spinner that never resolves, with no rows and no way to retry, is
            // the worst of the outcomes available.
            guard !Task.isCancelled else { return }
            report("the connection closed before this finished", over: previous)
        } catch {
            // Guarded *before* `handle`: a superseded load that finally fails
            // would otherwise tear down the connection a newer, successful one
            // just established, and the next command would pay a full handshake
            // for it. If the newer load also fails, it calls `handle` itself.
            guard generation == self.generation else { return }
            await connections.handle(error)
            report(ErrorMessage.of(error), over: previous)
        }
    }

    /// A failure keeps whatever had already arrived, so one dropped packet on a
    /// pull-to-refresh does not replace a good list with an error page.
    private func report(_ message: String, over previous: [Item]?) {
        state = previous.map { .stale($0, message) } ?? .failed(message)
    }
}
