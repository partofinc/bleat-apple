import SwiftUI

/// Closes a presentation when a `bleat://` link arrives — but not in the middle
/// of a write.
///
/// **Two rules that pull against each other, which is why this is one place
/// rather than three.**
///
/// SwiftUI will not raise a second presentation over one already up, so a
/// pairing request arriving while a sheet is on screen is lost *and* leaves
/// `PairingRouter.isPresented` true with nothing visible — which makes the Pair
/// button a no-op until the app is relaunched. Every presentation in the app
/// therefore stands aside; `PeersView` and `PeerSettingsFlow` were doing it by
/// hand first.
///
/// But the sheets that *write* — starting a session, creating a workspace,
/// starting an agent — are the only place their outcome is ever reported, which
/// is why each refuses an interactive dismissal while its work is in flight.
/// Tearing one down from here would defeat that: a start that took the full
/// thirty seconds and came back "something may be running in that pane" would
/// have nowhere to say so, and the next open resets the model and wipes it.
///
/// So the dismissal **waits for the write to finish** and then happens. The
/// pairing sheet is delayed by at most the length of one command, and nothing
/// that was done on someone's Mac goes unreported.
struct PairingYield: ViewModifier {
    @Environment(AppContext.self) private var context
    /// True while something is being written to the host.
    let isBusy: Bool
    @Binding var isPresented: Bool

    @State private var waiting = false

    func body(content: Content) -> some View {
        content
            .onChange(of: context.pairing.isPresented) { _, isPairing in
                guard isPairing, isPresented else { return }
                if isBusy { waiting = true } else { isPresented = false }
            }
            .onChange(of: isBusy) { _, busy in
                guard !busy, waiting else { return }
                waiting = false
                isPresented = false
            }
            // A presentation that closes on its own leaves nothing to wait for.
            .onChange(of: isPresented) { _, showing in
                if !showing { waiting = false }
            }
    }
}

extension View {
    /// Stands aside for a `bleat://` link, once any write in flight has
    /// finished. See `PairingYield`.
    func yieldsToPairing(whileBusy isBusy: Bool, presenting isPresented: Binding<Bool>) -> some View {
        modifier(PairingYield(isBusy: isBusy, isPresented: isPresented))
    }
}
