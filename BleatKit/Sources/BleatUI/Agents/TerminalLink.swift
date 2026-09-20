import BleatKit
import SwiftUI

/// A plain shell's row, which opens its pane in the terminal.
///
/// **Terminal, not chat.** A shell writes no transcript, so the chat this app
/// opens an *agent* in would be an empty screen with a button on it. The mode
/// is part of the route for exactly this reason.
struct TerminalLink: View {
    let peer: PairedPeer
    let session: String?
    let pane: Pane

    var body: some View {
        NavigationLink(
            value: NavigationRouter.Route.pane(
                peer: peer.hostKey,
                session: session,
                target: pane.target,
                title: pane.displayTitle,
                mode: .terminal
            )
        ) {
            TerminalRow(pane: pane)
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("Terminal links", traits: .sampleData) {
    NavigationStack {
        List {
            ForEach(Pane.samples) { pane in
                TerminalLink(peer: .preview, session: "work", pane: pane)
            }
        }
    }
}
#endif
