import BleatKit
import SwiftUI

/// The confirmation a swipe reaches, and the explanation if the host refuses.
///
/// Attached once to the sessions screen rather than to each row, for the reason
/// `UnpairFlow` is attached to the stack: a `confirmationDialog` per row is one
/// presentation per session, of which SwiftUI raises whichever it reaches first
/// and silently drops the rest.
///
/// **The dialog is the whole safety story for stopping.** herdr ends every
/// process in a session when it stops — measured, a pane's shell was gone a
/// second later — and there is no undo and nothing at the Mac saying who did
/// it. So the message names the session and says what goes with it, rather than
/// asking "are you sure?" about a verb.
struct SessionControlFlow: ViewModifier {
    let control: SessionControlModel
    let peer: PairedPeer
    /// Run after something actually happened, so the screen reflects it. Takes
    /// the action because the right answer differs: a list refreshes, while the
    /// screen *inside* a session it has just deleted has to leave.
    let reload: (SessionControlModel.Action) async -> Void

    func body(content: Content) -> some View {
        @Bindable var control = control
        content
            // Installed once, for every way an action can start. Assigned here
            // rather than passed to each call site because there are two of
            // those — the dialog's button and a button that needs no dialog —
            // and giving it to only the first is exactly the bug this fixes.
            .onAppear { control.onCompleted = reload }
            .confirmationDialog(
                title, isPresented: $control.isConfirming, titleVisibility: .visible
            ) {
                // **Captured here, not read back when the task runs.**
                // SwiftUI clears `isPresented` before running this action, and
                // that write resets the model's phase — so reading the pending
                // action inside the closure finds nothing armed and the tap
                // does nothing, silently. `UnpairFlow` captures its peer for
                // the same reason.
                if let pending = control.pending {
                    Button(pending.action.title, role: .destructive) {
                        // No reload here: `perform` calls `onCompleted` itself,
                        // so this path and the one that raises no dialog end
                        // the same way.
                        Task { await control.perform(pending.action, about: pending.session, on: peer) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(message)
            }
            // An alert rather than a line under the list: the row is still
            // there but says nothing about a refusal, and the commonest cause
            // — the session being in a state herdr will not do this from —
            // is a sentence worth reading rather than a badge.
            .alert(
                "That did not happen",
                isPresented: $control.isShowingFailure
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(control.failureMessage ?? "The host did not say why.")
            }
    }

    private var title: String {
        guard let pending = control.pending else { return "" }
        return "\(pending.action.title) \(pending.session.name)?"
    }

    private var message: String {
        guard let pending = control.pending else { return "" }
        switch pending.action {
        // Never asked about — `needsConfirmation` says so — but the switch has
        // to be total.
        case .start: return ""
        case .stop:
            // Named plainly, because it is the part that cannot be taken back.
            // Anything running in that session — an agent mid-task included —
            // exits with it.
            return "Everything running in \(pending.session.name) on \(peer.name) exits, "
                + "including any agents. This cannot be undone."
        case .delete:
            return "\(pending.session.name) and its workspaces are removed from \(peer.name)."
        }
    }
}

extension View {
    /// Confirms and reports the stop and delete actions for one screen's rows.
    func sessionControl(
        _ control: SessionControlModel,
        on peer: PairedPeer,
        reload: @escaping (SessionControlModel.Action) async -> Void
    ) -> some View {
        modifier(SessionControlFlow(control: control, peer: peer, reload: reload))
    }
}

// No `#Preview`: like `UnpairFlow` and `PeerSettingsFlow` this presents rather
// than draws. `PeerDetailView`'s previews exercise it in place.
