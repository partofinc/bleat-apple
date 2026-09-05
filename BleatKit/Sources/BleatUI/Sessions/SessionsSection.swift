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
            case .loaded(let sessions) where sessions.isEmpty:
                Text("No sessions. Start one on the host with `herdr session attach <name>`.")
                    .foregroundStyle(.secondary)
            case .loaded(let sessions):
                ForEach(sessions) { session in
                    Button {
                        context.navigation.push(
                            .workspaces(peer: peer.hostKey, session: session.name)
                        )
                    } label: {
                        SessionRow(session: session)
                    }
                    .buttonStyle(.plain)
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
