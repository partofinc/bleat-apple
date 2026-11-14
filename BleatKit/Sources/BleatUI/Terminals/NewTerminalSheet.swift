#if os(iOS)
import BleatKit
import SwiftUI

/// Starting a terminal on a host: the shell, a command, or a template, in a
/// directory, under an optional name, in a Herdr.app space: its own, or one
/// already there for that folder.
///
/// Started detached from the phone (`HcRunRequest`), so it keeps running
/// after the phone goes; then opened, which takes it over at the phone's size
/// like any other.
struct NewTerminalSheet: View {
    @State private var model: NewTerminalModel
    /// The start in flight. Held so Cancel can stop it: left to run, it
    /// opened the terminal after the sheet had gone.
    @State private var starting: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    /// The grid to start it at, when one is known for this width.
    let size: TerminalGrid?
    /// The new terminal's address and the title to open it under.
    let onStarted: (String, String) -> Void

    init(model: NewTerminalModel, size: TerminalGrid? = nil, onStarted: @escaping (String, String) -> Void) {
        _model = State(initialValue: model)
        self.size = size
        self.onStarted = onStarted
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Run", selection: $model.kind) {
                        ForEach(kinds) { kind in Text(kind.title).tag(kind) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                program
                directory
                name
                herdrSpace
                if case .failed(let message) = model.phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Also while starting: a template's agent may never get
                    // ready, and this is the way out. What was asked for may
                    // still start on the host; it is not opened.
                    Button("Cancel") {
                        starting?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.phase == .starting {
                        ProgressView()
                    } else {
                        Button("Start") { begin() }
                            .disabled(!model.canStart)
                    }
                }
            }
            .interactiveDismissDisabled(model.phase == .starting)
            .task { await model.load() }
        }
    }

    /// Template only where the host has one.
    private var kinds: [NewTerminalModel.Kind] {
        model.templates.isEmpty ? [.shell, .command] : NewTerminalModel.Kind.allCases
    }

    @ViewBuilder
    private var program: some View {
        switch model.kind {
        case .shell:
            Section {
                Text("The login shell of \(model.hostName).")
                    .foregroundStyle(.secondary)
            }
        case .command:
            Section {
                LiteralTextField(placeholder: "claude", text: $model.command, returnKey: .go) { begin() }
                if !model.commandSuggestions.isEmpty {
                    suggestions(model.commandSuggestions) { model.command = $0 }
                }
            } header: {
                Text("Command")
            } footer: {
                Text("Run by sh -c, with herdr-core's environment.")
            }
        case .template:
            Section {
                Picker("Template", selection: $model.templateName) {
                    ForEach(model.templates) { template in
                        Text(template.name).tag(Optional(template.name))
                    }
                }
                // Smart punctuation left on (kept from review): this goes
                // to an agent as prose, which reads `—verbose` as meant, and
                // a multi-line UIKit field in a Form is not worth that.
                TextField("First message (optional)", text: $model.task, axis: .vertical)
                    .lineLimit(2...6)
            } footer: {
                if let template = model.selectedTemplate, !template.description.isEmpty {
                    Text(template.description)
                }
            }
        }
    }

    private var directory: some View {
        Section {
            HStack {
                LiteralTextField(placeholder: "~", text: $model.directory)
                if !model.directorySuggestions.isEmpty {
                    Menu {
                        Button("~ (home)") { model.directory = "" }
                        ForEach(model.directorySuggestions, id: \.self) { path in
                            Button(HcRunSuggestions.abbreviate(path, home: model.home)) {
                                model.directory = HcRunSuggestions.abbreviate(path, home: model.home)
                            }
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Directories in use")
                }
            }
        } header: {
            Text("Directory")
        } footer: {
            if model.spacesForFolder.isEmpty, model.spacesProblem == nil {
                Text("On \(model.hostName). Empty is home; a path without / is under home. It gets a new space in Herdr, named after the folder.")
            } else {
                Text("On \(model.hostName). Empty is home; a path without / is under home.")
            }
        }
    }

    private var name: some View {
        Section {
            LiteralTextField(placeholder: "Optional", text: $model.name)
        } header: {
            Text("Name")
        } footer: {
            if let problem = model.nameProblem {
                Text(problem).foregroundStyle(.red)
            } else {
                Text("Unique on the host, so it can be found by name.")
            }
        }
    }

    /// Where it shows in Herdr.app. A selector only where Herdr.app already
    /// has a space for this very folder (decided by Ravil, 14 Nov 2026):
    /// anywhere else it gets a new space and there is nothing to choose.
    @ViewBuilder
    private var herdrSpace: some View {
        let existing = model.spacesForFolder
        if !existing.isEmpty || model.spacesProblem != nil {
            Section {
                if !existing.isEmpty {
                    Picker("Space", selection: placement) {
                        ForEach(existing) { space in
                            Text(space.displayName(home: model.home)).tag(NewTerminalModel.Placement.space(space.id))
                        }
                        Text("New space").tag(NewTerminalModel.Placement.newSpace)
                    }
                }
            } header: {
                Text("Herdr")
            } footer: {
                if let problem = model.spacesProblem {
                    Text("Herdr's spaces could not be read: \(problem). It will get a new space.")
                        .foregroundStyle(.red)
                } else if let space = model.space {
                    Text("In a new tab of \(space.displayName(home: model.home)), in Herdr on \(model.hostName).")
                } else {
                    Text("In a new space beside it, named after the folder.")
                }
            }
        }
    }

    /// The selector's choice: what the model will do, and what a pick sets.
    private var placement: Binding<NewTerminalModel.Placement> {
        Binding { model.placement } set: { model.picked = $0 }
    }

    private func suggestions(_ values: [String], pick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(values.prefix(8), id: \.self) { value in
                    Button(value) { pick(value) }
                        .buttonStyle(.bordered)
                        .font(.callout.monospaced())
                }
            }
        }
        .accessibilityLabel("Commands in use")
    }

    private func begin() {
        guard model.canStart else { return }
        starting = Task {
            let address = await model.start(size: size)
            guard let address, !Task.isCancelled else { return }
            onStarted(address, model.title)
        }
    }
}

#if DEBUG
#Preview("New terminal", traits: .sampleData) {
    NewTerminalSheet(
        model: NewTerminalModel(hostName: "adam", terminals: HcTerminal.samples, host: PreviewTerminalHost()),
        onStarted: { _, _ in }
    )
}
#endif
#endif
