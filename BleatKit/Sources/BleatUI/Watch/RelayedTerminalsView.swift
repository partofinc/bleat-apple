import BleatKit
import SwiftUI

/// A host's terminals on the watch, through the phone: the host's load first,
/// then the terminals, most urgent first. Everything is a row, as elsewhere
/// on the watch (`docs/watch.md`): an overlay cannot be scrolled.
struct RelayedTerminalsView: View {
    let peer: PairedPeer
    @State private var model: RelayedTerminalsModel
    @Environment(AppContext.self) private var context

    init(peer: PairedPeer, model: RelayedTerminalsModel) {
        self.peer = peer
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
            HostLoadSection(peer: peer)
            Section("Terminals") {
                switch model.phase {
                case .loading:
                    if model.terminals.isEmpty { ProgressView() }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                case .live where model.terminals.isEmpty:
                    Text("Nothing running")
                        .foregroundStyle(.secondary)
                case .live:
                    EmptyView()
                }
                ForEach(model.terminals) { terminal in
                    NavigationLink(value: NavigationRouter.Route.terminal(
                        peer: peer.hostKey, address: terminal.address, title: terminal.displayName
                    )) {
                        HcTerminalRow(terminal: terminal)
                    }
                }
            }
        }
        .task { await model.run() }
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
