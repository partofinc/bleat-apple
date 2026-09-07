import BleatKit
import SwiftUI

/// Presents the pairing sheet, once, for the whole app.
///
/// Attached at the root for the reason `UnpairFlow` is: two places start it —
/// the peer list's button and a `bleat://` link the system delivers — and a
/// link can arrive while the user is deep in the navigation stack, where the
/// peer list's own `@State` is not being evaluated at all.
struct PairingFlow: ViewModifier {
    @Environment(AppContext.self) private var context

    func body(content: Content) -> some View {
        @Bindable var pairing = context.pairing
        content
            .sheet(isPresented: $pairing.isPresented) {
                PairingView(store: context.peers, code: pairing.takeIncomingCode())
            }
            // Handled here rather than on the app's `WindowGroup` so the router
            // is read from the environment the same way everything else is.
            .onOpenURL { url in
                context.pairing.open(code: url.absoluteString)
            }
    }
}

extension View {
    func pairingFlow() -> some View { modifier(PairingFlow()) }
}
