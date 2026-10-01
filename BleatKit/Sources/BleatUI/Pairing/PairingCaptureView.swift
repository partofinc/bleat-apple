import Foundation
import SwiftUI

/// How a code gets in: the camera, or a pasted link.
///
/// Both exist deliberately. `bleat pair` falls back to printing the link when
/// the terminal is too small for a QR or is not a terminal at all, and that
/// link has to be usable — otherwise the fallback pairs nothing.
struct PairingCaptureView: View {
    /// `@Bindable` for the text field: the model owns the typed link, so the
    /// field writes straight to it rather than to a local copy the submit
    /// button would then have to reconcile.
    @Bindable var model: PairingModel
    /// nil until asked. Requesting camera access shows a system prompt, so it
    /// happens once, in `task`, rather than as a side effect of `body`.
    @State private var cameraAuthorised: Bool?
    #if DEBUG
    /// Preview-only: answer for the camera instead of asking it.
    ///
    /// **A canvas does not fail to get a camera.** `CameraAccess.request()`
    /// returns true outright whenever access is already granted, which is the
    /// normal state on any device or simulator that has been through pairing
    /// once — so a preview would take the `true` branch and mount a live
    /// `AVCaptureSession`, the exact thing `QRScannerView` says a preview must
    /// not do. On a fresh install it raises the permission alert instead.
    var previewCamera: Bool?
    #endif

    var body: some View {
        Form {
            #if canImport(UIKit) && !os(watchOS)
            Section {
                CameraSection(authorised: cameraAuthorised, model: model)
            } header: {
                Text("Scan")
            } footer: {
                Text("Run `bleat pair` on the host and point the camera at the code it shows.")
            }
            #endif

            Section {
                // Vertical axis so a long link wraps instead of scrolling
                // sideways through a single line.
                TextField("bleat://pair?d=…", text: $model.typedCode, axis: .vertical)
                    .lineLimit(2...5)
                    .font(.footnote.monospaced())
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
                Button("Pair with this link") {
                    Task { await model.submitTypedCode() }
                }
                .disabled(model.typedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Or paste the link")
            } footer: {
                Text("`bleat pair` prints a link when the window is too small for a code.")
            }
        }
        .task {
            #if canImport(UIKit) && !os(watchOS)
            #if DEBUG
            if let previewCamera {
                cameraAuthorised = previewCamera
                return
            }
            #endif
            cameraAuthorised = await CameraAccess.request()
            #endif
        }
    }
}

#if DEBUG
/// Both ways in, with the camera answered rather than asked — see
/// `previewCamera`. `false` is the honest state to lay out: it is the one a
/// canvas can show without turning a camera on, and it keeps the pasted-link
/// half on screen, which is the fallback `bleat pair` prints when the window is
/// too small for a code.
#Preview("No camera", traits: .sampleData) {
    NavigationStack {
        PairingCaptureView(model: PairingModel(previewing: .waiting), previewCamera: false)
    }
}

/// Before the permission has been answered.
#Preview("Asking", traits: .sampleData) {
    NavigationStack {
        PairingCaptureView(model: PairingModel(previewing: .waiting), previewCamera: nil)
    }
}
#endif
