import BleatKit
import SwiftUI

/// One paired host: what is running on it, and what is known about it.
///
/// The sessions come first because they are what the user came for. The pairing
/// details stay below them rather than moving to a separate screen — they are
/// what makes a connection problem diagnosable from the phone, and the moment
/// they are worth reading is the moment the list above has failed.
struct PeerDetailView: View {
    @Environment(AppContext.self) private var context
    /// The peer as it was when this screen was pushed. Read through `peer`
    /// below rather than used directly: editing an address rewrites the record,
    /// and a screen holding the version from before the edit would show the old
    /// list until it was popped and pushed again.
    let initialPeer: PairedPeer
    @State private var sessions: RemoteList<SessionInfo>
    @State private var addingEndpoint = false

    /// The stored record, falling back to the one this screen was built with.
    ///
    /// The fallback is what keeps unpairing from flashing an empty screen: the
    /// record is deleted while this view is still on the stack for the moment
    /// before the navigation pops.
    private var peer: PairedPeer {
        context.peers.peers.first { $0.hostKey == initialPeer.hostKey } ?? initialPeer
    }

    /// Takes the store rather than reading `AppContext`, so the model exists
    /// from the first body onwards and a refresh cannot rebuild it mid-load.
    init(peer: PairedPeer, connections: ConnectionStore) {
        self.initialPeer = peer
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

            Section {
                ForEach(peer.endpoints, id: \.self) { endpoint in
                    EndpointRow(endpoint: endpoint, isLastGood: endpoint == peer.lastGoodEndpoint)
                        .swipeActions {
                            // Hidden on the last one rather than shown and
                            // refused. A peer with no addresses cannot be
                            // connected to, and since nothing can add one back
                            // without a connection, the only way out would be a
                            // walk to the Mac. Unpairing is the deliberate way
                            // to be rid of a peer, and it is right below.
                            if peer.endpoints.count > 1 {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    context.peers.removeEndpoint(endpoint, from: peer)
                                }
                            }
                        }
                }
                Button("Add an address", systemImage: "plus") { addingEndpoint = true }
            } header: {
                Text("Reachable at")
            } footer: {
                // Says the two things a user would otherwise learn by being
                // surprised: that this list maintains itself, and therefore
                // that removing an address the host still reports will not
                // stick. Which is also what "cannot know about itself" is
                // pointing at — those are the ones worth adding by hand.
                Text("Bleat asks \(peer.name) for its addresses each time it connects, so this list keeps itself up to date. Add one the host cannot know about itself — a VPN name that only resolves on this phone, or a port forward.")
            }

            // The other half of pairing, and the half that has to be visible.
            // A swipe on the list unpairs too, but a swipe has nowhere to say
            // what unpairing does — and what it does is decide whether this
            // phone can still open a shell on someone's Mac.
            Section {
                if let marker = peer.deviceMarker {
                    LabeledContent("Key on host", value: marker)
                        .font(.footnote.monospaced())
                }
                Button("Unpair \(peer.name)", role: .destructive) {
                    context.unpair.ask(about: peer)
                }
            } header: {
                Text("This device")
            } footer: {
                Text("Unpairing removes this device's key from \(peer.name), so this phone can no longer log in there.")
            }
        }
        .navigationTitle(peer.name)
        .refreshable { await sessions.load(for: peer) }
        .task { await sessions.load(for: peer) }
        .sheet(isPresented: $addingEndpoint) { AddEndpointView(peer: peer) }
    }
}

// No `#Preview` here any more: the screen now loads sessions in `task`, which
// means a Keychain read and an SSH connection attempt. A preview that reaches
// for the real device key is not a preview. The rows it is built from —
// `SessionRow`, `EndpointRow` — are pure and preview on their own.
