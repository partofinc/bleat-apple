import BleatKit
import SwiftUI

/// A host's terminals on the watch, through the phone: the host's load first,
/// then the terminals, most urgent first. Everything is a row, as elsewhere
/// on the watch (`docs/watch.md`): an overlay cannot be scrolled.
struct RelayedTerminalsView: View {
    let peer: PairedPeer
    @State private var model: RelayedTerminalsModel
    @Environment(AppContext.self) private var context
    @Environment(\.scenePhase) private var scenePhase

    /// A row saying what the list cannot show yet, or why.
    @ViewBuilder
    private var statusRow: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        case .live:
            Text("Nothing running")
                .foregroundStyle(.secondary)
        }
    }

    /// Whether the status row shows: always but while terminals are shown
    /// and nothing has gone wrong.
    private var showsStatus: Bool {
        if case .failed = model.phase { return true }
        return model.terminals.isEmpty
    }

    init(peer: PairedPeer, model: RelayedTerminalsModel) {
        self.peer = peer
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
            HostLoadSection(peer: peer)
            if showsStatus {
                Section("Terminals") { statusRow }
            }
            TerminalSections(hostKey: peer.hostKey, terminals: model.terminals, untitled: "Terminals")
        }
        .task { await model.run() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setInFront(phase == .active)
        }
        // The load is read over the same relay; asking for the shell is what
        // makes the phone connect for it.
        .task {
            _ = try? await context.connections.shell(for: peer)
            await context.hostLoad.refresh(for: peer)
        }
    }
}

#if DEBUG
#Preview("Terminals", traits: .sampleData) {
    NavigationStack {
        RelayedTerminalsView(peer: .preview, model: RelayedTerminalsModel(call: { _, _ in
            .object(["terminals": .array([])])
        }))
    }
}
#endif
