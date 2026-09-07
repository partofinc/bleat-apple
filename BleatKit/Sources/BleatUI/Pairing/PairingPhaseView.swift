import SwiftUI

/// Whichever of the sheet's four states is current.
struct PairingPhaseView: View {
    let model: PairingModel

    var body: some View {
        switch model.phase {
        case .waiting:
            PairingCaptureView(model: model)
        case .pairing:
            // The host is being reached, a key installed and proven, and
            // another deleted. It is worth saying that it involves the host
            // rather than showing a bare spinner.
            ProgressView("Reaching the host…")
                .controlSize(.large)
        case .awaitingPermission:
            // A different wait, and saying so matters: the user has an alert in
            // front of them and nothing here explains why the app is stalled.
            // Dismissable, unlike `pairing` — nothing is in flight.
            ProgressView("Waiting for permission to reach your local network…")
                .controlSize(.large)
                .multilineTextAlignment(.center)
        case .paired(let peer):
            PairedResultView(peer: peer)
        case .failed(let message):
            ContentUnavailableView {
                Label("Pairing failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again", action: model.retry)
            }
        }
    }
}
