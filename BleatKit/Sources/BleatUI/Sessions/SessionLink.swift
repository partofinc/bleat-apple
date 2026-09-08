import BleatKit
import SwiftUI

/// A session row that pushes its workspaces, and — for a session this phone
/// started — swipes to stop or delete it.
struct SessionLink: View {
    let peer: PairedPeer
    let session: SessionInfo
    /// Nil where the actions are not offered at all, which is every screen but
    /// the peer's own. The swipe exists to manage sessions, and a session row
    /// appears nowhere else today; passing the model rather than reading it
    /// from the context keeps that a decision of the screen rather than of the
    /// row.
    var control: SessionControlModel?

    var body: some View {
        NavigationLink(value: NavigationRouter.Route.workspaces(peer: peer.hostKey, session: session.name)) {
            SessionRow(session: session)
        }
        .buttonStyle(.plain)
        // **Asking, never acting** — the rule the peer row already follows.
        // Stopping a session ends every process in it, which is not something a
        // full swipe may do on its own; what a full swipe reaches here is a
        // confirmation. And nothing is offered at all for a session this phone
        // did not create, so the host's real work has no swipe.
        .swipeActions {
            if let control {
                ForEach(SessionControlModel.actions(for: session, on: peer), id: \.self) { action in
                    // **Tinted red rather than given the destructive role**,
                    // which in a swipe action is not just a colour: SwiftUI
                    // takes it as "this row is going away" and animates it out
                    // of the list the moment the button is tapped. These
                    // buttons only open a confirmation, so the row went missing
                    // before the user had answered — and stayed missing when
                    // they cancelled, and after a Stop, which leaves the
                    // session listed and merely not running. The row must
                    // change only when the host's answer changes it.
                    Button {
                        control.begin(action, about: session, on: peer)
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                    // Start is the one that undoes rather than destroys, so it
                    // is not dressed as a warning.
                    .tint(action == .start ? .green : .red)
                    .disabled(control.isWorking)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Session links", traits: .sampleData) {
    NavigationStack {
        List {
            ForEach(SessionInfo.samples) { session in
                SessionLink(peer: .preview, session: session)
            }
        }
    }
}

/// The same rows on a peer that started two of them from this phone: `work`
/// swipes to Stop because it runs, `bleat-test` to Delete because it does not,
/// and `phone` — which this install did not create — has no swipe at all.
#Preview("Session links, some ours", traits: .sampleData) {
    NavigationStack {
        List {
            ForEach(SessionInfo.samples) { session in
                SessionLink(
                    peer: .previewOwningSessions,
                    session: session,
                    control: SessionControlModel(previewing: .idle)
                )
            }
        }
    }
}
#endif
