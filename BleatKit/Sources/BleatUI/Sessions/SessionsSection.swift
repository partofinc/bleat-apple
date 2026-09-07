import BleatKit
import SwiftUI

/// The sessions on a host, wherever they are being shown.
struct SessionsSection: View {
    let peer: PairedPeer
    let model: RemoteList<SessionInfo>
    @Environment(AppContext.self) private var context

    var body: some View {
        Section {
            switch model.state {
            case .loading:
                // In a row rather than over the screen: the host details below
                // are already useful, and taking them away to show a spinner
                // would be a downgrade.
                HStack {
                    ProgressView()
                    Text("Reaching \(peer.name)…")
                        .foregroundStyle(.secondary)
                }
            case .stale(let sessions, let message):
                // The rows stay; the failure sits above them. Losing a list
                // that arrived fine because a refresh dropped a packet is the
                // worse answer.
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
                ForEach(sessions) { session in
                    SessionLink(peer: peer, session: session)
                }
            case .loaded(let sessions) where sessions.isEmpty:
                Text("No sessions. Start one on the host with `herdr session attach <name>`.")
                    .foregroundStyle(.secondary)
            case .loaded(let sessions):
                ForEach(sessions) { session in
                    SessionLink(peer: peer, session: session)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Try again") {
                    Task { await model.load(for: peer) }
                }
            }
        } header: {
            Text("Sessions")
        }
    }
}

#if DEBUG
/// The section has five states of its own, and three of them are only reachable
/// from a host that is misbehaving — which is precisely why they want a canvas.
#Preview("Loaded", traits: .sampleData) {
    Form {
        SessionsSection(peer: .preview, model: RemoteList(previewing: .loaded(SessionInfo.samples)))
    }
}

#Preview("Loading", traits: .sampleData) {
    Form {
        SessionsSection(peer: .preview, model: RemoteList(previewing: .loading))
    }
}

#Preview("No sessions", traits: .sampleData) {
    Form {
        SessionsSection(peer: .preview, model: RemoteList(previewing: .loaded([])))
    }
}

#Preview("Failed", traits: .sampleData) {
    Form {
        SessionsSection(
            peer: .preview,
            model: RemoteList(previewing: .failed("none of 3 addresses could be reached"))
        )
    }
}

/// A refresh that dropped, over rows that had already arrived. They stay; the
/// failure sits above them.
#Preview("Stale", traits: .sampleData) {
    Form {
        SessionsSection(
            peer: .preview,
            model: RemoteList(previewing: .stale(SessionInfo.samples, "the connection closed"))
        )
    }
}
#endif
