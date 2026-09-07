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

    /// Whether Bleat made the pane this size.
    private(set) var didResizePane = false
    /// The pane's grid before Bleat first resized it, so it can be put back.
    ///
    /// Set once, on the first successful resize, and kept across rotations —
    /// the thing to restore is what the Mac had, not the previous orientation.
    private var restoreTo: TerminalGrid?

    /// Whether output is being cut off horizontally.
    ///
    /// Only when the pane could *not* be resized: then `observe --cols` crops
    /// rather than reflows, and asking for fewer columns than the pane holds
    /// loses everything to the right. Rows are not counted — asking for fewer
    /// keeps the bottom, where the prompt and newest output are.
    ///
    /// **`scroll.viewport_rows` is not used for this.** It looked like the way
    /// to detect a pane whose pty had drifted, but it lags: measured at 44
    /// while the pty was 47 and the rect 48, which made every resized pane
    /// claim to be cropped.
    var isCropped: Bool {
        guard !didResizePane, grid != nil else { return false }
        // **No layout reported is the cropped case, not the safe one.** Without
        // a rect there is nothing to resize the pty to, so the stream is opened
        // at this phone's width against a pane that is very likely wider — the
        // exact situation the badge exists for. Reading it as "not cropped"
        // silenced the warning precisely when it was needed.
        guard let paneGrid else { return true }
        // The one column herdr reserves of the rect does not count as a crop.
        return grid!.cols < paneGrid.cols - 1
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

    #if DEBUG
    /// Preview-only: `start()` returns early, so no `observe` stream is opened.
    private var isPreview = false

    /// Parked in one phase, for `#Preview`.
    ///
    /// Three of the four are only reachable from a host that stops answering,
    /// and each is a `ContentUnavailableView` with its own way back — which is
    /// exactly the sort of thing worth laying out in a canvas rather than by
    /// unplugging a Mac.
    convenience init(
        previewing phase: Phase,
        grid: TerminalGrid? = TerminalGrid(cols: 142, rows: 47),
        paneGrid: TerminalGrid? = TerminalGrid(cols: 142, rows: 47)
    ) {
        let peers = PeerStore(registry: .sample())
        self.init(
            connections: ConnectionStore(peers: peers, reachability: Reachability()),
            peer: .preview,
            session: "work",
            target: "w2:p1"
        )
        isPreview = true
        self.phase = phase
        self.grid = grid
        self.paneGrid = paneGrid
    }
    #endif

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
        #if DEBUG
        // A preview: the phase was handed in and there is no stream to open.
        // Before the assignment below, or a seeded `.failed` would be replaced
        // by a spinner on the terminal's first layout pass.
        if isPreview { return }
        #endif
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
        // **Put the pane back.** Bleat narrowed someone's pty to suit a phone;
        // leaving it that way means the next person at the Mac finds their
        // agent wrapped at 53 columns with nothing to explain it. Best effort
        // and deliberately not awaited into the failure path: the screen is
        // going away either way.
        if let restoreTo, didResizePane {
            let peer = self.peer
            let target = self.target
            let connections = self.connections
            Task { await Self.restore(to: restoreTo, target: target, peer: peer, connections: connections) }
        }
        restoreTo = nil
        // Forgotten, so a screen that comes back reopens rather than
        // deduplicating itself into a permanently blank pane.
        opened = nil
        grid = nil
        paneGrid = nil
        didResizePane = false
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
            let pane = try await paneSize(from: client)
            let fit = pane.flatMap { PtyResize.target(viewport: size, pane: $0) }

            // **Resize, let it settle, then open.** `stty` raises SIGWINCH and
            // the program repaints on its own schedule, and `observe` sends a
            // full redraw only when it opens — so the opening frame is the one
            // chance to capture a settled screen. Opening first and letting the
            // repaint arrive as deltas sounds equivalent and is not: a repaint
            // that only rewrites what it thinks changed leaves whatever the
            // opening frame caught mid-flight, which is how a pane's input box
            // and status line ended up composited onto one row. Measured at
            // rest, the same pane renders them as four clean rows.
            // **Guarded before the resize, not just before the assignment.** A
            // reopen cancels this reader while it is suspended in `paneSize` or
            // `paneProcessInfo`; the replacement then resizes the pty to the new
            // orientation and opens its stream, and this one would resume and
            // `stty` the same tty back to the *pre-rotation* width — leaving the
            // host's pty disagreeing with the live stream, so every line wraps.
            // A write to someone's machine is the last thing that should run on
            // a reader that has already been replaced.
            guard !Task.isCancelled else { return }

            var resized = false
            if let fit {
                resized = await resizePty(to: fit, on: peer, client: client)
                if resized { try? await Task.sleep(for: .milliseconds(350)) }
            }
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
            didResizePane = resized
            if resized { restoreTo = restoreTo ?? pane }
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

    /// Makes the pane's pty match this screen, so the program inside wraps to
    /// it.
    ///
    /// **The only thing that actually reflows a pane.** `observe --cols` crops
    /// rather than reflows and no stream client can change a pane's grid, but
    /// the program writes at the width of its pty and a pty can be set from
    /// outside. Verified on a clean pane: 53 columns grown to 100 came back
    /// genuinely wrapped at 100.
    ///
    /// Best effort — no tty, no permission, a herdr without `pane process-info`
    /// all fall back to reading the pane at the size it already has.
    @discardableResult
    private func resizePty(
        to grid: TerminalGrid,
        on peer: PairedPeer,
        client: HerdrClient
    ) async -> Bool {
        do {
            let info = try await client.paneProcessInfo(target: target)
            guard let pid = info.pid,
                  let command = PtyResize.command(pid: pid, cols: grid.cols, rows: grid.rows)
            else { return false }
            // The plain-shell seam, not herdr: there is no herdr command that
            // sets a pane's size, which is the whole reason this exists.
            let output = try await connections.shell(for: peer).run(shell: command)
            // The command prints its marker only when `stty` actually
            // succeeded; it exits 0 either way, so the status says nothing.
            return output.contains(PtyResize.marker)
        } catch {
            return false
        }
    }

    /// Puts a pane's pty back to the size it had before Bleat touched it.
    ///
    /// Static because it outlives the screen: `close()` returns immediately and
    /// this finishes on its own, so it must not hold the model.
    private static func restore(
        to grid: TerminalGrid,
        target: String,
        peer: PairedPeer,
        connections: ConnectionStore
    ) async {
        do {
            let client = try await connections.client(for: peer)
            let info = try await client.paneProcessInfo(target: target)
            guard let pid = info.pid,
                  let command = PtyResize.command(pid: pid, cols: grid.cols, rows: grid.rows)
            else { return }
            _ = try await connections.shell(for: peer).run(shell: command)
        } catch {
            // The connection is being released as this runs, so a failure here
            // is ordinary. The pane is left narrow, which the next client at
            // the Mac corrects by attaching.
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
