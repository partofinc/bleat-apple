#if os(iOS)
import BleatKit
import SwiftUI

/// Naming a new workspace: a directory, and what to call it.
///
/// **A form rather than the one-line bar `NewSessionField` uses, and the
/// difference is the point.** A session takes a short name and nothing else, so
/// a field above the keyboard is the whole interaction. A workspace takes an
/// absolute path — long, easy to mistype, and the thing herdr is silently
/// wrong about — plus a label, and CLAUDE.md already asked for "a deliberate
/// gesture showing the label and cwd before it acts, rather than a bare `+`".
/// This is that gesture: both values visible, the directories the host is
/// already using offered as taps, and nothing sent until the host has agreed
/// the directory is there.
///
/// The whole file is iOS-only, like `NewSessionField`: `BleatUI` compiles for
/// macOS, where there is no bottom bar to open this from and where
/// `textInputAutocapitalization` does not exist. `NewWorkspaceModel` stays
/// cross-platform, which is what lets `swift test` exercise the logic on the
/// Mac.
struct NewWorkspaceForm: View {
    @Bindable var model: NewWorkspaceModel
    let peer: PairedPeer
    /// What the screen behind already knows is in this session, so the label
    /// field can say a name is taken before the tap rather than after it.
    let known: [Workspace]
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?

    private enum Field: Hashable { case path, label }

    var body: some View {
        NavigationStack {
            Form {
                if let note { outcome(note) }
                directorySection
                if !model.suggestions.isEmpty { suggestionsSection }
                labelSection
            }
            .navigationTitle("New Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.isCreating)
                }
                ToolbarItem(placement: .confirmationAction) { confirm }
            }
        }
        // The suggestions are the reason most creates need no typing at all, so
        // they are fetched as the sheet opens rather than on demand.
        .task { await model.loadSuggestions(for: peer) }
        // **Not dismissible while the create is in flight**, for the reason the
        // pairing sheet is not: this is the only place the outcome is reported,
        // and a workspace made on someone's Mac that nobody was told about is
        // the failure this whole screen is built to avoid.
        .interactiveDismissDisabled(model.isCreating)
        .onChange(of: model.path) { _, _ in model.clearFailure() }
        .task {
            // A frame's grace before taking focus, the same race
            // `NewSessionField` loses without it: asking during the sheet's own
            // presentation leaves the field unfocused with no keyboard.
            try? await Task.sleep(for: .milliseconds(50))
            if model.path.isEmpty { focus = .path }
        }
    }

    // MARK: - Sections

    private var directorySection: some View {
        Section {
            TextField("/Users/you/Project", text: $model.path)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .path)
                .onSubmit { focus = .label }
                .disabled(model.isCreating)
        } header: {
            Text("Directory")
        } footer: {
            if let problem = model.pathProblem {
                Text(problem).foregroundStyle(.red)
            } else {
                // Says what the pane will be, because "workspace" does not
                // imply it: herdr opens one tab holding one pane running a
                // login shell, and an agent is a separate step it does not do.
                Text("The workspace opens here with a shell in it. Starting an agent is a separate step.")
            }
        }
    }

    private var suggestionsSection: some View {
        Section("In use on this host") {
            ForEach(model.suggestions, id: \.self) { path in
                Button {
                    model.path = path
                    focus = nil
                } label: {
                    // Truncated at the head, for the reason the pane rows are:
                    // every path here starts `/Users/…/Developer/…` and the tail
                    // is the only part that tells one checkout from another.
                    Text(path)
                        .truncationMode(.head)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.path == path ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
        }
        .disabled(model.isCreating)
    }

    private var labelSection: some View {
        Section {
            TextField(model.labelPlaceholder, text: $model.label)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focus, equals: .label)
                .onSubmit(create)
                .disabled(model.isCreating)
        } header: {
            Text("Label")
        } footer: {
            if let duplicate {
                // Not a problem: herdr allows two workspaces with one label —
                // measured, both were created and both appear in the list — so
                // this is a heads-up rather than a refusal.
                Text("There is already a workspace called \(duplicate) here.")
            } else {
                Text("Leave this empty to use the folder's name.")
            }
        }
    }

    @ViewBuilder
    private func outcome(_ note: (text: String, isProblem: Bool)) -> some View {
        Section {
            Text(note.text)
                .foregroundStyle(note.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        }
    }

    @ViewBuilder
    private var confirm: some View {
        if model.isCreating {
            ProgressView()
        } else if model.warning != nil {
            // Something may exist on the host. Offering "Create" again would
            // risk a second one; the only thing left is to read the message and
            // leave. `NewWorkspaceModel.reset` is what clears this, on the next
            // deliberate open.
            Button("Done") { dismiss() }
        } else {
            Button("Create", action: create).disabled(!model.canCreate)
        }
    }

    // MARK: - Wiring

    /// At most one message, most urgent first.
    private var note: (text: String, isProblem: Bool)? {
        if let failure = model.failure { return (failure, true) }
        // Not red: something may well be on the host whether or not the user
        // likes where. Red would read as "nothing happened", which is the one
        // thing this state is telling them not to assume.
        if let warning = model.warning { return (warning, false) }
        return nil
    }

    private var duplicate: String? {
        let typed = model.trimmedLabel
        let wanted = typed.isEmpty ? model.directory?.suggestedLabel : typed
        guard let wanted, !wanted.isEmpty else { return nil }
        return known.first { $0.label == wanted }?.label
    }

    private func create() {
        guard model.canCreate else { return }
        focus = nil
        Task {
            switch await model.create(on: peer) {
            case .created:
                onCreated()
                dismiss()
            case .warned:
                // The list still has to be refreshed — a workspace may well be
                // there — but the sheet stays up, because this is the only
                // place that says what happened to it.
                onCreated()
            case .failed:
                break
            }
        }
    }
}

#if DEBUG
/// The ordinary case: a directory picked from the host's own list.
#Preview("Naming", traits: .sampleData) {
    NewWorkspacePreview(model: NewWorkspaceModel(
        previewing: "/Users/robin/Developer/partofinc/bleat-apple",
        suggestions: Pane.sampleDirectories
    ))
}

/// A path that cannot work, refused before anything leaves the phone.
#Preview("Relative path", traits: .sampleData) {
    NewWorkspacePreview(model: NewWorkspaceModel(
        previewing: "Developer/bleat-apple", suggestions: Pane.sampleDirectories
    ))
}

/// The one that looks absolute and is not — nothing on the host expands it.
#Preview("Tilde", traits: .sampleData) {
    NewWorkspacePreview(model: NewWorkspaceModel(previewing: "~/Developer"))
}

/// The host answered: there is no such directory. Nothing was created.
#Preview("No such directory", traits: .sampleData) {
    NewWorkspacePreview(model: NewWorkspaceModel(
        previewing: "/Users/robin/Developr",
        failure: "There is no directory at /Users/robin/Developr on this host."
    ))
}

/// **Created, and not where it was asked to go.** Unreachable from a healthy
/// host now that the directory is checked first, which is exactly why it is
/// previewed: it is the state nobody will otherwise ever look at.
#Preview("Landed elsewhere", traits: .sampleData) {
    NewWorkspacePreview(model: NewWorkspaceModel(
        previewing: "/Users/robin/Developer",
        warning: "Created Developer, but its pane opened in /Users/robin rather than "
            + "/Users/robin/Developer."
    ))
}

/// The other half of that state, and the one that actually happens: the
/// connection dropped in the window where the workspace may or may not have
/// been made. The button is spent either way.
#Preview("Cannot tell", traits: .sampleData) {
    NewWorkspacePreview(model: NewWorkspaceModel(
        previewing: "/Users/robin/Developer",
        warning: "the connection closed before this finished\n\nThe workspace may or may not "
            + "have been created — pull the list down to see."
    ))
}

/// A label the session already has. herdr allows it; the footer says so.
#Preview("Duplicate label", traits: .sampleData) {
    NewWorkspacePreview(
        model: NewWorkspaceModel(previewing: "/Users/robin/Developer/forge", label: "forge")
    )
}

#Preview("Creating", traits: .sampleData) {
    NewWorkspacePreview(model: NewWorkspaceModel(
        previewing: "/Users/robin/Developer/partofinc/bleat-apple", isCreating: true
    ))
}

/// Presented over the screen it is opened from, so the previews show the sheet
/// as it is really seen rather than on a blank canvas.
private struct NewWorkspacePreview: View {
    let model: NewWorkspaceModel
    @State private var showing = true

    var body: some View {
        NavigationStack {
            WorkspacesView(peer: .preview, session: "work", previewing: .loaded(Workspace.samples))
        }
        .sheet(isPresented: $showing) {
            NewWorkspaceForm(
                model: model, peer: .preview, known: Workspace.samples, onCreated: {}
            )
        }
    }
}
#endif
#endif
