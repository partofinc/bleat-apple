import BleatKit
import SwiftUI

/// Presents the peer settings sheet, once, for the whole app.
///
/// Attached at the root rather than on each screen that opens it, for the
/// reason `UnpairFlow` is: the peer list and a peer's own screen are both in
/// the navigation stack at the same time, and a modifier on each would bind two
/// presentations to one router.
struct PeerSettingsFlow: ViewModifier {
    @Environment(AppContext.self) private var context
    /// Declared here because the presentation is here — see
    /// `EnvironmentValues.peerSettingsNamespace` for why it is published
    /// downwards rather than declared by the screen holding the gear.
    @Namespace private var namespace

    func body(content: Content) -> some View {
        @Bindable var router = context.peerSettings
        content
            .environment(\.peerSettingsNamespace, namespace)
            .sheet(item: $router.peer, onDismiss: startPendingUnpair) { host in
                PeerSettingsView(hostKey: host.id)
                    // Keyed by host key rather than a constant, so the sheet
                    // grows out of the gear belonging to *this* host. A swipe
                    // on the peer list opens the same sheet with no source on
                    // screen, which is a plain presentation.
                    .zoomTransition(from: host.id, in: namespace)
            }
            // A `bleat://` link can arrive while this sheet is up — the user
            // goes to the system camera and comes back — and SwiftUI will not
            // raise a second sheet over one that is already presented. The
            // pairing request would be silently lost *and* leave its
            // `isPresented` true with nothing on screen, which makes the Pair
            // button a no-op until the app is relaunched. Yield to it, exactly
            // as `PeersView` does with the device key sheet.
            .onChange(of: context.pairing.isPresented) { _, isPairing in
                if isPairing { context.peerSettings.close() }
            }
    }

    /// The unpair the sheet asked for, started now that it has gone.
    ///
    /// `UnpairFlow`'s confirmation dialog is presented at the root, under this
    /// sheet. Asking while the sheet was still up would put the dialog behind
    /// it — the tap would appear to do nothing at all.
    private func startPendingUnpair() {
        guard let peer = context.peerSettings.takePendingUnpair() else { return }
        context.unpair.ask(about: peer)
    }
}

extension View {
    func peerSettingsSheet() -> some View { modifier(PeerSettingsFlow()) }
}

// No `#Preview` of its own: like `UnpairFlow` and `PairingFlow` it presents
// rather than draws. `RootView` previews it in place, and `PeerSettingsView`
// previews what it presents.
