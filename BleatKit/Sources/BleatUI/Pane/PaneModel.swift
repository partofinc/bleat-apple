import BleatKit
import Foundation
import Observation

/// Streams one pane's rendered screen.
///
/// **Read-only.** `terminal session observe` cannot disturb whoever currently
/// holds input on the pane, which is the right default and the whole of Phase
/// 2 — Herdr allows one input owner per pane, and taking it from an agent
/// mid-run because someone glanced at their phone would be indefensible.
/// `control` and `--takeover` arrive in Phase 3, when there is a deliberate
/// gesture behind them.
///
/// The bytes are never inspected. `terminal.frame` payloads carry cursor
/// positioning and synchronized-output markers inside them, so they go to the
/// renderer exactly as they arrived.
@Observable
final class PaneModel {
    enum Phase: Equatable {
        /// Connecting, or waiting to learn what size to ask for.
        case opening
        case live
        /// The host closed the stream — the pane went away, or the session
        /// stopped. Distinct from a failure: nothing went wrong.
        case ended
        case failed(String)
    }

    private(set) var phase: Phase = .opening

    private let connections: ConnectionStore
    private let peer: PairedPeer
    private let session: String?
    private let target: String

    /// Set by the terminal view once it exists. Frames that arrive before then
    /// are held rather than dropped — the first one is the full-screen replay,
    /// and losing it means an empty pane until something else changes on the
    /// host, which on an idle pane is never.
    private var sink: ((Data) -> Void)?
    private var pending: [Data] = []

    private var stream: (any HerdrStream)?
    private var reader: Task<Void, Never>?
    /// The size last asked for, so a layout pass that changes nothing does not
    /// tear the stream down and rebuild it — and so `retry` knows what to
    /// reopen at.
    private var requested: (cols: Int, rows: Int)?

    init(connections: ConnectionStore, peer: PairedPeer, session: String?, target: String) {
        self.connections = connections
        self.peer = peer
        self.session = session
        self.target = target
    }

    /// Registers the renderer and hands it anything that arrived first.
    func attach(_ sink: @escaping (Data) -> Void) {
        self.sink = sink
        for data in pending { sink(data) }
        pending.removeAll()
    }

    /// Opens the stream at the size the view can actually show.
    ///
    /// The size is the view's, not the host's: `observe --cols --rows` makes
    /// Herdr render the pane at whatever the phone can display, so an 80-column
    /// pane arrives already reflowed rather than needing to be scrolled
    /// sideways. Called again on rotation, which reopens — the first frame of a
    /// new stream is `full: true`, so the screen simply redraws.
    func open(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        guard requested == nil || requested! != (cols, rows) else { return }
        start(cols: cols, rows: rows)
    }

    /// Opens again at the size already known.
    ///
    /// Needed because `open` deduplicates: without a way past that, a pane that
    /// failed — or whose socket dropped, which CLAUDE.md calls normal — stays
    /// dead until the user pops the screen and pushes it again.
    func retry() {
        guard let requested else { return }
        start(cols: requested.cols, rows: requested.rows)
    }

    private func start(cols: Int, rows: Int) {
        requested = (cols, rows)
        // Set here rather than inside `run`, which is a task away: closing the
        // old stream takes up to a second (see below), and leaving `.live` on
        // screen through it shows a stale pane with nothing to say it is stale.
        phase = .opening

        reader?.cancel()
        let previous = stream
        stream = nil
        // Closed *alongside* the new dial, not before it. `SSHStream.close()`
        // waits up to a second for output to drain, and an `observe` stream
        // never ends on its own, so that second is always spent — spending it
        // serially would delay every rotation by a full second.
        if let previous { Task { await previous.close() } }
        reader = Task { [weak self] in await self?.run(cols: cols, rows: rows) }
    }

    /// Closes the stream. There is no `terminal.release` to send: release is
    /// what an input *owner* does, and an observer never becomes one.
    func close() async {
        reader?.cancel()
        reader = nil
        // Forgotten, so a screen that comes back reopens rather than
        // deduplicating itself into a permanently blank pane.
        requested = nil
        let open = stream
        stream = nil
        await open?.close()
    }

    private func run(cols: Int, rows: Int) async {
        phase = .opening
        do {
            let client = try await connections.client(for: peer, session: session)
            let opened = try await client.observe(target, cols: cols, rows: rows)
            // A resize cancelled this reader while the channel was opening. It
            // is a live `herdr terminal session observe` on the host and
            // nothing else holds it, so installing it now would orphan it — or
            // worse, overwrite the stream the replacement reader just installed,
            // leaving the live one running and closing the dead one on exit.
            guard !Task.isCancelled else {
                await opened.close()
                return
            }
            stream = opened
            phase = .live

            for try await record in opened.records {
                guard case .frame(let frame) = record else { continue }
                // A frame whose base64 will not decode is the host's problem,
                // not a reason to tear the stream down; the next one is a
                // moment away and may well be a full redraw.
                guard let data = frame.data else { continue }
                deliver(data)
            }
            // The host closed it. On a pane that was removed, or a session that
            // stopped, this is the normal ending rather than an error.
            if !Task.isCancelled { phase = .ended }
        } catch is CancellationError {
            // The screen went away, or a resize replaced this reader.
        } catch {
            // Guarded *before* `handle`: a reader cancelled by a resize can
            // still surface a `TransportError` from the teardown, and handling
            // that would release the shared SSH connection out from under the
            // replacement reader already dialling on it.
            guard !Task.isCancelled else { return }
            await connections.handle(error)
            phase = .failed(ErrorMessage.of(error))
        }
    }

    private func deliver(_ data: Data) {
        if let sink { sink(data) } else { pending.append(data) }
    }
}
