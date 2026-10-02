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
        #if os(watchOS)
        // A row and not a link: a terminal is a stream, and the watch has
        // none — see `RelayTransport`. An agent's row still opens, because
        // its conversation is a file.
        TerminalRow(pane: pane)
        #else
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
        #endif
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
