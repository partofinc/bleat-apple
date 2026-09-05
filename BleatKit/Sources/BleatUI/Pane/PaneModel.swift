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
    /// The size currently asked for, so a layout pass that changes nothing does
    /// not tear the stream down and rebuild it.
    private var size: (cols: Int, rows: Int)?

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
        guard size == nil || size! != (cols, rows) else { return }
        size = (cols, rows)

        reader?.cancel()
        let previous = stream
        stream = nil
        reader = Task { [weak self] in
            await previous?.close()
            await self?.run(cols: cols, rows: rows)
        }
    }

    /// Closes the stream. There is no `terminal.release` to send: release is
    /// what an input *owner* does, and an observer never becomes one.
    func close() async {
        reader?.cancel()
        reader = nil
        let open = stream
        stream = nil
        await open?.close()
    }

    private func run(cols: Int, rows: Int) async {
        phase = .opening
        do {
            let client = try await connections.client(for: peer, session: session)
            let opened = try await client.observe(target, cols: cols, rows: rows)
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
            await connections.handle(error)
            guard !Task.isCancelled else { return }
            phase = .failed(ErrorMessage.of(error))
        }
    }

    private func deliver(_ data: Data) {
        if let sink { sink(data) } else { pending.append(data) }
    }
}
