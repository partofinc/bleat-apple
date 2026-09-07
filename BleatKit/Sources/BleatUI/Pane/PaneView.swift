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
    @State private var mode: PaneMode = .chat
    /// Whether the terminal has ever been asked for on this screen.
    ///
    /// It gates *mounting* the terminal, not showing it. Chat is the default
    /// now, and mounting the terminal regardless would open an `observe` stream
    /// — a live exec channel on someone's Mac — for every agent screen that is
    /// opened and read. Once asked for it stays mounted for the reasons below.
    @State private var terminalWasAskedFor = false
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

    #if DEBUG
    /// Preview-only: every model is handed in already settled, so no stream is
    /// opened and nothing is fetched.
    ///
    /// `capturedAt` is seeded alongside the reader's lines for the same reason
    /// `TranscriptModel`'s is: the screen keys its first load on that being
    /// nil, and a preview without one would go and read the pane.
    init(
        peer: PairedPeer,
        title: String,
        mode: PaneMode,
        pane: PaneModel = PaneModel(previewing: .live),
        text: Loadable<[String]> = .loaded(PreviewPaneText.lines),
        capturedAt: Date? = .now,
        transcript: TranscriptModel = TranscriptModel(previewing: .loaded(TranscriptEntry.samples))
    ) {
        self.title = title
        self.peer = peer
        _model = State(wrappedValue: pane)
        _text = State(wrappedValue: RemoteList(previewing: text))
        _transcript = State(wrappedValue: transcript)
        _mode = State(wrappedValue: mode)
        _terminalWasAskedFor = State(wrappedValue: mode == .terminal)
        _capturedAt = State(wrappedValue: capturedAt)
    }
    #endif

    var body: some View {
        ZStack {
            // **Once mounted, kept mounted rather than swapped out.** Tearing
            // the terminal down on every toggle would close the stream, and
            // reopening it costs a dial plus the second `SSHStream.close()`
            // spends draining — but worse, `close()` is async and a quick flip
            // back would race the reopen and tear down the fresh stream.
            // Hidden, the buffer and the stream both survive, so switching back
            // is instant and shows the screen as it stands rather than waiting
            // for a redraw the host only sends when a stream opens.
            if terminalWasAskedFor {
                PaneSurface(model: model, isActive: mode == .terminal)
                    .opacity(mode == .terminal ? 1 : 0)
                    .allowsHitTesting(mode == .terminal)
                    .accessibilityHidden(mode != .terminal)
            }

            if mode == .reader {
                PaneReaderView(lines: text.state, capturedAt: capturedAt, reload: load)
            }

            if mode == .chat {
                PaneChatView(
                    phase: transcript.phase,
                    status: transcript.status,
                    step: transcript.step,
                    capturedAt: transcript.capturedAt,
                    reload: { await transcript.load(for: peer) },
                    showTerminal: { mode = .terminal }
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
            case .terminal:
                terminalWasAskedFor = true
            case .reader:
                if capturedAt == nil { await load() }
            case .chat:
                if transcript.capturedAt == nil { await transcript.load(for: peer) }
                // Then keep following. `follow` returns immediately unless the
                // agent is working, so this costs nothing on an idle pane.
                await transcript.follow(for: peer)
            }
        }
        .onDisappear {
            transcript.stop()
            Task { await model.close() }
        }
    }

    private func load() async {
        await text.load(for: peer)
        // **`.loaded`, not `value != nil`.** A failed refresh over existing
        // lines produces `.stale(previous, message)`, whose `value` is the
        // *old* content — so the looser test restamped a twenty-minute-old
        // snapshot with the current time, which is exactly the misdating this
        // is here to avoid.
        if case .loaded = text.state { capturedAt = .now }
    }
}

#if DEBUG
/// The default mode, and the reason it is the default: the transcript never
/// went through a terminal, so it is the one reading of a pane that reflows to
/// a phone.
#Preview("Chat", traits: .sampleData) {
    NavigationStack {
        PaneView(peer: .preview, title: "Auditing the migration", mode: .chat)
    }
}

/// The reader: the pane's own output, wrapped to the device. Monospaced on
/// purpose — an agent's indentation is structural.
#Preview("Reader", traits: .sampleData) {
    NavigationStack {
        PaneView(peer: .preview, title: "swift test", mode: .reader)
    }
}

/// The terminal mounts SwiftTerm and, in a canvas, has no stream feeding it —
/// so what this shows is the chrome around an empty grid: the badge, the
/// read-only marker, and the mode picker.
#Preview("Terminal", traits: .sampleData) {
    NavigationStack {
        PaneView(peer: .preview, title: "w2:p1", mode: .terminal)
    }
}
#endif
