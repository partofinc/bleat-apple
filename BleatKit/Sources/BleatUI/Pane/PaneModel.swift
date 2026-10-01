import BleatKit
import Foundation
import Observation

/// Streams one pane's rendered screen, holding its input.
///
/// **The terminal always takes the pane.** It opens `terminal session control
/// --takeover` and never `observe`: everything the terminal is for — scrolling,
/// answering a dialog, typing — sends, and a `control` attach that is not a
/// takeover is silently inert while anyone else holds the pane (measured 8 Sept
/// 2026). A read-only mode with a "Take control" step in front of every one of
/// those was removed on 1 Oct 2026; whoever is typing at the Mac loses input
/// for as long as this terminal is on screen.
///
/// **On screen, not merely mounted.** The terminal stays mounted while the chat
/// is showing, and holding the pane through that would take it from the Mac for
/// a whole visit spent reading. `setActive(false)` releases it and
/// `setActive(true)` takes it back.
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

    /// Whether the user has asked for the system keyboard.
    ///
    /// **Raised by an explicit button, never by tapping the pane.** A tap that
    /// happened to land on the terminal would otherwise start sending
    /// keystrokes to a live agent, and a drag misread as a tap is not exotic on
    /// a surface whose whole job is to be dragged. The button is also the only
    /// version of this that VoiceOver and Switch Control can reach.
    ///
    /// Put down whenever the pane is let go of — hidden, closed, or a stream
    /// that ended — since a keystroke would have nowhere to go.
    private(set) var wantsKeyboard = false
    private(set) var phase: Phase = .opening
    /// The grid everything agrees on: what the terminal shows, what the pane's
    /// pty was set to, and what the stream was opened at.
    ///
    /// One number rather than three. The terminal sizes itself to the screen,
    /// the host is asked to make the pty exactly that, and the stream is opened
    /// at it — so there is no grid to reconcile against another and no window
    /// in which they differ.
    private(set) var grid: TerminalGrid?
    /// How tall one row of the terminal is drawn, in points, once it has laid
    /// out. What `PaneScrollGesture` sizes a notch by — and deliberately the
    /// terminal's own figure rather than one worked out from the space the
    /// surface is given, which shrinks under the keyboard while the grid does
    /// not.
    private(set) var rowHeight: CGFloat?

    /// Whether Bleat made the pane this size.
    private(set) var didResizePane = false
    /// The pane's grid before Bleat first resized it, so it can be put back.
    ///
    /// Set once, on the first successful resize, and kept across rotations —
    /// the thing to restore is what the Mac had, not the previous orientation.
    private var restoreTo: TerminalGrid?

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

    /// Whether the terminal is on screen, and so whether the pane is held.
    private var isActive = true
    /// The release sent when the terminal was hidden, still on its way out. A
    /// takeover waits for it, so the old stream's release cannot land after the
    /// new stream has taken the pane.
    private var letGo: Task<Void, Never>?

    /// Whether `close()` has begun. Once it has, nothing may open a stream —
    /// including a layout pass caused by the close itself.
    private var isClosing = false

    /// Read by `PaneGeometryTests` to check that the chrome around the terminal
    /// does not change its size between phases — the shape of bug that put an
    /// endless spinner on a device. `terminalFrameForTesting` exists for the
    /// same reason one level down.
    var viewportForTesting: TerminalGrid? { viewport }

    #if DEBUG
    /// Preview-only: `start()` returns early, so no stream is opened.
    private var isPreview = false

    /// Parked in one phase, for `#Preview`.
    ///
    /// Three of the four are only reachable from a host that stops answering,
    /// and each is a `ContentUnavailableView` with its own way back — which is
    /// exactly the sort of thing worth laying out in a canvas rather than by
    /// unplugging a Mac.
    convenience init(
        previewing phase: Phase,
        grid: TerminalGrid? = TerminalGrid(cols: 142, rows: 47)
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
    /// not optional — the stream sends a full redraw only when it opens, so a
    /// stream left running after the terminal changed shape would keep painting
    /// frames written for the old one, and nothing would ever repair it.
    func show(_ grid: TerminalGrid) {
        guard grid.isUsable else { return }
        let previous = viewport
        viewport = grid
        guard opened != nil else { return start() }
        if previous != grid { start() }
    }

    /// The terminal draws its rows this tall. Nothing is sent: this is only
    /// how far a finger travels per row.
    func setRowHeight(_ height: CGFloat) {
        guard height > 0, height != rowHeight else { return }
        rowHeight = height
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
        // A close is in flight and the screen is going: see `close()`. Or the
        // terminal is hidden, and opening would take the pane for nobody.
        guard !isClosing, isActive else { return }
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
        // The same for input going the other way: a keystroke typed at the old
        // stream must not arrive at whatever replaces it, seconds later and out
        // of context.
        outgoing.removeAll()
        let previous = stream
        stream = nil
        // Closed *alongside* the new dial, not before it. `SSHStream.close()`
        // waits up to a second for output to drain, and a stream
        // never ends on its own, so that second is always spent — spending it
        // serially would delay every reopen by a full second.
        if let previous { Task { await previous.close() } }
        reader = Task { [weak self] in await self?.run() }
    }

    /// Takes the pane while the terminal is on screen and lets go of it while
    /// it is not.
    ///
    /// **Released rather than left held.** Hidden, nothing on this phone can
    /// send — but holding still takes input from whoever is at the Mac, for as
    /// long as somebody reads the chat. Coming back costs a reopen, which the
    /// first frame of a takeover repaints in full.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            if viewport != nil { start() }
        } else {
            suspend()
        }
    }

    /// Releases the pane and closes the stream, keeping everything needed to
    /// take it back — unlike `close()`, which is the screen going away.
    private func suspend() {
        wantsKeyboard = false
        reader?.cancel()
        reader = nil
        pending.removeAll()
        outgoing.removeAll()
        // Forgotten, so the next `show()` or `setActive(true)` opens rather
        // than deduplicating itself into a blank terminal.
        opened = nil
        phase = .opening
        let held = stream
        stream = nil
        // `terminal.release` rather than just closing, for the reason `close()`
        // sends it: it is the clean detach, and it is what tells herdr the pane
        // is free again rather than leaving that to a dropped channel.
        let previous = letGo
        letGo = Task {
            await previous?.value
            try? await held?.send(.release)
            await held?.close()
        }
    }

    /// Sends the program one of its own keys.
    ///
    /// Dropped while there is no stream — opening, hidden, or ended.
    func send(_ key: TerminalKey) async {
        await send(bytes: key.bytes)
    }

    /// Scrolls the pane by `notches` wheel notches.
    ///
    /// **`terminal.scroll`, never wheel bytes, and herdr decides what it
    /// means.** Measured on 0.9.3, 30 Sept 2026: for a shell it moves herdr's
    /// own history by `lines`; for a full-screen program — `less --mouse`,
    /// Claude Code — herdr turns each record into one wheel event and the
    /// program scrolls itself, ignoring `lines`. Ten records moved Claude Code
    /// as far as ten raw wheel sequences did. Sending the raw sequence instead
    /// is worse in exactly the case the phone cannot detect: herdr drops mouse
    /// modes from the frames, so nothing here knows whether the program asked
    /// for a mouse, and a shell handed `ESC[<64;…M` types `64;10;10M` at its
    /// prompt. `max_offset_from_bottom` is no signal either — a fresh shell
    /// reports 0 exactly as a full-screen program does.
    ///
    /// **One record per notch, never one record for the lot.** `lines` could
    /// carry the whole distance for a shell, but a full-screen program gets one
    /// wheel event per record whatever it says, and nothing here knows which
    /// kind of pane this is.
    ///
    /// One line a notch, so a shell's history moves a row for a row of finger
    /// travel. Queued like a keystroke, so a drag never overtakes typing.
    ///
    /// **Dropped when the queue is already long.** A scroll is a request about
    /// now: on a link too slow to keep up, queued notches would go on
    /// scrolling the pane long after the finger stopped. Keys are never
    /// dropped this way — only scrolls, which the next drag replaces.
    func scroll(_ direction: ScrollDirection, notches: Int = 1) async {
        guard notches > 0, outgoing.count < Self.scrollBacklog else { return }
        await send(Array(repeating: .scroll(direction: direction, lines: 1), count: notches))
    }

    /// How much may be waiting to go out before a scroll is not worth adding
    /// to it: about a fifth of a second of the fastest coast.
    private static let scrollBacklog = 30

    /// Input waiting to go out, oldest first, and whether anyone is draining it.
    ///
    /// **Order is the whole point.** Every keystroke used to get its own
    /// unstructured `Task`, and a task per chunk is a race: each one runs on
    /// the main actor only until `stream.send` suspends, after which any number
    /// of them are inside `SSHStream.send` at once with nothing sequencing the
    /// writes. Fast typing could transpose two characters into a live agent —
    /// and SwiftTerm's `paste` is worse, calling `send` three times in one
    /// runloop turn (bracketed-paste start, the text, the end), so the markers
    /// could land around or after the payload they are meant to wrap.
    private var outgoing: [TerminalCommand] = []
    private var isDraining = false

    /// Sends what the keyboard produced, byte for byte.
    ///
    /// **`.bytes`, never `.text`.** SwiftTerm hands over the encoded bytes a
    /// terminal would send, which for anything but a plain character includes a
    /// raw ESC — and a raw ESC inside a JSON string is not legal JSON, so herdr
    /// would answer `input ignored` on stderr and the screen simply would not
    /// move. The same reason `TerminalKey` travels this way.
    ///
    /// Nothing here inspects or filters the bytes. They are what the user
    /// typed; deciding which of them a program is allowed to receive is not
    /// this layer's business, and a filter would break exactly the control
    /// sequences an agent's UI is driven by.
    func send(bytes: Data) async {
        guard !bytes.isEmpty else { return }
        await send([.bytes(bytes)])
    }

    private func send(_ commands: [TerminalCommand]) async {
        // Enqueued and drained by one caller at a time. Both halves run on the
        // main actor with no suspension between the append and the check, so
        // the queue order is the order the keys were pressed.
        outgoing.append(contentsOf: commands)
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while !outgoing.isEmpty {
            guard let stream else { return outgoing.removeAll() }
            try? await stream.send(outgoing.removeFirst())
        }
    }

    /// Asks for or dismisses the system keyboard.
    func setWantsKeyboard(_ wanted: Bool) {
        wantsKeyboard = wanted
    }

    /// Releases the pane and closes the stream: the screen is going away.
    func close() async {
        // **Set first.** This function suspends, so SwiftUI gets a layout pass
        // in the middle of it, and a layout pass that reports a grid finds
        // `opened` nil and calls `start()` — taking the pane *after the user
        // has left the screen*, an orphaned stream on their Mac, which is the
        // one thing `ConnectionStore` promises not to leave. Nothing may reopen
        // once a close has begun.
        isClosing = true
        wantsKeyboard = false
        // **Before the reader is cancelled**, or there is no live stream left
        // to send it on and the pane stays owned by a phone that has walked
        // away — herdr would hold it until the channel drops.
        try? await stream?.send(.release)
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
        didResizePane = false
        let open = stream
        stream = nil
        await open?.close()
    }

    private func run() async {
        phase = .opening
        // The release from the last time the terminal was hidden goes first;
        // see `letGo`.
        await letGo?.value
        do {
            let client = try await connections.client(for: peer, session: session)
            guard let size = viewport, size.isUsable else {
                phase = .failed("Bleat could not work out what size to render \(target) at.")
                return
            }
            let pane = try await paneSize(from: client)
            let fit = pane.flatMap { PtyResize.target(viewport: size, pane: $0) }

            // **Resize, let it settle, then open.** `stty` raises SIGWINCH and
            // the program repaints on its own schedule, and the stream sends a
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
            // `--takeover` because there is no other way in: without it a
            // second client gets no frames and lands no input while anyone else
            // holds the pane, and says nothing about why.
            let opened = try await client.attach(
                to: target, cols: size.cols, rows: size.rows, takeover: true
            )
            // A reopen cancelled this reader while the channel was opening. It
            // is a live `herdr terminal session control` on the host and
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
            if !Task.isCancelled {
                phase = .ended
                // Nothing left to type into. The key bar greys itself out here;
                // the system keyboard cannot, so it has to be put away or every
                // keystroke is dropped in silence.
                wantsKeyboard = false
            }
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
            wantsKeyboard = false
        }
    }

    /// Makes the pane's pty match this screen, so the program inside wraps to
    /// it.
    ///
    /// **The only thing that actually reflows a pane.** `--cols` crops
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

    /// The pane's real grid on the host, which is what the pty is resized
    /// from and later put back to. `nil` when the host
    /// will not say, which is not a failure — the stream opens either way now.
    ///
    /// `HerdrError` and `DecodingError` give up; `TransportError` does not.
    ///
    /// The first two are both "this host will not tell me the layout" — a herdr
    /// too old to know `pane layout`, a pane just closed, or a reply whose shape
    /// has moved — and losing the resize is not worth losing the pane. A
    /// `TransportError` is a different thing and is left to propagate:
    /// swallowing it would spend a second opening a stream that cannot open
    /// either, and report the wrong cause when it failed.
    private func paneSize(from client: HerdrClient) async throws -> TerminalGrid? {
        do {
            let layout = try await client.paneLayout(target: target)
            // A tab that does not contain this pane. A sibling's rect would
            // resize this pane's pty to somebody else's width.
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
