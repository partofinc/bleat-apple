#if os(iOS)
import BleatKit
import SwiftUI

/// A Mac's saved layouts: restore one, or save or close one that is open.
///
/// Reached from the host's terminal list, where the button shows only on a
/// host that has `herdr-layout` (`LayoutsModel`). A restored layout's
/// terminals show up in that list as they start, as any started on the Mac.
struct LayoutsSheet: View {
    @State private var model: LayoutsModel
    /// The layout whose actions are up.
    @State private var chosen: HerdrLayout?
    /// The layout being renamed, and the name typed for it.
    @State private var renaming: HerdrLayout?
    @State private var newName = ""
    @Environment(\.dismiss) private var dismiss

    init(model: LayoutsModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            List {
                if let outcome = model.outcome {
                    Section {
                        Label(outcome.message, systemImage: outcome.failed ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(outcome.failed ? .red : .primary)
                    }
                }
                if let problem = model.loadProblem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    ForEach(model.layouts) { layout in
                        Button { chosen = layout } label: { LayoutRow(layout: layout, progress: progress(for: layout)) }
                            .disabled(model.running != nil)
                    }
                } footer: {
                    if !model.layouts.isEmpty {
                        Text("Saved with herdr-layout on \(model.hostName). Restoring opens them in Herdr.app there.")
                    }
                }
            }
            .overlay {
                if model.layouts.isEmpty, model.loadProblem == nil {
                    if model.isLoading {
                        ProgressView()
                    } else {
                        ContentUnavailableView(
                            "No saved layouts",
                            systemImage: "rectangle.3.group",
                            description: Text("Save one on \(model.hostName) with herdr-layout save.")
                        )
                    }
                }
            }
            .navigationTitle("Layouts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await model.load() }
            .task { await model.load() }
            .confirmationDialog(
                chosen?.name ?? "",
                isPresented: Binding { chosen != nil } set: { if !$0 { chosen = nil } },
                titleVisibility: .visible,
                presenting: chosen
            ) { layout in
                if layout.isOpen {
                    Button("Save Now") { model.perform(.update, on: layout.name) }
                    Button("Close", role: .destructive) { model.perform(.close, on: layout.name) }
                } else {
                    Button("Restore") { model.perform(.restore, on: layout.name) }
                }
                Button("Rename…") {
                    newName = layout.name
                    renaming = layout
                }
            } message: { layout in
                Text(Self.explanation(for: layout, on: model.hostName))
            }
            .alert(
                "Rename \(renaming?.name ?? "")",
                isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } },
                presenting: renaming
            ) { layout in
                TextField("Name", text: $newName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Rename") { model.perform(.rename(to: trimmedName), on: layout.name) }
                    .disabled(!canRename(layout))
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Letters, digits, spaces, . _ or -, up to 64, starting with a letter or digit.")
            }
            .alert(
                "Agents are still working",
                isPresented: Binding { model.stillWorking != nil } set: { if !$0 { model.stillWorking = nil } },
                presenting: model.stillWorking
            ) { name in
                Button("Close Anyway", role: .destructive) { model.perform(.closeAnyway, on: name) }
                Button("Cancel", role: .cancel) {}
            } message: { name in
                Text("Closing \(name) now ends them mid-task.")
            }
        }
    }

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespaces) }

    /// A name the script takes, and not the one it has: the script refuses
    /// an unchanged name, and allows a change of case alone.
    private func canRename(_ layout: HerdrLayout) -> Bool {
        trimmedName != layout.name && HerdrLayout.isValidName(trimmedName)
    }

    private func progress(for layout: HerdrLayout) -> String? {
        guard let running = model.running, running.name == layout.name else { return nil }
        return running.action.progress
    }

    static func explanation(for layout: HerdrLayout, on host: String) -> String {
        if layout.isOpen {
            return "Save Now keeps it as it is now. Close saves it first, then closes its spaces in Herdr.app on \(host) and ends their terminals."
        }
        let claude = layout.claude == 1 ? "1 Claude session" : "\(layout.claude) Claude sessions"
        let spaces = layout.spaces.count == 1 ? "1 space" : "\(layout.spaces.count) spaces"
        return layout.claude > 0
            ? "Opens its \(spaces) in Herdr.app on \(host) and resumes \(claude)."
            : "Opens its \(spaces) in Herdr.app on \(host)."
    }
}

#if DEBUG
#Preview("Layouts", traits: .sampleData) {
    LayoutsSheet(model: LayoutsModel(hostName: "kestrel", hcPath: nil, shell: { PreviewLayoutsShell() }))
}
#endif
#endif
