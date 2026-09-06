import BleatKit
import SwiftUI

/// One pane, read two ways.
///
/// Read-only either way: this is `terminal session observe` and `pane read`,
/// neither of which can disturb whoever holds input on the pane. The keyboard,
/// the accessory row and takeover are Phase 3.
struct PaneView: View {
    let title: String
    private let peer: PairedPeer
    private let connections: ConnectionStore

    @State private var model: PaneModel
    /// The pane's text, loaded on demand.
    ///
    /// `RemoteList` rather than a fetch written here: a snapshot *is* a list of
    /// lines, and the parts of loading that are easy to get wrong — the
    /// generation token, a cancelled screen staying silent, dropping a dead
    /// connection so the retry re-races — are identical to the three list
    /// screens and already solved there.
    @State private var text: RemoteList<String>
    @State private var transcript: TranscriptModel
    @State private var mode: PaneMode = .terminal
    /// When the snapshot was taken, so the reader can admit its age. The
    /// phone's clock, at the moment the answer arrived — the host does not
    /// stamp the payload.
    @State private var capturedAt: Date?

    init(
        peer: PairedPeer,
        session: String?,
        target: String,
        title: String,
        connections: ConnectionStore
    ) {
        self.title = title
        self.peer = peer
        self.connections = connections
        _model = State(wrappedValue: PaneModel(
            connections: connections, peer: peer, session: session, target: target
        ))
        _text = State(wrappedValue: RemoteList(
            connections: connections,
            session: session,
            fetch: { try await $0.paneText(target: target) }
        ))
        _transcript = State(wrappedValue: TranscriptModel(
            connections: connections, session: session, target: target
        ))
    }

    var body: some View {
        ZStack {
            // **Kept mounted rather than swapped out.** Tearing the terminal
            // down on every toggle would close the stream, and reopening it
            // costs a dial plus the second `SSHStream.close()` spends draining
            // — but worse, `close()` is async and a quick flip back would race
            // the reopen and tear down the fresh stream. Hidden, the buffer and
            // the stream both survive, so switching back is instant and shows
            // the screen as it stands rather than waiting for a redraw the host
            // only sends when a stream opens.
            PaneSurface(model: model)
                .opacity(mode == .terminal ? 1 : 0)
                .allowsHitTesting(mode == .terminal)
                .accessibilityHidden(mode != .terminal)

            if mode == .reader {
                PaneReaderView(lines: text.state, capturedAt: capturedAt, reload: load)
            }

            if mode == .transcript {
                PaneTranscriptView(
                    phase: transcript.phase,
                    capturedAt: transcript.capturedAt,
                    reload: { await transcript.load(for: peer) }
                )
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Icons rather than words: two labelled segments plus the
                // read-only marker crowd an inline title off an iPhone.
                Picker("How to read this pane", selection: $mode) {
                    ForEach(PaneMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol)
                            .labelStyle(.iconOnly)
                            .tag(mode)
                            .accessibilityLabel(mode.label)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) {
                // Says what the screen is, not just what it shows. Herdr allows
                // one input owner per pane, and a user looking at live output
                // deserves to know they are not it. True of both modes.
                Image(systemName: "eye")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Read-only")
            }
        }
        // Loaded when the reader is first shown and not before: it is a whole
        // exec channel, and most visits to this screen never open it. Keyed on
        // the mode so returning to a snapshot already taken does not re-read —
        // the footer says how old it is and pull-to-refresh is right there.
        .task(id: mode) {
            switch mode {
            case .terminal: break
            case .reader: if capturedAt == nil { await load() }
            case .transcript: if transcript.capturedAt == nil { await transcript.load(for: peer) }
            }
        }
        .onDisappear { Task { await model.close() } }
    }

    private func load() async {
        await text.load(for: peer)
        // Only on an answer. Stamping a failure would date a snapshot that
        // never arrived, and `Loadable.stale` deliberately keeps showing the
        // older one — which is the reading whose age still matters.
        if text.state.value != nil { capturedAt = .now }
    }
}
