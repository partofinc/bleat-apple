import BleatKit
import SwiftUI

/// One pane, read two ways, one at a time.
///
/// **Tried and rejected: the terminal as a permanent background with the chat
/// on glass over it.** It looked good and could not be read — a conversation
/// over a live 47-row grid is two things competing for the same pixels, and
/// glass tinted by a black terminal leaves prose with nowhere near enough
/// contrast. So a mode is a mode: the chat has the system's own background and
/// the terminal is on screen only when it is chosen.
///
/// The chat is a transcript file and disturbs nobody. **The terminal takes the
/// pane** — `PaneModel` holds its input for as long as the terminal is on
/// screen and lets go when the chat is — so choosing the terminal is the
/// gesture, and there is no second one behind it. Whoever is typing at the Mac
/// loses input until the phone goes back to the chat or leaves.
struct PaneView: View {
    let title: String
    private let peer: PairedPeer

    @State private var model: PaneModel
    @State private var transcript: TranscriptModel
    @State private var mode: PaneMode = .chat
    /// Whether the terminal has ever been asked for on this screen.
    ///
    /// It gates *mounting* the terminal, not showing it. Chat is the default,
    /// and mounting the terminal regardless would take the pane — a live exec
    /// channel on someone's Mac, their input, and an `stty` that reflows their
    /// pane — for every agent screen that is opened and read. Once asked for it
    /// stays mounted, for the reasons in the body.
    @State private var terminalWasAskedFor = false

    init(
        peer: PairedPeer,
        session: String?,
        target: String,
        title: String,
        mode: PaneMode = .chat,
        connections: ConnectionStore
    ) {
        self.title = title
        self.peer = peer
        _mode = State(wrappedValue: mode)
        // Opening straight into the terminal is also asking for it to be
        // mounted; `terminalWasAskedFor` gates that, and the `.task` would
        // otherwise not set it until the mode changed *to* terminal.
        _terminalWasAskedFor = State(wrappedValue: mode == .terminal)
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
            // the view down on every toggle would throw away the rendered
            // buffer, and `close()` is async — a quick flip back would race
            // the reopen. Hidden, the buffer survives; the *stream* does not,
            // because `PaneModel.setActive(false)` releases the pane, and the
            // takeover on the way back repaints in full.
            //
            // Hidden by `opacity`, and `isActive` false with it: the view still
            // lays out, and a size reported from one nobody is looking at
            // reopens the stream and `stty`s the pane on the user's Mac.
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
                // Icons rather than words: two labelled segments crowd an
                // inline title off an iPhone.
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
            // Before anything suspends: the pane is let go of the moment the
            // chat is chosen, not when the transcript has loaded.
            model.setActive(mode == .terminal)
            switch mode {
            case .terminal:
                terminalWasAskedFor = true
            case .chat:
                // Cleared rather than merely hidden, so switching back to the
                // terminal does not silently raise a keyboard nobody asked for
                // again — and so the toggle's own icon stays honest.
                model.setWantsKeyboard(false)
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
        .animation(.easeInOut, value: mode)
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
/// scroll keys, the key bar and the mode picker.
#Preview("Terminal", traits: .sampleData) {
    NavigationStack {
        PaneView(peer: .preview, title: "w2:p1", mode: .terminal)
    }
}
#endif
