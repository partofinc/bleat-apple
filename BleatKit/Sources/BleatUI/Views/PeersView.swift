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

    /// Snapshotted first: `remove` reloads the array, so indices after the
    /// first are stale — a multi-select delete would unpair the wrong host or
    /// run off the end.
    private func unpair(_ offsets: IndexSet) {
        let doomed = offsets.map { context.peers.peers[$0] }
        for peer in doomed { context.peers.remove(peer) }
    }
}
