import SwiftUI

/// Whichever of the sheet's four states is current.
struct PairingPhaseView: View {
    let model: PairingModel

    var body: some View {
        switch model.phase {
        case .waiting:
            PairingCaptureView(model: model)
        case .pairing(let label):
            // Worth saying what is being waited on rather than showing a bare
            // spinner — and it is not always the host. A first pairing can sit
            // here waiting for iOS's local network alert to be answered.
            ProgressView(label)
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
