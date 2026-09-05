import BleatKit
import SwiftUI

/// One paired host in the list.
struct PeerRow: View {
    let peer: PairedPeer

    var body: some View {
        VStack(alignment: .leading) {
            Text(peer.name)
                .font(.headline)
            Text("\(peer.username)@\(address)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The address it last answered on, falling back to the first it knows.
    /// The list is ordered by preference, so the first is the best guess.
    private var address: String {
        peer.lastGoodEndpoint?.description
            ?? peer.endpoints.first?.description
            ?? "no address"
    }
}

#if DEBUG
#Preview {
    List {
        PeerRow(peer: .preview)
    }
}
#endif
