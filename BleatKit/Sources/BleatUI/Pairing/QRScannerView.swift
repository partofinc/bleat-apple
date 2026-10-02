#if canImport(UIKit) && !os(watchOS)
import SwiftUI

/// The camera preview, as a SwiftUI view.
struct QRScannerView: UIViewControllerRepresentable {
    /// Called for each distinct code the camera reads. Not necessarily a Bleat
    /// code — deciding that is the caller's job, and it is the caller who can
    /// say something useful when it is a Wi-Fi QR instead.
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        // Re-assigned rather than captured once: `onCode` closes over the view's
        // state, and a stale copy would go on calling a model the sheet has
        // already replaced.
        controller.onCode = onCode
    }
}
#endif

// No `#Preview`: this mounts a live `AVCaptureSession`, which a canvas has
// nothing to give — it would render a black rectangle and nothing else. The
// layout around it previews in `CameraSection`, whose `nil` and `false` states
// are the ones a preview can honestly show.
