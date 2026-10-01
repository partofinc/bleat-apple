import BleatKit
import SwiftUI

/// One paired host in the list.
struct PeerRow: View {
    let peer: PairedPeer

    var body: some View {
        HStack(spacing: 12) {
            // A fixed width, so names line up whichever mark is beside them.
            (peer.hostInfo?.platform ?? .unknown).mark
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(peer.name)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What the host last said it runs. Until it has said — a peer paired and
    /// never connected to — where it is, which is all that is known.
    private var detail: String {
        peer.hostInfo?.system ?? "\(peer.username)@\(address)"
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
#Preview("Peer rows", traits: .sampleData) {
    List {
        // A Mac, a Pi, and one that has never been connected to — which has no
        // mark of its own and still says where it is.
        ForEach(PairedPeer.samples) { peer in
            PeerRow(peer: peer)
        }
    }
}
#endif
