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

    var body: some View {
        Form {
            #if canImport(UIKit)
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
            #if canImport(UIKit)
            cameraAuthorised = await CameraAccess.request()
            #endif
        }
    }
}
