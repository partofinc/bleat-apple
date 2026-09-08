#if os(iOS)
import BleatKit
import SwiftUI

/// Naming a new session: a scrim over the screen and one field above the
/// keyboard.
///
/// The whole file is iOS-only. `BleatUI` compiles for macOS, where the peer
/// screen has no bottom bar and so no plus button to open this — and where
/// `textInputAutocapitalization` does not exist either. Gating the file rather
/// than three modifiers inside it keeps the branch in one place; the model
/// (`NewSessionModel`) stays cross-platform, which is what lets `swift test`
/// exercise the logic on the Mac.
///
/// Presented in a `fullScreenCover` with a clear presentation background
/// rather than as an `.overlay`. An overlay lives inside the screen's content,
/// which on iOS 26 leaves the navigation bar undimmed and — worse — leaves the
/// floating bottom bar, including the plus button that opened this, drawn on
/// top of the scrim and still tappable. A cover is above all of it.
struct NewSessionField: View {
    @Bindable var model: NewSessionModel
    let peer: PairedPeer
    /// What the screen behind already knows is on the host, so the field can
    /// say that a name is taken — or that it would resume something — before
    /// the tap rather than after it.
    let known: [SessionInfo]
    let onStarted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            scrim
            bar
        }
        // Presented content paints its own backdrop; without this the cover is
        // an opaque sheet and the scrim below is invisible.
        .presentationBackground(.clear)
        .task {
            // A frame's grace before taking focus. Asking in `onAppear` races
            // the cover's own presentation, and losing that race leaves the
            // field unfocused with no keyboard — which is the entire layout.
            try? await Task.sleep(for: .milliseconds(50))
            focused = true
        }
        .onChange(of: model.name) { _, _ in model.clearFailure() }
    }

    /// Half transparent, and the way out.
    ///
    /// **Inert while the launch is in flight**, for the reason the pairing
    /// sheet refuses to be dismissed mid-swap: this is the only place the
    /// outcome is reported, and a launch whose result nobody sees is a session
    /// left running on someone's Mac that the user does not know about.
    private var scrim: some View {
        Rectangle()
            .fill(.black.opacity(0.35))
            .ignoresSafeArea()
            .contentShape(.rect)
            .onTapGesture { if !model.isStarting { dismiss() } }
            // The scrim is the only dismissal, so it has to be reachable
            // without seeing it.
            .accessibilityLabel("Cancel")
            .accessibilityAddTraits(.isButton)
            .accessibilityHidden(model.isStarting)
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note {
                Text(note.text)
                    .font(.footnote)
                    .foregroundStyle(note.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 6)
            }
            HStack(spacing: 12) {
                TextField("Session name", text: $model.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit(start)
                    .disabled(model.isStarting)
                confirm
            }
        }
        .padding(12)
        .glassEffect(in: .rect(cornerRadius: 26))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var confirm: some View {
        if model.isStarting {
            // Sized to the button it replaces, so the bar does not jump.
            ProgressView().frame(width: 34, height: 34)
        } else {
            // `Button(_:systemImage:)` with `.iconOnly` rather than a bare
            // `Image`: the label is what VoiceOver reads, and a checkmark on
            // its own says nothing about what it confirms.
            Button("Start session", systemImage: "checkmark", action: start)
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(!canStart)
            }
    }

    /// The one thing already-known sessions change: a name that is *running*
    /// cannot be started again — herdr refuses it — so the button is off rather
    /// than offering an action that has already failed before it is taken.
    private var canStart: Bool {
        model.canStart && model.existing(in: known)?.running != true
    }

    /// At most one line under the field, most urgent first.
    private var note: (text: String, isProblem: Bool)? {
        if let failure = model.failure { return (failure, true) }
        if let problem = model.nameProblem { return (problem, true) }
        guard let existing = model.existing(in: known) else { return nil }
        return existing.running
            ? ("\(existing.name) is already running on this host.", true)
            // Not a warning: herdr keeps a stopped session's directory, so
            // starting one of that name brings back the workspaces it had
            // rather than making an empty session. Measured, and surprising
            // enough to say out loud.
            : ("Resumes \(existing.name), which is stopped.", false)
    }

    private func start() {
        guard canStart else { return }
        Task {
            guard await model.start(on: peer) else { return }
            model.name = ""
            onStarted()
            dismiss()
        }
    }
}

#if DEBUG
/// Typing a name that is free.
#Preview("Naming", traits: .sampleData) {
    NewSessionPreview(model: NewSessionModel(previewing: "scratch"))
}

/// A name the host already has running, which herdr would refuse.
#Preview("Taken", traits: .sampleData) {
    NewSessionPreview(model: NewSessionModel(previewing: "work"))
}

/// A stopped session of that name: this resumes it rather than creating one.
#Preview("Resumes", traits: .sampleData) {
    NewSessionPreview(model: NewSessionModel(previewing: "bleat-test"))
}

/// herdr's own complaint, fetched from the launch log — the only channel a
/// detached launch has, and unreachable from a healthy host.
#Preview("Refused", traits: .sampleData) {
    NewSessionPreview(model: NewSessionModel(
        previewing: "work", failure: "herdr server is already running"
    ))
}

/// A name herdr will not take. Refused here so it never leaves the phone.
#Preview("Bad name", traits: .sampleData) {
    NewSessionPreview(model: NewSessionModel(previewing: "my session"))
}

/// Launched, waiting for the host to report it running.
#Preview("Starting", traits: .sampleData) {
    NewSessionPreview(model: NewSessionModel(previewing: "scratch", isStarting: true))
}

/// The cover is what puts this over a dimmed screen, so the previews show it
/// over something rather than on a blank canvas.
private struct NewSessionPreview: View {
    let model: NewSessionModel
    @State private var showing = true

    var body: some View {
        NavigationStack {
            PeerDetailView(peer: .preview, previewing: .loaded(SessionInfo.samples))
        }
        .fullScreenCover(isPresented: $showing) {
            NewSessionField(
                model: model, peer: .preview, known: SessionInfo.samples, onStarted: {}
            )
        }
    }
}
#endif
#endif
