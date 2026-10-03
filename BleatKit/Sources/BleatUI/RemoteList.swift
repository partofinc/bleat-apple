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

    /// Optional for exactly one reason: `init(previewing:)` below, which is
    /// `#if DEBUG` and is the only thing that ever leaves it nil. Production
    /// callers all pass one.
    private let connections: ConnectionStore?
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

    /// **This empty deinit is load-bearing. Do not delete it.**
    ///
    /// Without it, `swift-frontend` 6.3.3 segfaults building this module with
    /// optimisation on — `SILFunctionTransform "EarlyPerfInliner" on
    /// SILFunction "@$s7BleatUI10RemoteListCfD"`, which is this class's
    /// *synthesized* deallocating destructor. Writing the destructor out, even
    /// empty, is enough to avoid whatever shape the inliner chokes on; the
    /// members are still released exactly as before, so this changes nothing at
    /// runtime.
    ///
    /// It only bites in a release build, so `swift build`, `swift test` and
    /// every debug run on a device are all green with it removed. What it
    /// actually blocks is archiving the app — TestFlight and the App Store.
    /// Reproduce in six seconds with `swift build -c release --target BleatUI`.
    ///
    /// Swift 6.4 builds it without this (re-tested 3 Oct 2026); it stays until
    /// an archive has been made without it. See docs/concurrency.md.
    deinit {}

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
        // A preview: the rows were handed in, and there is nothing to fetch.
        // First, before the state is touched — a seeded `.failed` is a state
        // somebody wants to look at, and moving it to `.loading` on the way out
        // would show a spinner instead.
        guard let connections else { return }
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
            report(.unreachable("the connection closed before this finished"), over: previous)
        } catch {
            // Guarded *before* `handle`: a superseded load that finally fails
            // would otherwise tear down the connection a newer, successful one
            // just established, and the next command would pay a full handshake
            // for it. If the newer load also fails, it calls `handle` itself.
            guard generation == self.generation else { return }
            await connections.handle(error)
            report(ErrorMessage.failure(of: error), over: previous)
        }
    }

    #if DEBUG
    /// A list that is already loaded and will never connect, for `#Preview`.
    ///
    /// The seam that keeps previews off the network. Every screen here loads in
    /// `.task`, so a preview built the ordinary way would race a real peer's
    /// endpoints from the canvas — spending a connect timeout and then drawing
    /// a connection error over the layout somebody was trying to look at.
    init(previewing state: Loadable<[Item]>) {
        self.connections = nil
        self.session = nil
        self.fetch = { _ in [] }
        self.state = state
    }
    #endif

    /// A failure keeps whatever had already arrived, so one dropped packet on a
    /// pull-to-refresh does not replace a good list with an error page.
    private func report(_ failure: LoadFailure, over previous: [Item]?) {
        state = previous.map { .stale($0, failure) } ?? .failed(failure)
    }
}
