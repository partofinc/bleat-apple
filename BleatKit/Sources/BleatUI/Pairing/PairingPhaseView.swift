import SwiftUI
#if DEBUG
import BleatKit
#endif

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

#if DEBUG
/// The camera state. In a canvas the capture device is unavailable, so what
/// this actually shows is the refused-camera branch — which is the one worth
/// looking at anyway, since it is the only way back from a denied permission.
#Preview("Waiting", traits: .sampleData) {
    NavigationStack {
        PairingPhaseView(model: PairingModel(previewing: .waiting))
    }
}

#Preview("Pairing", traits: .sampleData) {
    NavigationStack {
        PairingPhaseView(model: PairingModel(previewing: .pairing))
    }
}

/// A different wait, and it says so: the user has an iOS alert in front of them
/// and nothing else on this screen would explain the stall.
#Preview("Awaiting permission", traits: .sampleData) {
    NavigationStack {
        PairingPhaseView(model: PairingModel(previewing: .awaitingPermission))
    }
}

#Preview("Paired", traits: .sampleData) {
    NavigationStack {
        PairingPhaseView(model: PairingModel(previewing: .paired(.preview)))
    }
}

#Preview("Failed", traits: .sampleData) {
    NavigationStack {
        PairingPhaseView(model: PairingModel(previewing: .failed(
            """
            Bleat could not reach your local network. iOS asks for that permission the first \
            time the app connects to a Mac on it. Allow it when iOS asks, or turn it on in \
            Settings › Privacy & Security › Local Network, then pair again.
            """
        )))
    }
}
#endif
