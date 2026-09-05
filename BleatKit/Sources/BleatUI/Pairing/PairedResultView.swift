import BleatKit
import SwiftUI

/// What pairing produced.
///
/// Shows the host key fingerprint because that is the peer's identity, and the
/// user has it in front of them on the Mac — `bleat pair` prints the same
/// string above the code. Matching them by eye is the one check no software in
/// this flow can do for them.
struct PairedResultView: View {
    let peer: PairedPeer

    var body: some View {
        Form {
            Section {
                LabeledContent("Host", value: peer.name)
                LabeledContent("User", value: peer.username)
                if let herdr = peer.herdrPath {
                    LabeledContent("herdr", value: herdr)
                        .font(.footnote.monospaced())
                }
            } header: {
                Label("Paired", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
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
    }
}

#if DEBUG
#Preview {
    PairedResultView(peer: .preview)
}
#endif
