import BleatKit
import SwiftUI

/// A session row that pushes its workspaces.
struct SessionLink: View {
    @Environment(AppContext.self) private var context
    let peer: PairedPeer
    let session: SessionInfo

    var body: some View {
        NavigationLink(value: NavigationRouter.Route.workspaces(peer: peer.hostKey, session: session.name)) {
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
