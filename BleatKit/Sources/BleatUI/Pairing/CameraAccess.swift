#if canImport(UIKit)
import AVFoundation

/// Whether this app may use the camera.
///
/// Separate from the views so the prompt happens once, deliberately, rather
/// than as a side effect of a body running twice.
enum CameraAccess {
    /// Asks, prompting the user only the first time.
    ///
    /// - Returns: false for every case that is not a working camera —
    ///   refused, restricted by policy, or absent. The view says the same thing
    ///   for all of them, because the remedy is the same: paste the link.
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }
}
#endif
