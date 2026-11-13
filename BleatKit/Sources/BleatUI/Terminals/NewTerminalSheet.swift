#if os(iOS)
import BleatKit
import SwiftUI

/// Starting a terminal on a host: the shell, a command, or a template, in a
/// directory, under an optional name.
///
/// Started detached from the phone (`HcRunRequest`), so it keeps running
/// after the phone goes; then opened, which takes it over at the phone's size
/// like any other.
struct NewTerminalSheet: View {
    @State private var model: NewTerminalModel
    @Environment(\.dismiss) private var dismiss
    /// The new terminal's address and the title to open it under.
    let onStarted: (String, String) -> Void

    init(model: NewTerminalModel, onStarted: @escaping (String, String) -> Void) {
        _model = State(initialValue: model)
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
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.phase == .starting {
                        ProgressView()
                    } else {
                        Button("Start") { Task { await start() } }
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
                TextField("claude", text: $model.command)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await start() } }
                if !model.commandSuggestions.isEmpty {
                    suggestions(model.commandSuggestions) { model.command = $0 }
                }
            } header: {
                Text("Command")
            } footer: {
                Text("Run by the host's shell, like a line typed there.")
            }
        case .template:
            Section {
                Picker("Template", selection: $model.templateName) {
                    ForEach(model.templates) { template in
                        Text(template.name).tag(Optional(template.name))
                    }
                }
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
                TextField("~", text: $model.directory)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
            Text("On \(model.hostName). Empty is home; a path without / is under home.")
        }
    }

    private var name: some View {
        Section {
            TextField("Optional", text: $model.name)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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

    private func start() async {
        guard let address = await model.start(size: HcPaneModel.lastViewport) else { return }
        onStarted(address, model.title)
    }
}

#if DEBUG
#Preview("New terminal", traits: .sampleData) {
    NewTerminalSheet(
        model: NewTerminalModel(hostName: "adam", terminals: HcTerminal.samples, host: PreviewTerminalHost()),
        onStarted: { _, _ in }
    )
}

/// A host for previews: one template, a home, and a start that never returns.
final class PreviewTerminalHost: TerminalStarting {
    func templates() async -> [HcTemplate] {
        [HcTemplate(name: "pi-env", description: "Claude on a Pi with Docker Compose services.", command: "claude")]
    }
    func shell() async throws -> any ShellRunner { PreviewShell() }
    func start(_ request: HcRunRequest) async throws -> String {
        try await Task.sleep(for: .seconds(3600))
        return "t1"
    }

    private struct PreviewShell: ShellRunner {
        func run(shell command: String) async throws -> String {
            command == HostDirectory.home ? "/home/pi" : "yes\n"
        }
    }
}
#endif
#endif
