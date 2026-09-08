import BleatKit
import SwiftUI

/// One pane, read two ways, one behind the other.
///
/// **The terminal is the screen's background and is always live.** The chat
/// floats on glass over it, so the pane it is describing is visible through the
/// conversation about it rather than a mode away. That is the whole layout, and
/// it is what decides the two things below.
///
/// Read-only either way: the chat is a transcript file and the terminal is
/// `terminal session observe`, neither of which can take input from whoever
/// holds the pane. The keyboard, the accessory row and takeover are Phase 3.
struct PaneView: View {
    let title: String
    private let peer: PairedPeer

    @State private var model: PaneModel
    @State private var transcript: TranscriptModel
    @State private var mode: PaneMode = .chat

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
    }
    #endif

    var body: some View {
        ZStack {
            // Mounted once and never torn down. Tearing it down on a toggle
            // would close the stream, and reopening costs a dial plus the
            // second `SSHStream.close()` spends draining — but worse, `close()`
            // is async and a quick flip back would race the reopen and tear
            // down the fresh stream. It is behind the chat rather than swapped
            // out, so the buffer and the stream both simply stay.
            //
            // **`isActive: true` in both modes, because it really is on
            // screen.** The flag guards reporting a geometry — which reopens
            // the stream and `stty`s the pane on the user's Mac — and a size
            // read from a view nobody can see would be a write to someone's
            // machine on behalf of nothing. Visible through the glass, the
            // geometry is real.
            PaneSurface(model: model, isActive: true)
                // The chat is on top and takes the touches; the terminal
                // underneath is decoration until it is the mode. VoiceOver
                // likewise reads the conversation, not the grid behind it.
                .allowsHitTesting(mode == .terminal)
                .accessibilityHidden(mode != .terminal)

            if mode == .chat {
                PaneChatView(
                    phase: transcript.phase,
                    status: transcript.status,
                    step: transcript.step,
                    capturedAt: transcript.capturedAt,
                    reload: { await transcript.load(for: peer) },
                    showTerminal: { mode = .terminal }
                )
                // Glass rather than a solid fill: the pane stays legible
                // behind the conversation about it. On the *background* and
                // ignoring the safe area, so the material runs edge to edge
                // while the text stays inside it — `ignoresSafeArea` on the
                // chat itself would slide the newest turn under the home
                // indicator, which is the line the user came for.
                .background {
                    Color.clear
                        .glassEffect(in: .rect)
                        .ignoresSafeArea()
                }
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
                // Nothing to start: the stream is already open, because the
                // terminal has been on screen behind the chat the whole time.
                break
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
        // The terminal draws its own black and its chrome has to sit on it, so
        // the screen goes dark for that mode and hands the choice back for the
        // chat, which is ordinary prose and belongs in whatever the phone is
        // set to.
        //
        // **`nil`, not the current scheme.** `preferredColorScheme` is a
        // preference that travels *up* to the presentation, so what it sets
        // comes back down as `\.colorScheme` — reading that here and passing it
        // on for the chat means the terminal's `.dark` is read back as the
        // ambient value and re-asserted, and the screen never returns to light
        // once the terminal has been opened. `nil` is the way to say "no
        // preference"; nothing else on the stack sets one, so the phone's own
        // setting wins.
        .preferredColorScheme(mode == .terminal ? .dark : nil)
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
