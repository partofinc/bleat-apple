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
    /// The grid everything agrees on: what the terminal shows, what the pane's
    /// pty was set to, and what the stream was opened at.
    ///
    /// One number rather than three. The terminal sizes itself to the screen,
    /// the host is asked to make the pty exactly that, and `observe` is opened
    /// at it — so there is no grid to reconcile against another and no window
    /// in which they differ.
    private(set) var grid: TerminalGrid?
    /// The pane's own grid, when the host would say. Only used to tell whether
    /// anything is being cut off.
    private(set) var paneGrid: TerminalGrid?

    /// Whether output is being cut off horizontally.
    ///
    /// `observe --cols` crops rather than reflows, so asking for fewer columns
    /// than the pane has loses everything to the right. Rows are not counted:
    /// asking for fewer keeps the *bottom* of the pane, which is where the
    /// prompt and the newest output are, and is the right answer rather than a
    /// loss.
    var isCropped: Bool {
        guard let grid, let paneGrid else { return false }
        return grid.cols < paneGrid.cols
    }

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
    /// What the stream was opened at, so a layout pass that changes nothing
    /// does not tear it down and rebuild it.
    private var opened: TerminalGrid?
    /// However much of the pane this phone can show. Now the size that is asked
    /// for, rather than a fallback.
    private var viewport: TerminalGrid?

    init(connections: ConnectionStore, peer: PairedPeer, session: String?, target: String) {
        self.connections = connections
        self.peer = peer
        self.session = session
        self.target = target
    }

    /// Registers the renderer and hands it anything that arrived first.
    func attach(_ sink: @escaping (Data) -> Void) {
        self.sink = sink
        flush()
    }

    /// The terminal is now this size: match the host to it.
    ///
    /// Called on first layout and on every rotation. Reopening on a change is
    /// not optional — `observe` sends a full redraw only when it opens, so a
    /// stream left running after the terminal changed shape would keep painting
    /// frames written for the old one, and nothing would ever repair it.
    func show(_ grid: TerminalGrid) {
        guard grid.isUsable else { return }
        let previous = viewport
        viewport = grid
        guard opened != nil else { return start() }
        if previous != grid { start() }
    }

    /// Opens again.
    ///
    /// Needed because `open` deduplicates: without a way past that, a pane that
    /// failed — or whose socket dropped, which CLAUDE.md calls normal — stays
    /// dead until the user pops the screen and pushes it again.
    func retry() {
        guard viewport != nil else { return }
        start()
    }

    private func start() {
        // Set here rather than inside `run`, which is a task away: closing the
        // old stream takes up to a second (see below), and leaving `.live` on
        // screen through it shows a stale pane with nothing to say it is stale.
        phase = .opening

        reader?.cancel()
        // Dropped, not kept: anything buffered was drawn for the size the old
        // stream was opened at, and feeding it into the new one would wrap.
        pending.removeAll()
        let previous = stream
        stream = nil
        // Closed *alongside* the new dial, not before it. `SSHStream.close()`
        // waits up to a second for output to drain, and an `observe` stream
        // never ends on its own, so that second is always spent — spending it
        // serially would delay every reopen by a full second.
        if let previous { Task { await previous.close() } }
        reader = Task { [weak self] in await self?.run() }
    }

    /// Closes the stream. There is no `terminal.release` to send: release is
    /// what an input *owner* does, and an observer never becomes one.
    func close() async {
        reader?.cancel()
        reader = nil
        // Forgotten, so a screen that comes back reopens rather than
        // deduplicating itself into a permanently blank pane.
        opened = nil
        grid = nil
        paneGrid = nil
        let open = stream
        stream = nil
        await open?.close()
    }

    private func run() async {
        phase = .opening
        do {
            let client = try await connections.client(for: peer, session: session)
            guard let size = viewport, size.isUsable else {
                phase = .failed("Bleat could not work out what size to render \(target) at.")
                return
            }
            // The pane's own grid, for the badge. **Nothing is written to the
            // host.** Resizing a live pane's pty was tried and does not work:
            // the pane's buffer keeps the wrapping it already had and neither
            // herdr nor the program reflows it, so every widen leaves the old
            // lines wrapped at the old width — text interleaved at the seam,
            // permanently. Measured at 100 and again at 90 columns against a
            // buffer written at 54, and corrupt both times.
            let pane = try await paneSize(from: client)

            let opened = try await client.observe(
                target, cols: size.cols, rows: size.rows
            )
            // A reopen cancelled this reader while the channel was opening. It
            // is a live `herdr terminal session observe` on the host and
            // nothing else holds it, so installing it now would orphan it — or
            // worse, overwrite the stream the replacement reader just installed,
            // leaving the live one running and closing the dead one on exit.
            //
            // **Nothing above is written before this point.** A reader
            // suspended in `size()` across a rotation resumes with the
            // pre-rotation viewport in hand, and writing it here would clobber
            // the size the live reader had just installed — leaving the screen
            // rendering one grid while the stream sends another, and a rotation
            // back deduplicated into doing nothing.
            guard !Task.isCancelled else {
                await opened.close()
                return
            }
            self.opened = size
            grid = size
            paneGrid = pane
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
            // The screen went away, or a reopen replaced this reader.
        } catch {
            // Guarded *before* `handle`: a reader cancelled by a reopen can
            // still surface a `TransportError` from the teardown, and handling
            // that would release the shared SSH connection out from under the
            // replacement reader already dialling on it.
            guard !Task.isCancelled else { return }
            await connections.handle(error)
            phase = .failed(ErrorMessage.of(error))
        }
    }

    /// The pane's real grid on the host, for the badge. `nil` when the host
    /// will not say, which is not a failure — the stream opens either way now.
    ///
    /// `HerdrError` and `DecodingError` give up; `TransportError` does not.
    ///
    /// The first two are both "this host will not tell me the layout" — a herdr
    /// too old to know `pane layout`, a pane just closed, or a reply whose shape
    /// has moved — and losing the badge is not worth losing the pane. A
    /// `TransportError` is a different thing and is left to propagate:
    /// swallowing it would spend a second opening a stream that cannot open
    /// either, and report the wrong cause when it failed.
    private func paneSize(from client: HerdrClient) async throws -> TerminalGrid? {
        do {
            let layout = try await client.paneLayout(target: target)
            // A tab that does not contain this pane. A sibling's rect would
            // make the badge claim a crop that is not happening.
            return layout.rect(ofPane: target)
                .map { TerminalGrid(cols: $0.width, rows: $0.height) }
        } catch is HerdrError {
            return nil
        } catch is DecodingError {
            return nil
        }
    }

    /// Holds a frame until there is a renderer for it.
    ///
    /// No size check any more: the stream is opened at the size the terminal
    /// already reported, so a frame can only ever be the right shape for it. A
    /// rotation tears the stream down and clears `pending` before the new one
    /// opens, so a frame written for the old shape cannot survive into the new.
    private func deliver(_ data: Data) {
        guard let sink else { return pending.append(data) }
        sink(data)
    }

    private func flush() {
        guard let sink else { return }
        for data in pending { sink(data) }
        pending.removeAll()
    }
}
