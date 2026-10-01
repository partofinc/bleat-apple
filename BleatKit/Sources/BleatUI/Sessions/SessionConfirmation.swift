import BleatKit
import SwiftUI

/// The question in front of a stop or a delete, attached to whatever asked it.
///
/// **Where this is attached is where the dialog comes from.** On iOS 26 a
/// confirmation dialog grows out of the view that presents it, so one attached
/// to a toolbar button opens out of that button — and one attached to the
/// screen, for a button in a bar, appears from nowhere near the finger. A
/// toolbar button therefore carries its own, naming the one `action` it asks
/// about. A swipe has no view that outlives the gesture, so the screen holds
/// one for its rows with `action` nil — see `SessionControlFlow`.
///
/// **Never both for one model.** Two dialogs bound to one question is two
/// presentations of one intent, of which SwiftUI raises whichever it reaches
/// first and silently drops the other.
struct SessionConfirmation: ViewModifier {
    let control: SessionControlModel
    let peer: PairedPeer
    /// The one action this source asks about, or nil for whichever is pending.
    let action: SessionControlModel.Action?

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            // **Captured here, not read back when the task runs.** SwiftUI
            // clears `isPresented` before running this action, and that write
            // resets the model's phase — so reading the pending action inside
            // the closure finds nothing armed and the tap does nothing,
            // silently. `UnpairFlow` captures its peer for the same reason.
            if let pending = control.pending {
                Button(pending.action.title, role: .destructive) {
                    // No reload here: `perform` calls `onCompleted` itself, so
                    // this path and the one that raises no dialog end the same
                    // way.
                    Task { await control.perform(pending.action, about: pending.session, on: peer) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }

    /// Whether the question being asked is this source's to present.
    private var isAsking: Bool {
        control.isConfirming && (action == nil || control.pending?.action == action)
    }

    /// **The write is guarded as well as the read.** Two buttons on one bar
    /// each carry one of these over the same model, and a dismissal written by
    /// the one that was never presented would cancel the other's question.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { isAsking },
            set: { presented in
                if !presented, isAsking { control.isConfirming = false }
            }
        )
    }

    private var title: String {
        guard let pending = control.pending else { return "" }
        return "\(pending.action.title) \(pending.session.name)?"
    }

    /// **The wording lives on the model, not here.** Stop is offered for every
    /// running session now, so what this says is the safety story rather than a
    /// label for it — and a `private var` on a view modifier is something no
    /// test can read. See `SessionControlModel.confirmation(for:about:on:)`.
    private var message: String {
        guard let pending = control.pending else { return "" }
        return SessionControlModel.confirmation(
            for: pending.action, about: pending.session, on: peer
        )
    }
}

extension View {
    /// Asks before a stop or a delete, out of this view.
    ///
    /// - Parameter action: the one action this view starts, for a button; nil
    ///   for a screen answering for its rows.
    func sessionConfirmation(
        _ control: SessionControlModel,
        for action: SessionControlModel.Action? = nil,
        on peer: PairedPeer
    ) -> some View {
        modifier(SessionConfirmation(control: control, peer: peer, action: action))
    }
}

// No `#Preview`: this presents rather than draws. `WorkspacesView`'s previews
// carry it on their bar, and `PeerDetailView`'s behind their rows.
