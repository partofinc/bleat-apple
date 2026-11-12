import BleatKit
import SwiftUI

/// What a host opens to in Bleat 2: its terminals once it has herdr-core, and
/// otherwise what stands in the way.
///
/// **The terminals are a placeholder for now.** The hc client is the next
/// change; this one only moves every 1.x peer through the gate.
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
            ContentUnavailableView(
                "Ready for herdr-core",
                systemImage: "terminal",
                description: Text("\(peer.name) has herdr-core. Its terminals appear here in the next build.")
            )
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
        case .checking:
            ProgressView("Checking for herdr-core…")
        case .unknown:
            ContentUnavailableView(
                "Not checked yet",
                systemImage: "questionmark.circle",
                description: Text(
                    context.isRelayed
                        ? "Open Bleat on your iPhone to check \(peer.name) for herdr-core."
                        : "\(peer.name) has not been checked for herdr-core yet."
                )
            )
        }
    }

    /// Not through a relay: the watch cannot dial, and the phone checks again
    /// whenever it comes to the foreground.
    @ViewBuilder
    private var checkAgain: some View {
        if !context.isRelayed {
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
