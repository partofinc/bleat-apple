import BleatKit
import SwiftUI

/// Puts the host's load in a bar under a screen, while there is one to show.
///
/// **Not on a watch**, where it is a row at the top of the list instead — see
/// `HostLoadSection`. The screens carry both and each draws on its own
/// platform.
///
/// **It draws and nothing else.** It does not ask for a reading: the screen
/// does, after its own list has loaded — see `HostLoadStore` for why the order
/// matters. So this is safe on a screen drawn with no connection at all.
///
/// On the host's screen, a session's and a workspace's. **Not on a pane**:
/// layout there is the stream's size, and a bar that comes and goes with the
/// connection would resize the pty on someone's Mac.
struct HostLoadBarModifier: ViewModifier {
    @Environment(AppContext.self) private var context
    let peer: PairedPeer

    func body(content: Content) -> some View {
        content.safeAreaBar(edge: .bottom) {
            if !WatchLayout.isHere, let load = context.hostLoad.load(for: peer) {
                HostLoadBar(load: load)
            }
        }
    }
}

extension View {
    /// The host's load under this screen, once it has been read.
    func hostLoadBar(for peer: PairedPeer) -> some View {
        modifier(HostLoadBarModifier(peer: peer))
    }
}

// No `#Preview`: `HostLoadBar` has them, and the screens that carry this.
