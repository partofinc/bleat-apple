#if canImport(UIKit)
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
                Label("No camera access", systemImage: "camera.slash")
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
#endif
