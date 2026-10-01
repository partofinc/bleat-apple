#if canImport(UIKit) && !os(watchOS)
import SwiftUI

/// The camera preview, or the reason there isn't one.
struct CameraSection: View {
    /// nil while the permission prompt has not been answered yet.
    let authorised: Bool?
    let model: PairingModel

    var body: some View {
        switch authorised {
        case nil:
            ProgressView()
                .frame(maxWidth: .infinity)
        case false?:
            // Actionable rather than merely regretful: the only way back from a
            // refused camera is Settings, and the user should not have to know
            // that.
            ContentUnavailableView {
                // `camera.slash` does not exist in the system symbol set —
                // UIKit logs "No symbol named" and draws nothing, so the label
                // came up iconless on the one screen that has to explain
                // itself. `video.slash` is the shipping name for this.
                Label("No camera access", systemImage: "video.slash")
            } description: {
                Text("Bleat needs the camera to read a pairing code. You can still paste the link below.")
            } actions: {
                if let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: settings)
                }
            }
        case true?:
            QRScannerView { code in
                guard model.shouldAttempt(code) else { return }
                Task { await model.scanned(code) }
            }
            // A square keeps the preview honest about what it is capturing and
            // adapts to any width, where a fixed height would not.
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityLabel("Camera viewfinder")
            .accessibilityHint("Point the camera at the pairing code shown by bleat pair.")
        }
    }
}

#if DEBUG
/// The two states that do not need a camera. `true` is left out deliberately:
/// it would mount a capture session, which a canvas has nothing to give.
#Preview("Refused", traits: .sampleData) {
    Form {
        Section {
            CameraSection(authorised: false, model: PairingModel(previewing: .waiting))
        }
    }
}

#Preview("Not yet asked", traits: .sampleData) {
    Form {
        Section {
            CameraSection(authorised: nil, model: PairingModel(previewing: .waiting))
        }
    }
}
#endif
#endif
