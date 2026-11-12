import BleatKit
import SwiftUI

/// A host's screen in Bleat 2: its live herdr-core terminals.
///
/// Reached through `HerdrCoreGateView` once the host has hc. A row opens the
/// terminal's live screen, `HcTerminalScreen`.
struct TerminalsView: View {
    @State private var model: TerminalsModel
    /// Bumped to connect again: Try Again, or coming back to the foreground
    /// after the connection was dropped.
    @State private var attempt = 0
    @Environment(\.scenePhase) private var scenePhase

    init(peer: PairedPeer, connections: ConnectionStore) {
        _model = State(initialValue: TerminalsModel(peer: peer, connections: connections))
    }

    var body: some View {
        TerminalsList(hostKey: model.peer.hostKey, terminals: model.terminals)
            .overlay { overlay }
            .navigationTitle(model.peer.name)
            // The host's load, and its settings behind a tap. Here, the host's
            // own screen, and not on a terminal: there a bar that comes and
            // goes would resize the terminal on someone's Mac.
            .hostLoadBar(for: model.peer)
            .task(id: attempt) { await model.run() }
            // iOS takes the socket in the background, and `RootView` releases
            // the connection there too. Coming back, a list that failed for
            // that reason reconnects by itself.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, case .failed = model.phase else { return }
                attempt += 1
            }
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.phase {
        case .connecting:
            if model.terminals.isEmpty { ProgressView("Connecting to herdr-core…") }
        case .live:
            if model.terminals.isEmpty {
                ContentUnavailableView(
                    "No terminals running",
                    systemImage: "terminal",
                    description: Text("Nothing is running in herdr-core on \(model.peer.name).")
                )
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Could not load terminals", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { attempt += 1 }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
