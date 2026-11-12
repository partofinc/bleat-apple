import BleatKit
import SwiftUI

/// What a host opens to in Bleat 2: its terminals once it has herdr-core, and
/// otherwise what stands in the way.
///
/// A ready host opens straight to `TerminalsView`; the gate is only ever seen
/// for a host that is not ready.
struct HerdrCoreGateView: View {
    @Environment(AppContext.self) private var context
    let peer: PairedPeer

    var body: some View {
        content
            .navigationTitle(peer.name)
    }


    @ViewBuilder
    private var content: some View {
        switch context.herdrCore.state(of: peer) {
        case .ready:
            if context.isRelayed {
                // The watch asks the phone for everything, and the relay
                // carries shell commands, not hc's stream — yet. So the host's
                // load is here, read over the relay, and its terminals are not.
                List {
                    HostLoadSection(peer: peer)
                    Section {
                        Label("Terminals are on iPhone for now", systemImage: "iphone")
                    } footer: {
                        Text("The watch follows in a later update.")
                    }
                }
                // Asking for the shell opens nothing on the watch: the phone
                // connects when the probe reaches it. The store reads only
                // over a connection something else asked for, and this is that.
                .task {
                    _ = try? await context.connections.shell(for: peer)
                    await context.hostLoad.refresh(for: peer)
                }
            } else {
                TerminalsView(peer: peer, connections: context.connections)
            }
        case .needsHerdrCore:
            ContentUnavailableView {
                Label("Install herdr-core", systemImage: "shippingbox")
            } description: {
                Text("Bleat now talks to herdr-core (`hc`), not the herdr TUI. Install it on \(peer.name), then check again.")
            } actions: {
                checkAgain
            }
        case .unreachable(let message):
            ContentUnavailableView {
                Label("Not reachable", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Bleat could not reach \(peer.name) to check for herdr-core: \(message)")
            } actions: {
                checkAgain
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Check failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Bleat could not finish checking \(peer.name) for herdr-core: \(message)")
            } actions: {
                checkAgain
            }
        case .checking:
            ProgressView("Checking for herdr-core…")
        case .unknown:
            ContentUnavailableView {
                Label("Not checked yet", systemImage: "questionmark.circle")
            } description: {
                Text(
                    context.herdrCore.canRetry
                        ? "\(peer.name) has not been checked for herdr-core yet."
                        : "Open Bleat on your iPhone to check \(peer.name) for herdr-core."
                )
            } actions: {
                checkAgain
            }
        }
    }

    /// Not through a relay: the watch cannot dial, and the phone checks again
    /// whenever it comes to the foreground.
    @ViewBuilder
    private var checkAgain: some View {
        if context.herdrCore.canRetry {
            Button("Check Again") {
                Task { await context.herdrCore.check(peer) }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#if DEBUG
#Preview("Ready", traits: .sampleData) {
    NavigationStack { HerdrCoreGateView(peer: .preview) }
}

#Preview("Needs herdr-core", traits: .sampleData) {
    NavigationStack { HerdrCoreGateView(peer: .previewOverlayOnly) }
}

#Preview("Not checked", traits: .sampleData) {
    NavigationStack { HerdrCoreGateView(peer: .previewSparse) }
}
#endif
