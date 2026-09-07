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
    /// Always current: `RouteView` looks the peer up by host key on every body
    /// evaluation and hands the stored value in, so an edit here is reflected
    /// without this screen tracking the store itself — and a peer that has been
    /// unpaired swaps the whole screen out one level up rather than needing a
    /// fallback here.
    let peer: PairedPeer
    @State private var sessions: RemoteList<SessionInfo>
    @State private var addingEndpoint = false

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

    #if DEBUG
    /// Preview-only: the sessions are handed in and nothing is fetched.
    init(peer: PairedPeer, previewing state: Loadable<[SessionInfo]>) {
        self.peer = peer
        _sessions = State(wrappedValue: RemoteList(previewing: state))
    }
    #endif

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
                        // `allowsFullSwipe: false`, so removing takes a
                        // deliberate tap. An address the user added by hand is
                        // one detection can never report, so deleting it is
                        // permanent and undone only by retyping it from memory
                        // — and the peer list beside this one already refuses
                        // to let a full swipe act rather than ask.
                        .swipeActions(allowsFullSwipe: false) {
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
                // Editing writes to disk, and a write can fail — an unwritable
                // container, a full disk. Without this the row simply stays
                // where it was and the swipe looks like it did nothing, because
                // `PeerStore.failure` is only rendered a screen back on the
                // peer list. The user swipes again, to the same effect.
                if let failure = context.peers.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
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

#if DEBUG
/// Previewable again. The screen loads its sessions in `task`, which used to
/// mean an SSH connection attempt from the canvas; `init(peer:previewing:)`
/// hands them in instead, so nothing here dials.
#Preview("Peer", traits: .sampleData) {
    NavigationStack {
        PeerDetailView(peer: .preview, previewing: .loaded(SessionInfo.samples))
    }
}

/// The sparse record: no `herdrPath`, no device marker, one mDNS address. Every
/// row that has a fallback is showing it.
#Preview("Sparse", traits: .sampleData) {
    NavigationStack {
        PeerDetailView(peer: .previewSparse, previewing: .loaded([]))
    }
}

/// The host could not be reached, which is exactly when the details below the
/// sessions section become the useful part of this screen.
#Preview("Unreachable", traits: .sampleData) {
    NavigationStack {
        PeerDetailView(
            peer: .previewOverlayOnly,
            previewing: .failed("this host is only reachable over a VPN from here, and nothing "
                                + "answered — check that a VPN reaching it is connected on this device")
        )
    }
}

/// Still connecting: the sessions section shows its own row rather than taking
/// the host details off the screen behind a spinner.
#Preview("Loading", traits: .sampleData) {
    NavigationStack {
        PeerDetailView(peer: .preview, previewing: .loading)
    }
}
#endif
