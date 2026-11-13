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
    /// The confirmation before the installer runs, which shows what it is.
    @State private var confirmingInstall = false

    var body: some View {
        content
            .navigationTitle(peer.name)
            .alert("Install herdr-core on \(peer.name)?", isPresented: $confirmingInstall) {
                Button("Install") {
                    // A task of its own, not the view's: leaving the screen
                    // must not cancel an installer half way through on the
                    // host. The answer lands in `herdrCore` either way.
                    Task { await context.herdrCore.install(peer) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Bleat will run herdr-core's official installer over SSH, as \(peer.username):\n\n\(HerdrCoreInstall.displayCommand)\n\nIt installs into ~/.local/bin and needs no password.")
            }
    }


    @ViewBuilder
    private var content: some View {
        switch context.herdrCore.state(of: peer) {
        case .ready:
            if context.isRelayed {
                // The watch asks the phone for everything: the terminals are
                // herdr-core calls the phone makes for it, asked again while
                // the screen is up.
                RelayedTerminalsView(peer: peer, model: RelayedTerminalsModel(peer: peer, connections: context.connections))
            } else {
                TerminalsView(peer: peer, connections: context.connections)
            }
        case .needsHerdrCore:
            ContentUnavailableView {
                Label("Install herdr-core", systemImage: "shippingbox")
            } description: {
                Text("Bleat now talks to herdr-core (`hc`), not the herdr TUI. Bleat can install it on \(peer.name) for you, or install it yourself and check again.")
            } actions: {
                installActions
            }
        case .installing:
            ProgressView("Installing herdr-core on \(peer.name)…")
        case .installFailed(let message):
            ContentUnavailableView {
                Label("Install failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text("herdr-core could not be installed on \(peer.name): \(message)")
            } actions: {
                installActions
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

    /// Install, and Check Again for someone who installed it themselves. Only
    /// where this device can dial: the watch cannot.
    @ViewBuilder
    private var installActions: some View {
        if context.herdrCore.canRetry {
            Button("Install herdr-core") { confirmingInstall = true }
                .buttonStyle(.borderedProminent)
            Button("Check Again") {
                Task { await context.herdrCore.check(peer) }
            }
            .buttonStyle(.bordered)
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
