import BleatKit
import SwiftUI

/// Everything known about a paired host, and everything that can be changed
/// about it: who it logs in as, where it answers, and whether this phone is
/// still paired with it.
///
/// A sheet rather than a section under the sessions. What the user came for is
/// the list of sessions; this is what makes a connection problem diagnosable
/// once that list has failed, and none of it changes between visits. Reached
/// from the gear on the host's own screen and from a swipe on the peer list,
/// both through `PeerSettingsRouter` — see `PeerSettingsFlow` for why one
/// presentation rather than two.
struct PeerSettingsView: View {
    @Environment(AppContext.self) private var context
    @Environment(\.dismiss) private var dismiss
    /// Looked up on every body evaluation rather than held, because this screen
    /// writes: adding and removing an address both edit the record, and a
    /// captured value would go stale on the first one.
    let hostKey: String
    @State private var addingEndpoint = false

    var body: some View {
        NavigationStack {
            Group {
                if let peer {
                    settings(for: peer)
                } else {
                    unpaired
                }
            }
            .navigationTitle(peer?.name ?? "Host")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
    }

    private var peer: PairedPeer? {
        context.peers.peers.first { $0.hostKey == hostKey }
    }

    private func settings(for peer: PairedPeer) -> some View {
        Form {
            Section("Host") {
                LabeledContent("Name", value: peer.name)
                LabeledContent("User", value: peer.username)
                LabeledContent("herdr", value: peer.herdrPath ?? "not resolved")
                    .font(.footnote.monospaced())
            }

            // What the host last said it is. Stored on the peer, so it is here
            // whether or not anything is connected.
            if let info = peer.hostInfo, !info.isEmpty {
                Section {
                    if let system = info.system { LabeledContent("System", value: system) }
                    if let kernel = info.kernel {
                        LabeledContent(
                            "Kernel",
                            value: info.architecture.map { "\(kernel) · \($0)" } ?? kernel
                        )
                    }
                    if let model = info.model { LabeledContent("Model", value: model) }
                    if let version = info.herdrVersion {
                        LabeledContent("herdr version", value: version)
                    }
                } header: {
                    Text("System")
                } footer: {
                    Text("As \(peer.name) reported it the last time this phone connected.")
                }
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
                // `PeerStore.failure` is only rendered on the peer list behind
                // this sheet. The user swipes again, to the same effect.
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
            // A swipe on the peer list unpairs too, but a swipe has nowhere to
            // say what unpairing does — and what it does is decide whether this
            // phone can still open a shell on someone's Mac.
            Section {
                if let marker = peer.deviceMarker {
                    LabeledContent("Key on host", value: marker)
                        .font(.footnote.monospaced())
                }
                // Through the router, which closes this sheet first. The
                // confirmation is presented at the root, under here, so asking
                // directly would raise a dialog nobody can see.
                Button("Unpair \(peer.name)", role: .destructive) {
                    context.peerSettings.requestUnpair(peer)
                }
            } header: {
                Text("This device")
            } footer: {
                Text("Unpairing removes this device's key from \(peer.name), so this phone can no longer log in there.")
            }
        }
        .sheet(isPresented: $addingEndpoint) { AddEndpointView(peer: peer) }
    }

    /// Reachable: the sheet is open when the host is unpaired from underneath
    /// it — the unpair flow is presented at the root and outlives this. Saying
    /// so beats an empty form.
    private var unpaired: some View {
        ContentUnavailableView(
            "Host not paired",
            systemImage: "desktopcomputer.trianglebadge.exclamationmark",
            description: Text("This host was removed.")
        )
    }
}

#if DEBUG
/// Everything the peer screen used to carry below its sessions.
#Preview("Settings", traits: .sampleData) {
    PeerSettingsView(hostKey: PairedPeer.preview.hostKey)
}

/// The sparse record: no `herdrPath`, no device marker, one address — so every
/// row that has a fallback is showing it, and the Remove swipe is hidden
/// because removing the last address would strand the peer.
#Preview("Sparse", traits: .sampleData) {
    PeerSettingsView(hostKey: PairedPeer.previewSparse.hostKey)
}

/// Unpaired from underneath the sheet, which the root-level unpair flow can do
/// while this is on screen.
#Preview("Unpaired", traits: .sampleData) {
    PeerSettingsView(hostKey: "ssh-ed25519 a-host-key-that-is-not-in-the-list")
}
#endif
