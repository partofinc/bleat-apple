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
    /// The new-terminal sheet, while it is up.
    @State private var creating: NewTerminalModel?
    /// The list's width in points: a terminal opened from it is as wide, so
    /// the grid remembered for that width is the one to start a new one at.
    @State private var width = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppContext.self) private var context

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
            // The bar's reading is asked for again whenever the list is back
            // on screen — coming back from a terminal twenty minutes later
            // must not show twenty-minute-old numbers as current — and forced
            // by a pull. Reads under ten seconds old are turned away by the
            // store, so this costs nothing on a quick return.
            .onAppear { Task { await context.hostLoad.refresh(for: model.peer) } }
            .onChange(of: model.phase) { _, phase in
                guard phase == .live else { return }
                Task { await context.hostLoad.refresh(for: model.peer) }
            }
            .refreshable { await context.hostLoad.refresh(for: model.peer, force: true) }
            .task(id: attempt) { await model.run() }
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Terminal", systemImage: "plus") {
                        creating = NewTerminalModel(
                            hostName: model.peer.name, terminals: model.terminals, host: model
                        )
                    }
                    // It asks on the list's own connection, which only a
                    // live list has.
                    .disabled(model.phase != .live)
                }
            }
            .onGeometryChange(for: Int.self) { Int($0.size.width) } action: { width = $0 }
            .sheet(item: $creating) { form in
                NewTerminalSheet(model: form, size: HcPaneModel.lastViewport(forWidth: width)) { address, title in
                    creating = nil
                    // Opened as a row would open it: it takes the terminal
                    // over at the phone's size, which it already started at.
                    context.navigation.push(.terminal(peer: model.peer.hostKey, address: address, title: title))
                }
            }
            #endif
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
