import BleatKit
import Foundation
import Observation

/// One herdr-core terminal's live screen, and the phone's input into it.
///
/// **Attached as an active viewer, at the phone's grid, from the first
/// frame** — chosen 12 Nov 2026 over watching first. hc gives the terminal's
/// size and colours to the most recently active typing viewer
/// (`viewers.rs`), so attaching takes over and the program reflows to the
/// phone. Watching first would have drawn the Mac's ~130 columns on a phone,
/// cropped or shrunk; and scrolling counts as input in hc anyway.
///
/// **Leaving gives the Mac its size back, with nothing to undo.** Closing the
/// channel removes this viewer, and hc hands the size to the next most recent
/// active one — the Mac's Herdr.app. 1.x had to `stty` a pty and put it back
/// by hand; there is no counterpart here.
///
/// **A rotation is a RESIZE frame, not a reopen**, sent through the same
/// ordered queue as keys so the two cannot overtake each other.
///
/// **Every attach is checked against being replaced, at each point it could
/// write.** A retry or a return to the screen starts a new attach while the
/// old one may still be mid-flight; one that resumes after being replaced
/// must neither install itself nor paint its buffered bytes into the
/// terminal the new one is drawing.
///
/// One `hc connect` per attach, on the shared SSH connection; the list behind
/// it has its own. The bytes are never inspected: they go to SwiftTerm exactly
/// as they arrived.
@Observable
final class HcPaneModel: PaneDriving {
    private(set) var wantsKeyboard = false
    private(set) var phase: PanePhase = .opening
    /// The grid the core last accepted for this viewer.
    private(set) var grid: TerminalGrid?
    private(set) var rowHeight: CGFloat?

    let address: String

    /// Opens a fresh `hc connect` byte stream. The app's goes through
    /// `ConnectionStore`; a test passes a scripted one.
    private let open: () async throws -> any HerdrStream
    /// Told about a failure, so a dead SSH connection is dropped and the next
    /// attach dials afresh. **Never `release()` here**: one terminal's stream
    /// ending says nothing about the connection the list is also using.
    private let report: (any Error) async -> Void

    private var sink: ((Data) -> Void)?
    /// Frames that arrived before the renderer. The first is the first paint;
    /// dropping it leaves an idle terminal blank for good.
    private var pending: [Data] = []
    private var scroller: ((ScrollDirection, Int) -> Void)?

    /// The live attach: the client, and the channel the screen comes on.
    private var attached: (client: HcClient, channel: UInt32)?
    private var reader: Task<Void, Never>?
    /// What the terminal last measured, and so what to attach or resize at.
    private var viewport: TerminalGrid?
    /// Whether the screen is on show. Off screen, nothing is attached: the
    /// Mac has the terminal back.
    private var isActive = true
    /// Set first in `close()`: nothing may attach once the screen is gone.
    private var isClosing = false

    /// What goes out on the channel, in the order it was asked for.
    private enum Outgoing {
        case data(Data)
        case resize(TerminalGrid)
    }

    /// One drainer at a time, so keys and resizes arrive in the order they
    /// happened — see `PaneModel.outgoing` for the race this avoids.
    private var outgoing: [Outgoing] = []
    private var isDraining = false

    /// How many lines of scrollback the first paint carries. hc paints them
    /// only for a program on the main screen (a shell); a full-screen program
    /// scrolls itself — see `TerminalHost`.
    static let history = 2000

    convenience init(peer: PairedPeer, address: String, connections: ConnectionStore) {
        self.init(
            address: address,
            open: {
                guard let hcPath = peer.herdrCore?.path else {
                    throw HcPaneFailure.notChecked
                }
                let link = try await connections.link(for: peer)
                guard let opener = link as? any HcStreamOpening else { throw HcPaneFailure.noRoute }
                return try await opener.openHcConnection(hcPath: hcPath)
            },
            report: { error in await connections.handle(error) }
        )
    }

    init(
        address: String,
        open: @escaping () async throws -> any HerdrStream,
        report: @escaping (any Error) async -> Void
    ) {
        self.address = address
        self.open = open
        self.report = report
    }

    // MARK: - The renderer

    func attach(_ sink: @escaping (Data) -> Void) {
        self.sink = sink
        for data in pending { sink(data) }
        pending.removeAll()
    }

    func attachScroller(_ scroller: @escaping (ScrollDirection, Int) -> Void) {
        self.scroller = scroller
    }

    /// The terminal measured itself. The first time, this attaches; after
    /// that, a different size goes out as a RESIZE on the live channel.
    func show(_ grid: TerminalGrid) {
        guard grid.isUsable else { return }
        viewport = grid
        guard attached != nil, phase == .live else {
            // Not attached yet: the attach in flight catches up with the
            // latest size once it lands.
            if reader == nil { start() }
            return
        }
        Task { await enqueue([.resize(grid)]) }
    }

    func setRowHeight(_ height: CGFloat) {
        guard height > 0, height != rowHeight else { return }
        rowHeight = height
    }

    func retry() {
        guard viewport != nil else { return }
        start()
    }

    /// On screen, attach; off it, let go, so the Mac has the terminal back.
    ///
    /// **Off screen is not gone.** A covering sheet or an iPad column change
    /// takes the screen away with its state kept, and it comes back. Treating
    /// that as the end left a frozen frame that still claimed to be live.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            if viewport != nil { start() }
        } else {
            wantsKeyboard = false
            detach()
            phase = .opening
        }
    }

    func setWantsKeyboard(_ wanted: Bool) {
        wantsKeyboard = wanted
    }

    // MARK: - Input

    func send(_ key: TerminalKey) async {
        await send(bytes: key.bytes)
    }

    func send(_ keys: [TerminalKey], spacedBy pause: Duration) async {
        for (index, key) in keys.enumerated() {
            if index > 0 { try? await Task.sleep(for: pause) }
            await send(key)
        }
    }

    /// The composed line, then Enter, queued together so nothing typed meanwhile
    /// lands between them.
    ///
    /// Not `terminal.send`: that waits for ~3 s without typing and refuses a
    /// blocked program, which suits an agent sending to another agent. Here the
    /// person at the phone is the one typing.
    func submit(_ line: SubmittedLine) async {
        await enqueue([.data(Data(line.text.utf8)), .data(TerminalKey.enter.bytes)])
    }

    func send(bytes: Data) async {
        guard !bytes.isEmpty else { return }
        await enqueue([.data(bytes)])
    }

    /// hc has no scroll command: the terminal on screen decides. See
    /// `TerminalHost`.
    func scroll(_ direction: ScrollDirection, notches: Int) async {
        guard notches > 0 else { return }
        scroller?(direction, notches)
    }

    private func enqueue(_ items: [Outgoing]) async {
        outgoing.append(contentsOf: items)
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while !outgoing.isEmpty {
            guard let attached else { return outgoing.removeAll() }
            let item = outgoing.removeFirst()
            switch item {
            case .data(let bytes):
                try? await attached.client.send(HcFrame(channel: attached.channel, kind: .data, payload: bytes))
            case .resize(let size):
                guard size != grid else { continue }
                var payload = Data()
                payload.append(littleEndian: UInt16(clamping: size.cols))
                payload.append(littleEndian: UInt16(clamping: size.rows))
                // The grid is what the core accepted, so it moves only once the
                // frame is on its way; a send that failed leaves it as it was.
                do {
                    try await attached.client.send(HcFrame(channel: attached.channel, kind: .resize, payload: payload))
                    grid = size
                } catch {}
            }
        }
    }

    // MARK: - Attaching

    private func start() {
        guard !isClosing, isActive else { return }
        #if DEBUG
        if isPreview { return }
        #endif
        phase = .opening
        detach()
        reader = Task { [weak self] in await self?.run() }
    }

    /// Ends the current attach, if any. The channel closing is what removes
    /// this viewer at the core.
    private func detach() {
        reader?.cancel()
        reader = nil
        pending.removeAll()
        outgoing.removeAll()
        if let attached {
            Task { await attached.client.close() }
        }
        attached = nil
    }

    private func run() async {
        guard let size = viewport else { return }
        var client: HcClient?
        do {
            let stream = try await open()
            try await withTaskCancellationHandler {
                let connected = try await HcClient.connect(over: stream)
                client = connected
                let attachment = try HcAttachment(reply: try await connected.call("terminal.attach", [
                    "terminal": .string(address),
                    "cols": .number(Double(size.cols)),
                    "rows": .number(Double(size.rows)),
                    "history": .number(Double(Self.history)),
                ]))
                let screen = await connected.channel(attachment.channel)
                // **After the last suspension, right before anything is
                // written.** Checked any earlier, a run replaced while it hopped
                // onto the client would still install itself as live, and keys
                // and resizes would go to a client nobody reads.
                try Task.checkCancellation()
                attached = (connected, attachment.channel)
                grid = size
                phase = .live
                // Measured again while the attach was opening — a rotation.
                if let latest = viewport, latest != size { await enqueue([.resize(latest)]) }
                for try await chunk in screen {
                    // A replaced attach can still have chunks buffered; painted
                    // into the terminal the new one is drawing, they would mix
                    // two screens.
                    guard !Task.isCancelled else { break }
                    deliver(chunk)
                    // Credit once the bytes are in the terminal, which is when
                    // they have been dealt with.
                    await connected.grant(chunk.count, on: attachment.channel)
                }
                guard !Task.isCancelled else { return }
                // The core closed the channel: the program ended, or the
                // terminal was removed. Nothing is left to type into, and the
                // `hc connect` behind it is closed rather than left open.
                attached = nil
                outgoing.removeAll()
                await connected.close()
                phase = .ended
                wantsKeyboard = false
            } onCancel: {
                Task { await stream.close() }
            }
        } catch {
            guard !Task.isCancelled else {
                await client?.close()
                return
            }
            await client?.close()
            attached = nil
            phase = .failed(ErrorMessage.of(error))
            wantsKeyboard = false
            await report(error)
        }
    }

    private func deliver(_ data: Data) {
        guard let sink else { return pending.append(data) }
        sink(data)
    }

    /// The screen is gone for good: the viewer leaves, and the Mac gets its
    /// size back. `setActive(false)` is the one for a screen that may return.
    func close() async {
        isClosing = true
        wantsKeyboard = false
        let attached = self.attached
        detach()
        phase = .ended
        if let attached { await attached.client.close() }
    }

    #if DEBUG
    private var isPreview = false

    /// Parked in one phase, for `#Preview`.
    convenience init(previewing phase: PanePhase) {
        self.init(address: "t58", open: { throw CancellationError() }, report: { _ in })
        isPreview = true
        self.phase = phase
        grid = TerminalGrid(cols: 53, rows: 30)
    }
    #endif
}

extension Data {
    fileprivate mutating func append(littleEndian value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
