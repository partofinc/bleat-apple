#if canImport(UIKit)
import AVFoundation
import UIKit

/// Hosts the capture session and its preview layer.
///
/// A view controller rather than a bare `UIView` because the two things that go
/// wrong with camera previews are lifecycle and layout: the session must stop
/// when the sheet goes away — it holds the camera, and iOS will not hand it to
/// anything else meanwhile — and the preview layer has to be resized by hand,
/// since it is a `CALayer` and takes no part in Auto Layout.
///
/// SwiftUI has no native camera preview on iOS 18, so this is UIKit by
/// necessity rather than preference.
final class QRScannerController: UIViewController {
    /// Called once per distinct code. The scanner keeps running: a scan that
    /// turns out not to be a Bleat code should not require reopening the sheet.
    var onCode: ((String) -> Void)?

    /// Configured and started on `sessionQueue`, never on the main actor.
    /// `startRunning()` blocks — Apple's own documentation says so — and
    /// blocking here means the sheet animates in frozen.
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "team.partof.bleat.scanner")
    private var preview: AVCaptureVideoPreviewLayer?
    /// The last code handed up, so holding the camera on one QR does not fire
    /// the callback sixty times a second.
    private var lastCode: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    /// Builds the session on its own queue.
    ///
    /// Failure is silent by design: the view above this one decides what to say
    /// when no camera appears, and it can already say it for the case that
    /// actually happens — permission refused. A simulator, or a device whose
    /// camera another app holds, lands in the same place.
    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        let output = AVCaptureMetadataOutput()
        // Set here rather than on the session queue: the conformance below is
        // main-actor isolated, and handing it to a nonisolated context is not
        // allowed. Callbacks are asked for on the main queue anyway, which is
        // what keeps `lastCode` and `onCode` alongside the view's own state.
        output.setMetadataObjectsDelegate(self, queue: .main)

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer

        sessionQueue.async { [session] in
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            // `availableMetadataObjectTypes` is empty until the output has
            // joined a session, so asking for `.qr` any earlier silently
            // matches nothing — the camera runs and no code is ever seen.
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

extension QRScannerController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue,
              value != lastCode
        else { return }
        lastCode = value
        onCode?(value)
    }
}
#endif
