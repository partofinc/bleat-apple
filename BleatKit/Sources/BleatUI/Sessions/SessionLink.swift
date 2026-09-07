import BleatKit
import SwiftUI

/// A session row that pushes its workspaces.
struct SessionLink: View {
    @Environment(AppContext.self) private var context
    let peer: PairedPeer
    let session: SessionInfo

    var body: some View {
        Button {
            context.navigation.push(.workspaces(peer: peer.hostKey, session: session.name))
        } label: {
            SessionRow(session: session)
        }
        .buttonStyle(.plain)
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
#endif
