import BleatKit
import SwiftUI

/// What a session action needs from its screen: the confirmation a swipe
/// reaches, the reload once something happened, and the explanation if the host
/// refuses.
///
/// Attached once to the sessions screen rather than to each row, for the reason
/// `UnpairFlow` is attached to the stack: a `confirmationDialog` per row is one
/// presentation per session, of which SwiftUI raises whichever it reaches first
/// and silently drops the rest.
///
/// **The dialog is the whole safety story for stopping, and that is now literal
/// rather than nearly so.** herdr ends every process in a session when it stops
/// — measured, a pane's shell was gone a second later — there is no undo and
/// nothing at the Mac saying who did it, and since Stop stopped being gated on
/// `startedHere` there is no second guard behind this one. So the message names
/// the session, says what goes with it and says whose it is, rather than asking
/// "are you sure?" about a verb. The dialog itself is `SessionConfirmation`.
struct SessionControlFlow: ViewModifier {
    let control: SessionControlModel
    let peer: PairedPeer
    /// Whether the screen asks the question itself. True for a list, whose
    /// swipes have nothing else to ask from; false where the actions are
    /// toolbar buttons, each of which carries its own `sessionConfirmation` so
    /// the dialog opens out of the button that was tapped.
    let confirmsHere: Bool
    /// Run after something actually happened, so the screen reflects it. Takes
    /// the action because the right answer differs: a list refreshes, while the
    /// screen *inside* a session it has just deleted has to leave.
    let reload: (SessionControlModel.Action) async -> Void

    func body(content: Content) -> some View {
        @Bindable var control = control
        confirming(content)
            // Installed once, for every way an action can start. Assigned here
            // rather than passed to each call site because there are two of
            // those — the dialog's button and a button that needs no dialog —
            // and giving it to only the first is exactly the bug this fixes.
            .onAppear { control.onCompleted = reload }
            // **And cleared, or the screen never goes.** `reload` captures the
            // view, which holds the `@State` box, which holds this model, which
            // holds `reload` — a cycle that leaks a model and everything it
            // captured on every push. Re-installed on the way back in.
            .onDisappear { control.onCompleted = nil }
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

    /// A branch that cannot flip: `confirmsHere` is fixed by the call site, so
    /// the `_ConditionalContent` this builds keeps one identity for the life of
    /// the screen.
    @ViewBuilder
    private func confirming(_ content: Content) -> some View {
        if confirmsHere {
            content.sessionConfirmation(control, on: peer)
        } else {
            content
        }
    }
}

extension View {
    /// Reports the start, stop and delete actions for one screen, and confirms
    /// them unless its buttons do that themselves.
    func sessionControl(
        _ control: SessionControlModel,
        on peer: PairedPeer,
        confirmsHere: Bool = true,
        reload: @escaping (SessionControlModel.Action) async -> Void
    ) -> some View {
        modifier(SessionControlFlow(
            control: control, peer: peer, confirmsHere: confirmsHere, reload: reload
        ))
    }
}

// No `#Preview`: like `UnpairFlow` and `PeerSettingsFlow` this presents rather
// than draws. `PeerDetailView`'s previews exercise it in place.
