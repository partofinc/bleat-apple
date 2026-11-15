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
            } message: { layout in
                Text(Self.explanation(for: layout, on: model.hostName))
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

/// One layout: its name, whether it is open, its spaces and what is in them.
struct LayoutRow: View {
    let layout: HerdrLayout
    /// What it is doing, while an action runs on it.
    let progress: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(layout.name).font(.headline)
                    if layout.isOpen {
                        Text("Open")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: .capsule)
                            .foregroundStyle(.tint)
                    }
                }
                if !layout.spaces.isEmpty {
                    Text(layout.spaces.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                details
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let progress {
                ProgressView()
                    .accessibilityLabel(progress)
            }
        }
        .contentShape(.rect)
        .foregroundStyle(.primary)
    }

    private var details: Text {
        let panes = layout.panes == 1 ? "1 pane" : "\(layout.panes) panes"
        let counts = layout.claude > 0 ? "\(panes) · \(layout.claude) Claude" : panes
        guard let progress else {
            guard let savedAt = layout.savedAt else { return Text(counts) }
            return Text("\(counts) · saved \(savedAt, format: .relative(presentation: .named))")
        }
        return Text(progress)
    }
}

#Preview("Layouts", traits: .sampleData) {
    LayoutsSheet(model: LayoutsModel(hostName: "kestrel", hcPath: nil, shell: { PreviewLayoutsShell() }))
}

/// Answers `list` with the fixture's shape, for the preview.
private struct PreviewLayoutsShell: ShellRunner {
    func run(shell command: String) async throws -> String {
        #"[{"name":"Clinic","saved_at":1794719194,"open":0,"spaces":["clinic-api","clinic-ios","clinic-web"],"panes":3,"claude":3},{"name":"Studio","saved_at":1794628972,"open":1,"spaces":["studio"],"panes":1,"claude":1}]"#
    }
}
#endif
