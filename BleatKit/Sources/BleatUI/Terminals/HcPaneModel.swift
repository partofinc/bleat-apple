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
/// **A rotation is a RESIZE frame, not a reopen.** The viewer's size changes
/// in place and hc repaints. Reopening is kept for what needs it: a failure, a
/// retry, coming back after being hidden.
///
/// One `hc connect` per screen, on the shared SSH connection; the list
/// behind it has its own. The bytes are never inspected: they go to SwiftTerm
/// exactly as they arrived.
@Observable
final class HcPaneModel: PaneDriving {
    private(set) var wantsKeyboard = false
    private(set) var phase: PaneModel.Phase = .opening
    /// The grid the terminal shows and this viewer was attached or resized at.
    private(set) var grid: TerminalGrid?
    private(set) var rowHeight: CGFloat?

    let peer: PairedPeer
    let address: String
    private let connections: ConnectionStore

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
    private var isActive = true
    /// Set first in `close()`: nothing may attach once the screen is going.
    private var isClosing = false

    /// Input waiting to go out, oldest first. One drainer at a time, so keys
    /// arrive in the order they were pressed — see `PaneModel.outgoing`.
    private var outgoing: [Data] = []
    private var isDraining = false

    /// How many lines of scrollback the first paint carries. hc paints them
    /// only for a program on the main screen (a shell); a full-screen program
    /// scrolls itself, by wheel clicks — see `scroll`.
    static let history = 2000

    init(peer: PairedPeer, address: String, connections: ConnectionStore) {
        self.peer = peer
        self.address = address
        self.connections = connections
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

    /// The terminal measured itself. On first layout this attaches; after
    /// that, a different size is sent as a RESIZE on the live channel.
    func show(_ grid: TerminalGrid) {
        guard grid.isUsable else { return }
        viewport = grid
        guard let attached, phase == .live else {
            // Not attached yet: the attach in flight catches up with the
            // latest size once it lands.
            if reader == nil { start() }
            return
        }
        guard grid != self.grid else { return }
        resize(to: grid, on: attached)
    }

    /// Changes this viewer's size in place; hc reflows the program and repaints.
    private func resize(to grid: TerminalGrid, on attached: (client: HcClient, channel: UInt32)) {
        self.grid = grid
        var payload = Data()
        payload.append(littleEndian: UInt16(clamping: grid.cols))
        payload.append(littleEndian: UInt16(clamping: grid.rows))
        let frame = HcFrame(channel: attached.channel, kind: .resize, payload: payload)
        Task { try? await attached.client.send(frame) }
    }

    func setRowHeight(_ height: CGFloat) {
        guard height > 0, height != rowHeight else { return }
        rowHeight = height
    }

    func retry() {
        guard viewport != nil else { return }
        start()
    }

    /// Hidden, the viewer goes away and the Mac gets its size back; shown
    /// again, it attaches afresh and the first paint redraws everything.
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
        await enqueue([Data(line.text.utf8), TerminalKey.enter.bytes])
    }

    func send(bytes: Data) async {
        guard !bytes.isEmpty else { return }
        await enqueue([bytes])
    }

    /// hc has no scroll command: the terminal on screen decides — wheel clicks
    /// for a program that asked for the mouse, its own history otherwise. See
    /// `TerminalHost`.
    func scroll(_ direction: ScrollDirection, notches: Int) async {
        guard notches > 0 else { return }
        scroller?(direction, notches)
    }

    private func enqueue(_ chunks: [Data]) async {
        outgoing.append(contentsOf: chunks)
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while !outgoing.isEmpty {
            guard let attached else { return outgoing.removeAll() }
            let frame = HcFrame(channel: attached.channel, kind: .data, payload: outgoing.removeFirst())
            try? await attached.client.send(frame)
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
        guard let hcPath = peer.herdrCore?.path else {
            phase = .failed("this host has not been checked for herdr-core")
            return
        }
        var client: HcClient?
        do {
            let link = try await connections.link(for: peer)
            guard let opener = link as? any HcStreamOpening else {
                phase = .failed("herdr-core is not reachable this way yet")
                return
            }
            let stream = try await opener.openHcConnection(hcPath: hcPath)
            try await withTaskCancellationHandler {
                let connected = try await HcClient.connect(over: stream)
                client = connected
                let result = try await connected.call("terminal.attach", [
                    "terminal": .string(address),
                    "cols": .number(Double(size.cols)),
                    "rows": .number(Double(size.rows)),
                    "history": .number(Double(Self.history)),
                ])
                guard let channel = result["channel"]?.uint32 else { throw HcProtocolError.notFramed }
                // Replaced by a newer attach while this one was opening:
                // installing it would orphan a viewer on the host.
                try Task.checkCancellation()
                let screen = await connected.channel(channel)
                attached = (connected, channel)
                grid = size
                phase = .live
                // Measured again while the attach was opening (a rotation).
                if let latest = viewport, latest != size { resize(to: latest, on: (connected, channel)) }
                for try await chunk in screen {
                    deliver(chunk)
                    // Credit once the bytes are in the terminal, which is when
                    // they have been dealt with.
                    await connected.grant(chunk.count, on: channel)
                }
                // The core closed the channel: the program ended, or the
                // terminal was removed.
                if !Task.isCancelled {
                    phase = .ended
                    wantsKeyboard = false
                }
            } onCancel: {
                Task { await stream.close() }
            }
        } catch {
            guard !Task.isCancelled else { return }
            await client?.close()
            attached = nil
            phase = .failed(ErrorMessage.of(error))
            wantsKeyboard = false
            if case HcProtocolError.closed = error {
                await connections.release()
            } else {
                await connections.handle(error)
            }
        }
    }

    private func deliver(_ data: Data) {
        guard let sink else { return pending.append(data) }
        sink(data)
    }

    /// The screen is going: the viewer leaves, and the Mac gets its size back.
    func close() async {
        isClosing = true
        wantsKeyboard = false
        let attached = self.attached
        detach()
        if let attached { await attached.client.close() }
    }

    #if DEBUG
    private var isPreview = false

    /// Parked in one phase, for `#Preview`.
    convenience init(previewing phase: PaneModel.Phase) {
        let peers = PeerStore(registry: .sample())
        self.init(
            peer: .preview, address: "t58",
            connections: ConnectionStore(peers: peers, reachability: Reachability())
        )
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
