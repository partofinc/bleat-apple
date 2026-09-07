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
    public init(store: PeerStore, code: String? = nil) {
        _model = State(wrappedValue: PairingModel(store: store, code: code))
    }

    public var body: some View {
        NavigationStack {
            PairingPhaseView(model: model)
                // A link the app was opened with starts pairing straight away:
                // the user already aimed their camera at the code once, and
                // asking them to press a button in a sheet that is holding that
                // exact code would be asking twice.
                .task { await model.redeemIncomingCode() }
                // Disabling the button is only half of it: a sheet can also be
                // swiped away, and that would abandon the swap just as
                // silently.
                .interactiveDismissDisabled(model.phase == .pairing)
                .navigationTitle("Pair a host")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: dismiss.callAsFunction)
                            // Dismissing mid-swap leaves the pairing running
                            // with nobody watching, and the two outcomes that
                            // matter most would be lost silently: a host key
                            // that does not match the code — the one thing the
                            // out-of-band pin exists to catch — and a peer the
                            // host accepted but this device could not record.
                            // The wait is bounded by the connection attempt.
                            .disabled(model.phase == .pairing)
                    }
                }
        }
    }
}
