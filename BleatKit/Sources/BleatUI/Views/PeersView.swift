import BleatKit
import SwiftUI

/// The first screen: the hosts this phone has paired with.
public struct PeersView: View {
    @Environment(AppContext.self) private var context
    @State private var isPairing = false
    @State private var isShowingKey = false

    public init() {}

    public var body: some View {
        List {
            if let failure = context.peers.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            ForEach(context.peers.peers) { peer in
                Button {
                    context.navigation.push(.peer(peer: peer.hostKey))
                } label: {
                    PeerRow(peer: peer)
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: unpair)
        }
        .overlay {
            if context.peers.peers.isEmpty, context.peers.failure == nil {
                ContentUnavailableView {
                    Label("No hosts yet", systemImage: "desktopcomputer")
                } description: {
                    Text("Run `bleat pair` on the machine running Herdr, then scan the code it shows.")
                } actions: {
                    Button("Pair a host", systemImage: "qrcode.viewfinder") { isPairing = true }
                }
            }
        }
        .navigationTitle("Bleat")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Pair a host", systemImage: "qrcode.viewfinder") { isPairing = true }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("This device's key", systemImage: "key") { isShowingKey = true }
            }
        }
        .sheet(isPresented: $isPairing) { PairingView(store: context.peers) }
        .sheet(isPresented: $isShowingKey) { DeviceKeyView() }
        .task {
            context.peers.reload()
            // Being back at the root means no host is being browsed, so the SSH
            // session opened for one should not stay open on someone's Mac.
            // Re-entering costs a handshake; an idle session costs their trust.
            await context.connections.release()
        }
    }

    /// Swiping to delete **asks**; it does not unpair.
    ///
    /// Unpairing is not list management — it decides what a machine will let
    /// in — and the record is the only thing that knows how to reach the host
    /// and which key line is this phone's. Dropping it on a swipe threw both
    /// away and left a working key behind.
    ///
    /// One at a time, because the flow is one modal conversation: a multi-row
    /// delete offers the first and the rest stay.
    private func unpair(_ offsets: IndexSet) {
        guard let first = offsets.first, context.peers.peers.indices.contains(first) else { return }
        context.unpair.ask(about: context.peers.peers[first])
    }
}
