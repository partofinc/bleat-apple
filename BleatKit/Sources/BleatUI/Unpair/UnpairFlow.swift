import BleatKit
import SwiftUI

/// Presents the unpair flow, once, for the whole app.
///
/// Attached at the root rather than on each screen that can start it. Both the
/// peer list and a peer's detail screen are in the navigation stack at the same
/// time, so a modifier on each would give two presentations bound to one piece
/// of state — and SwiftUI presents whichever it reaches first while the other
/// silently does nothing.
struct UnpairFlow: ViewModifier {
    @Environment(AppContext.self) private var context

    func body(content: Content) -> some View {
        @Bindable var model = context.unpair
        content
            .confirmationDialog(
                title(for: model.peerBeingUnpaired),
                isPresented: $model.isConfirming,
                titleVisibility: .visible
            ) {
                // The peer is captured here rather than read back out of the
                // model when the task runs: dismissing the dialog resets
                // `phase`, and if that write-back lands first the tap would do
                // nothing at all — silently.
                if let peer = model.peerBeingUnpaired {
                    Button("Unpair", role: .destructive) {
                        Task { await model.unpair(peer) }
                    }
                }
                Button("Cancel", role: .cancel) { model.cancel() }
            } message: {
                Text("Bleat will remove this device's key from the Mac, so this phone can no longer log in to it.")
            }
            .sheet(isPresented: $model.isShowingProgress) {
                UnpairSheet(model: model)
            }
    }

    private func title(for peer: PairedPeer?) -> String {
        peer.map { "Unpair \($0.name)?" } ?? "Unpair?"
    }
}

extension View {
    func unpairFlow() -> some View { modifier(UnpairFlow()) }
}
