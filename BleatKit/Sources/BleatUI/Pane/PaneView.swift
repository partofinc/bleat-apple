import BleatKit
import SwiftUI

/// One pane, read two ways.
///
/// Read-only either way: the chat is a transcript file and the terminal is
/// `terminal session observe`, neither of which can disturb whoever holds input
/// on the pane. The keyboard, the accessory row and takeover are Phase 3.
struct PaneView: View {
    let title: String
    private let peer: PairedPeer

    @State private var model: PaneModel
    @State private var transcript: TranscriptModel
    @State private var mode: PaneMode = .chat
    /// Whether the terminal has ever been asked for on this screen.
    ///
    /// It gates *mounting* the terminal, not showing it. Chat is the default
    /// now, and mounting the terminal regardless would open an `observe` stream
    /// — a live exec channel on someone's Mac — for every agent screen that is
    /// opened and read. Once asked for it stays mounted for the reasons below.
    @State private var terminalWasAskedFor = false

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
        _transcript = State(wrappedValue: TranscriptModel(
            connections: connections, session: session, target: target
        ))
    }

    #if DEBUG
    /// Preview-only: every model is handed in already settled, so no stream is
    /// opened and nothing is fetched.
    ///
    /// The models default to **nil** and are built in the body rather than in
    /// the argument list. A default argument is evaluated on every call, and
    /// `State(wrappedValue:)` keeps only the first — so defaulting them to
    /// `PaneModel(previewing:)` meant every re-evaluation of a parent body
    /// seeded a temporary directory and started two `NWPathMonitor`s, then
    /// discarded them.
    init(
        peer: PairedPeer,
        title: String,
        mode: PaneMode,
        pane: PaneModel? = nil,
        transcript: TranscriptModel? = nil
    ) {
        self.title = title
        self.peer = peer
        _model = State(wrappedValue: pane ?? PaneModel(previewing: .live))
        _transcript = State(
            wrappedValue: transcript ?? TranscriptModel(previewing: .loaded(TranscriptEntry.samples))
        )
        _mode = State(wrappedValue: mode)
        _terminalWasAskedFor = State(wrappedValue: mode == .terminal)
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
        .toolbarBackground(.clear, for: .navigationBar)
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
                .labelsHidden()
            }
        }
        // Keyed on the mode: the transcript is a whole exec channel and most
        // of a visit to this screen is spent in one mode, so neither is loaded
        // until it is asked for.
        .task(id: mode) {
            switch mode {
            case .terminal:
                terminalWasAskedFor = true
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

/// The terminal mounts SwiftTerm and, in a canvas, has no stream feeding it —
/// so what this shows is the chrome around an empty grid: the badge, the
/// read-only marker, and the mode picker.
#Preview("Terminal", traits: .sampleData) {
    NavigationStack {
        PaneView(peer: .preview, title: "w2:p1", mode: .terminal)
    }
}
#endif
