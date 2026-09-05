import BleatKit
import SwiftUI

/// One paired host: what is running on it, and what is known about it.
///
/// The sessions come first because they are what the user came for. The pairing
/// details stay below them rather than moving to a separate screen — they are
/// what makes a connection problem diagnosable from the phone, and the moment
/// they are worth reading is the moment the list above has failed.
struct PeerDetailView: View {
    let peer: PairedPeer
    @State private var sessions: RemoteList<SessionInfo>

    /// Takes the store rather than reading `AppContext`, so the model exists
    /// from the first body onwards and a refresh cannot rebuild it mid-load.
    init(peer: PairedPeer, connections: ConnectionStore) {
        self.peer = peer
        // No session prefix: `session list` is a client-side command that
        // reports every session regardless of which one is selected.
        _sessions = State(wrappedValue: RemoteList(connections: connections, session: nil) {
            try await $0.sessions()
        })
    }

    var body: some View {
        Form {
            SessionsSection(peer: peer, model: sessions)

            Section("Host") {
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

        }
        .navigationTitle(peer.name)
        .refreshable { await sessions.load(for: peer) }
        .task { await sessions.load(for: peer) }
    }
}

// No `#Preview` here any more: the screen now loads sessions in `task`, which
// means a Keychain read and an SSH connection attempt. A preview that reaches
// for the real device key is not a preview. The rows it is built from —
// `SessionRow`, `EndpointRow` — are pure and preview on their own.
