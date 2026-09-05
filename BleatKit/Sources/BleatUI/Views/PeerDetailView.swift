import BleatKit
import SwiftUI

/// What is known about one paired host.
///
/// The sessions and workspaces that belong here land with the screens that read
/// them; until then this shows what pairing actually produced, which is what
/// makes a pairing problem diagnosable from the phone.
struct PeerDetailView: View {
    let peer: PairedPeer

    var body: some View {
        Form {
            Section {
                LabeledContent("User", value: peer.username)
                LabeledContent("herdr", value: peer.herdrPath ?? "not resolved")
                    .font(.footnote.monospaced())
            }

            Section("Host key") {
                Text(peer.hostKeyFingerprint ?? peer.hostKey)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }

            Section("Reachable at") {
                ForEach(peer.endpoints, id: \.self) { endpoint in
                    EndpointRow(endpoint: endpoint, isLastGood: endpoint == peer.lastGoodEndpoint)
                }
            }

            Section {
                ContentUnavailableView {
                    Label("Sessions", systemImage: "rectangle.dashed")
                } description: {
                    Text("Workspaces and panes land in the next step.")
                }
            }
        }
        .navigationTitle(peer.name)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        PeerDetailView(peer: .preview)
    }
}
#endif
