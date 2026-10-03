import BleatKit
import SwiftUI

/// Puts the host's load in a bar under a screen, while there is one to show.
///
/// **Not on a watch**, where it is a row at the top of the list instead — see
/// `HostLoadSection`. The screens carry both and each draws on its own
/// platform.
///
/// **It also asks for the reading, each time a connection comes up** —
/// `.task(id:)` on the connection's number. Arriving on a host from the list,
/// there is no connection when the screen appears: the screen's own list
/// dials it, and the number changing is what starts the read, so it is never
/// the reason for a dial. A re-dial gets a reading of its own the same way,
/// rather than an empty bar until a pull-to-refresh. With no connection the
/// number is nil and `HostLoadStore.refresh` returns at once, so this is
/// still safe on a screen drawn with none — a preview or a render test.
///
/// The screens still ask after their own lists load — which covers a pop back
/// to a screen, where `.task(id:)` does not run again — and force one on a
/// pull-to-refresh. A read already in flight or under ten seconds old turns
/// the extra asks away.
///
/// On the host's screen, a session's and a workspace's. **Not on a pane**:
/// layout there is the stream's size, and a bar that comes and goes with the
/// connection would resize the pty on someone's Mac.
struct HostLoadBarModifier: ViewModifier {
    @Environment(AppContext.self) private var context
    let peer: PairedPeer

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .bottom) {
                if !WatchLayout.isHere, let load = context.hostLoad.load(for: peer) {
                    HostLoadBar(load: load)
                }
            }
            // On the watch too, where the bar draws nothing and the reading
            // is `HostLoadSection`'s row.
            .task(id: context.connections.connectionID(for: peer)) {
                await context.hostLoad.refresh(for: peer)
            }
    }
}

extension View {
    /// The host's load under this screen, read whenever a connection to the
    /// host comes up.
    func hostLoadBar(for peer: PairedPeer) -> some View {
        modifier(HostLoadBarModifier(peer: peer))
    }
}

// No `#Preview`: `HostLoadBar` has them, and the screens that carry this.
