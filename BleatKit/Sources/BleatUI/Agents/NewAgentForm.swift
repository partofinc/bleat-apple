#if os(iOS)
import BleatKit
import SwiftUI

/// Starting an agent: which pane, which agent, and what to call it.
///
/// A form in a sheet, the shape `NewWorkspaceForm` uses and for the same
/// reason: three values have to be visible before the tap. The pane matters
/// most — this is the first screen in the app that asks the user to pick one,
/// and picking the wrong one starts a program in somebody's terminal.
///
/// The whole file is iOS-only, like the other two: `BleatUI` compiles for
/// macOS, where there is no bottom bar to open this from.
struct NewAgentForm: View {
    @Bindable var model: NewAgentModel
    let peer: PairedPeer
    let onStarted: () -> Void
    /// Asked to open a pane once this sheet is out of the way.
    ///
    /// **A callback rather than a push from here, and that is not indirection
    /// for its own sake.** SwiftUI will not act on a navigation raised from
    /// inside a sheet that is dismissing — the same hazard `PeerSettingsFlow`
    /// documents for a confirmation dialog presented under one — so the
    /// presenting screen holds the request and runs it from `onDismiss`.
    let onAnswer: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var naming: Bool
    @State private var unlocking = false
    /// Held only between the field and the one command that uses it.
    @State private var passphrase = ""
    @State private var unlockFailure: String?

    var body: some View {
        NavigationStack {
            Form {
                if let note { outcome(note) }
                keychainSection
                paneSection
                kindSection
                nameSection
            }
            .navigationTitle("Start Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.isStarting)
                }
                ToolbarItem(placement: .confirmationAction) { confirm }
            }
        }
        // Sequential on purpose: the pane list is what the user came for, and
        // the keychain check is a diagnosis that must not hold it up.
        .task {
            await model.loadPanes(for: peer)
            await model.checkKeychain(for: peer)
        }
        .alert("Unlock the Mac's keychain", isPresented: $unlocking) {
            unlockPrompt
        } message: {
            Text("Sent over the connection this host is already paired on, used once, and "
                 + "not saved.")
        }
        .alert(
            "Could not unlock it",
            isPresented: .init(get: { unlockFailure != nil }, set: { if !$0 { unlockFailure = nil } })
        ) {
            Button("OK") { unlockFailure = nil }
        } message: {
            Text(unlockFailure ?? "")
        }
        // **Not dismissible while the start is in flight**, for the reason the
        // pairing sheet is not: herdr may take half a minute, and this is the
        // only place the outcome is reported.
        .interactiveDismissDisabled(model.isStarting)
        .onChange(of: model.name) { _, _ in model.clearFailure() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var paneSection: some View {
        Section {
            if model.isLoadingPanes && model.available.isEmpty {
                HStack { ProgressView(); Text("Looking for free panes…") }
            } else if model.available.isEmpty && !model.hasLoadedPanes {
                // The host was never asked, or could not answer. The failure
                // row above says so; claiming anything about its panes here
                // would be a confident statement about a machine we did not
                // reach.
                Text("The host has not said which panes are free.")
                    .foregroundStyle(.secondary)
            } else if model.available.isEmpty {
                // **Not an error, and not a dead end either.** Every pane
                // holding an agent is the ordinary state of a working host —
                // measured, every workspace in the live `work` session has one
                // pane and every one is occupied. A workspace made from the
                // phone holds exactly one pane, so this is where the second
                // agent used to become impossible.
                Text("Every pane here already has an agent.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Pane", selection: $model.pane) {
                    ForEach(model.available) { pane in
                        // The pane id is what herdr wants and what makes two
                        // rows in one directory tellable apart; the directory
                        // is what the user recognises.
                        Text("\(pane.paneID) — \(directory(of: pane))")
                            .truncationMode(.head)
                            .tag(Optional(pane.paneID))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            addPane
        } header: {
            Text("Pane")
        } footer: {
            Text("Only panes with no agent are listed. The pane also has to be sitting at its "
                 + "shell prompt — herdr refuses one that is busy.")
        }
        .disabled(model.isStarting)
    }

    /// The way out when every pane is taken — and worth offering even when one
    /// is free, since wanting a *fresh* pane is not the same as wanting the
    /// only spare one.
    ///
    /// **A new tab, not a split.** Measured in a 120-column session: a split
    /// pane is 60 columns wide against a tab's 120, and it narrows the pane it
    /// came from as well. Narrow grids are what this codebase spends pages on.
    /// The directory is shown rather than asked for, because a tab inherits the
    /// workspace's — also measured.
    @ViewBuilder
    private var addPane: some View {
        if model.canAddPane || model.isAddingPane {
            Button {
                Task { await model.addPane(for: peer) }
            } label: {
                HStack {
                    if model.isAddingPane {
                        ProgressView()
                        Text("Adding a pane…")
                    } else {
                        Label("Add a pane", systemImage: "plus.rectangle")
                    }
                    Spacer()
                }
            }
            .disabled(!model.canAddPane)

            if let directory = model.workspaceDirectory, !model.isAddingPane {
                // Shown before the tap, which is the rule CLAUDE.md sets for
                // creating a pane: it opens in the workspace's own directory,
                // and the user should not have to find that out afterwards.
                Text("Opens a new tab here, in \(directory).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .truncationMode(.head)
                    .lineLimit(1)
            }
        }
    }

    private var kindSection: some View {
        Section {
            Picker("Agent", selection: $model.kind) {
                ForEach(AgentKind.known) { kind in
                    Text(kind.label).tag(kind)
                }
            }
        } footer: {
            // The honest warning, and the reason it is worth a sentence: this
            // is the one failure that is slow. Nothing on the phone can see
            // which binaries the host has.
            Text("Bleat cannot tell which of these are installed. One that is not takes about "
                 + "30 seconds to fail.")
        }
        .disabled(model.isStarting)
    }

    private var nameSection: some View {
        Section {
            TextField("reviewer", text: $model.name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($naming)
                .onSubmit(start)
                .disabled(model.isStarting)
        } header: {
            Text("Name")
        } footer: {
            if let problem = model.nameProblem {
                Text(problem).foregroundStyle(.red)
            } else {
                Text("Lowercase letters, numbers, dashes and underscores, up to 32.")
            }
        }
    }

    /// Said before the tap, because afterwards it costs half a minute and looks
    /// like success: herdr starts the agent, detects it, reports it — and the
    /// agent cannot sign in.
    ///
    /// **Shown only for `.lockedAndCannotPrompt`.** That is the one state an
    /// agent reports as "not logged in" — `security show-keychain-info` exiting
    /// 36, which is the test Claude Code itself makes. `.unknown` is a host that
    /// could not be asked and `.unlocked` needs no remark; announcing either
    /// would be noise on every healthy host. See `LoginKeychain`.
    @ViewBuilder
    private var keychainSection: some View {
        if model.keychain == .lockedAndCannotPrompt {
            Section {
                Label("Agents here cannot sign in yet", systemImage: "key.slash")
                    .font(.callout.weight(.medium))
                Text("The Mac's keychain is locked, and nothing over this connection can ask "
                     + "for the passphrase — so an agent that needs an account will come up "
                     + "reporting it is not logged in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Unlock the keychain") { unlocking = true }
            }
        }
    }

    /// Asks for the Mac's login passphrase and sends it over the connection.
    ///
    /// **Nothing is remembered.** It is used for one command and dropped —
    /// keeping a Mac login passphrase on a phone is a decision of its own and
    /// not one to make as a side effect of a dialog. The field is a
    /// `SecureField`, so it is not in the keyboard's cache or on screen.
    ///
    /// An alert rather than a sheet: it is one field, and a sheet over a sheet is
    /// exactly the presentation SwiftUI drops.
    private var unlockPrompt: some View {
        Group {
            SecureField("Mac login passphrase", text: $passphrase)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Unlock") { unlock() }
            Button("Cancel", role: .cancel) { passphrase = "" }
        }
    }

    private func unlock() {
        let typed = passphrase
        // Cleared before the round trip rather than after, so it is not sitting
        // in view state while the network is in flight.
        passphrase = ""
        Task {
            switch await model.unlock(passphrase: typed, for: peer) {
            case .unlocked:
                unlockFailure = nil
            case .wrongPassphrase:
                unlockFailure = "That passphrase was refused."
            case .failed:
                unlockFailure = "The keychain is still locked, and the Mac did not say why."
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
        if model.isStarting {
            ProgressView()
        } else if model.blocked != nil, let pane = model.pane {
            // **The agent is up and waiting at a dialog, so the useful action is
            // going there — not trying again.** Answering needs the terminal's
            // key bar, which means the pane screen; the user found that route by
            // hand, and this is it made into a button.
            Button("Answer it") { answer(pane) }
        } else if model.warning != nil {
            // Something may be running in that pane. Starting again would land
            // on `agent_pane_busy`, over the agent the user was told had not
            // started.
            Button("Done") { dismiss() }
        } else {
            Button("Start", action: start).disabled(!model.canStart)
        }
    }

    // MARK: - Wiring

    /// At most one message, most urgent first.
    private var note: (text: String, isProblem: Bool)? {
        if let failure = model.failure { return (failure, true) }
        // Not red, and first among the two that are not: the agent is *there*.
        // Red would read as "nothing happened", which is what this screen used
        // to say about it.
        if let blocked = model.blocked {
            return (blocked + "\n\nOpen the pane and switch to terminal mode to answer it.", false)
        }
        // Not red: something may well be running whether or not the user likes
        // it. Red would read as "nothing happened".
        if let warning = model.warning { return (warning, false) }
        return nil
    }

    /// A pane's `foreground_cwd` in preference to `cwd`, because it follows the
    /// running process — the same choice the agent rows make.
    private func directory(of pane: Pane) -> String {
        pane.foregroundCwd ?? pane.cwd ?? pane.paneID
    }

    /// Refreshes the list, asks for the pane, and gets out of the way. In that
    /// order: the blocked agent has to be in the list before the pane screen
    /// pushes over it, or backing out lands on a list that does not show it.
    private func answer(_ pane: String) {
        onStarted()
        onAnswer(pane)
        dismiss()
    }

    private func start() {
        guard model.canStart else { return }
        naming = false
        Task {
            switch await model.start(on: peer) {
            case .started:
                onStarted()
                dismiss()
            case .blocked:
                // The list still has to reload — the agent is real and blocked,
                // and blocked sorts first — but the sheet stays up, because it
                // is the only thing that says what happened and offers the way
                // to answer it.
                onStarted()
            case .warned:
                // The list still has to be refreshed — something may be running
                // — but the sheet stays up, because it is the only place that
                // says what happened.
                onStarted()
            case .failed:
                break
            }
        }
    }
}

#if DEBUG
/// The ordinary case: a free pane picked, a name typed.
#Preview("Naming", traits: .sampleData) {
    NewAgentPreview(model: NewAgentModel(
        previewing: "reviewer", pane: "w2:p1", available: Pane.samples
    ))
}

/// **The Mac's keychain is locked and nothing here can ask for the passphrase.**
/// `security show-keychain-info` exits 36, which is the test Claude Code makes
/// before reporting `Not logged in`. Not reachable by pointing the app at a
/// healthy Mac, which is the whole reason it wants a canvas.
#Preview("Keychain locked", traits: .sampleData) {
    NewAgentPreview(model: NewAgentModel(
        previewing: "reviewer", pane: "w2:p1", available: Pane.samples,
        keychain: .lockedAndCannotPrompt
    ))
}

/// **Started, and stopped at a dialog — the common case for a workspace the
/// phone just made.** herdr answers `agent_not_ready` in about four seconds and
/// the agent is there, named, waiting on Claude Code's workspace-trust prompt.
/// This used to be reported in red as a failure with the Start button armed,
/// over an agent that existed; both retries are dead ends.
#Preview("Waiting at a dialog", traits: .sampleData) {
    NewAgentPreview(model: NewAgentModel(
        previewing: "reviewer", pane: "w2:p1", available: Pane.samples,
        blocked: "agent reviewer is blocked during startup and is not ready for prompts"
    ))
}

/// A name herdr's own rule refuses. Capitals are the one that surprises.
#Preview("Bad name", traits: .sampleData) {
    NewAgentPreview(model: NewAgentModel(
        previewing: "Reviewer", pane: "w2:p1", available: Pane.samples
    ))
}

/// herdr refuses a duplicate (`agent_name_taken`), so the field says so first.
#Preview("Name taken", traits: .sampleData) {
    NewAgentPreview(model: NewAgentModel(
        previewing: "builder", pane: "w2:p1",
        available: Pane.samples, takenNames: ["builder"]
    ))
}

/// **Not a failure, and no longer a dead end.** Every pane on a busy host is
/// doing something; the way to another is a new tab, which costs no existing
/// pane any width.
#Preview("No free panes", traits: .sampleData) {
    NewAgentPreview(model: NewAgentModel(
        previewing: "reviewer", workspace: "w2",
        workspaceDirectory: "/Users/ravil/Developer/rawillk/bleat-apple"
    ))
}

#Preview("Adding a pane", traits: .sampleData) {
    NewAgentPreview(model: NewAgentModel(
        previewing: "reviewer", workspace: "w2",
        workspaceDirectory: "/Users/ravil/Developer/rawillk/bleat-apple",
        isAddingPane: true
    ))
}

/// **The cause herdr does not give.** Its own answer is "timed out waiting for
/// agent startup"; the sentence below came out of the pane.
#Preview("Not installed", traits: .sampleData) {
    NewAgentPreview(model: NewAgentModel(
        previewing: "reviewer", kind: AgentKind("devin"), pane: "w2:p1",
        available: Pane.samples, failure: "zsh: command not found: devin"
    ))
}

/// **The ambiguous one, and the reason the button is spent.** herdr stopped
/// waiting and the agent came up anyway, nameless.
#Preview("Started late", traits: .sampleData) {
    NewAgentPreview(model: NewAgentModel(
        previewing: "reviewer", pane: "w2:p1", available: Pane.samples,
        warning: "claude is running in w2:p1, but it took longer than herdr waited — so it has "
            + "no name. It will show in the list without one."
    ))
}

#Preview("Starting", traits: .sampleData) {
    NewAgentPreview(model: NewAgentModel(
        previewing: "reviewer", pane: "w2:p1", available: Pane.samples, isStarting: true
    ))
}

private struct NewAgentPreview: View {
    let model: NewAgentModel
    @State private var showing = true

    var body: some View {
        NavigationStack {
            AgentsView(
                peer: .preview, session: "work", workspace: "w2", title: "bleat-apple",
                previewing: .loaded(Agent.samples)
            )
        }
        .sheet(isPresented: $showing) {
            NewAgentForm(model: model, peer: .preview, onStarted: {}, onAnswer: { _ in })
        }
    }
}
#endif
#endif
