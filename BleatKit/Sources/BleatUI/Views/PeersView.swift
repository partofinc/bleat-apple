import BleatKit
import SwiftUI

/// The first screen: the hosts this phone has paired with.
public struct PeersView: View {
    @Environment(AppContext.self) private var context
    @State private var isShowingKey = false
    @Namespace private var namespace

    public init() {}

    public var body: some View {
        @Bindable var navigation = context.navigation
        // **A selection, not a `NavigationLink` per row.** The host is what the
        // split view's sidebar selects, and the detail column is rooted on it;
        // collapsed, SwiftUI turns that same selection into the push this list
        // used to make itself. A `NavigationLink` here would push onto the
        // *sidebar*, leaving the detail column showing nothing.
        List(selection: $navigation.selectedPeer) {
            if let failure = context.peers.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            ForEach(context.peers.peers) { peer in
                PeerRow(peer: peer)
                // `PairedPeer.id` is already the host key, so this restates
                // what `ForEach` would infer — but the selection's type is what
                // decides whether a row is selectable at all, and the two being
                // visibly the same thing is worth a line.
                .tag(peer.hostKey)
                .swipeActions {
                    // Not through a relay: unpairing and a host's settings
                    // belong to the device that holds the key.
                    if !context.isRelayed {
                    // **Swiping asks; it does not unpair.** Unpairing is not
                    // list management — it decides what a machine will let in
                    // — and the record is the only thing that knows how to
                    // reach the host and which key line is this phone's.
                    // Dropping it on a swipe threw both away and left a
                    // working key behind. Declared first, so it is the one a
                    // full swipe reaches, which is what `onDelete` did here
                    // before: opening a confirmation is safe to trigger by
                    // accident in a way that unpairing would not be.
                    Button("Unpair", systemImage: "trash", role: .destructive) {
                        context.unpair.ask(about: peer)
                    }
                    // The same sheet the gear on the host's own screen opens,
                    // through the same router — the two screens are in the
                    // stack at once, and a `.sheet` on each would be two
                    // presentations of one intent.
                    Button("Settings", systemImage: "gearshape") {
                        context.peerSettings.show(peer)
                    }
                    .tint(.gray)
                    }
                }
            }
        }
        .overlay {
            if context.peers.peers.isEmpty, context.peers.failure == nil {
                if context.isRelayed {
                    // The watch pairs with nothing itself: it shows the hosts
                    // the phone has, once the phone has said what they are.
                    ContentUnavailableView(
                        "No hosts yet",
                        systemImage: "desktopcomputer",
                        description: Text("Pair a host in Bleat on your iPhone and it appears here.")
                    )
                } else {
                    ContentUnavailableView {
                        Label("No hosts yet", systemImage: "desktopcomputer")
                    } description: {
                        Text("Run `bleat pair` on the machine running Herdr, then scan the code it shows.")
                    } actions: {
                        Button("Pair a host", systemImage: "qrcode.viewfinder") { context.pairing.open() }
                    }
                }
            }
        }
        .navigationTitle("Bleat")
        // `.bottomBar` is unavailable on macOS, and `BleatUI` builds for both —
        // `swift build` compiles it for the Mac. Platform branches are allowed
        // here where they are not in `BleatKit`; `AddEndpointView` and
        // `PairingView` carry the same one.
        //
        // **The `#else` is not ceremony.** Guarding the whole `.toolbar` left
        // the macOS build with no way to pair and no way to open the device
        // key — a target that compiles and cannot be used. The placements
        // below are what was there before the bottom bar.
        #if os(iOS)
        .toolbar {
            bottomBar
        }
        #elseif !os(watchOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Pair a host", systemImage: "qrcode.viewfinder") { context.pairing.open() }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("This device's key", systemImage: "key") { isShowingKey = true }
            }
        }
        #endif
        .sheet(isPresented: $isShowingKey) {
            DeviceKeyView()
                .zoomTransition(from: "key", in: namespace)
        }
        // A `bleat://` link can arrive while this sheet is open — the user goes
        // to the system camera and comes back — and SwiftUI will not raise the
        // pairing sheet from the root over a sheet a descendant already has up.
        // The request would be silently lost *and* leave `isPresented` true
        // with nothing on screen, which makes the Pair button a no-op until the
        // app is relaunched. Yield to it instead.
        .onChange(of: context.pairing.isPresented) { _, isPairing in
            if isPairing { isShowingKey = false }
        }
        .task {
            context.peers.reload()
        }
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button("This device's key", systemImage: "key") { isShowingKey = true }
                .matchedZoomSource("key", in: namespace)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        // Trailing, where the plus is on every screen below this one: pairing
        // is how a host is added, whatever its icon.
        ToolbarItem(placement: .bottomBar) {
            Button("Pair a host", systemImage: "qrcode.viewfinder") { context.pairing.open() }
                .buttonStyle(.glassProminent)
        }
    }
    #endif
}

#if DEBUG
/// In the split view it lives in, so the selection behaves as it does on the
/// device — in a bare `NavigationStack` a tap highlights a row and nothing
/// else, which is not what this screen does.
#Preview("Hosts", traits: .sampleData) {
    NavigationSplitView { PeersView() } detail: { Text("Detail") }
}

/// The first screen on a fresh install, and the one that has to explain what to
/// do next — the `bleat pair` sentence is the entire onboarding.
#Preview("No hosts", traits: .noHosts) {
    NavigationSplitView { PeersView() } detail: { Text("Detail") }
}
#endif
