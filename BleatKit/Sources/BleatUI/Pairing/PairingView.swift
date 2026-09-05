import BleatKit
import SwiftUI

/// The pairing sheet: point the camera at what `bleat pair` is showing.
public struct PairingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: PairingModel

    /// Takes the store rather than reading `AppContext`, so the model can be
    /// built in `init` and the sheet never has a state where it exists without
    /// one. Re-creating a model underneath an in-flight pairing would lose the
    /// result of a swap that has already happened on the host.
    public init(store: PeerStore) {
        _model = State(wrappedValue: PairingModel(store: store))
    }

    public var body: some View {
        NavigationStack {
            PairingPhaseView(model: model)
                .navigationTitle("Pair a host")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: dismiss.callAsFunction)
                    }
                }
        }
    }
}
