#if canImport(UIKit)
import AVFoundation
import UIKit

/// Shows the camera and reports the codes it reads.
///
/// A view controller rather than a bare `UIView` because the two things that go
/// wrong with camera previews are lifecycle and layout: the session must stop
/// when the view goes away — it holds the camera, and iOS will not hand it to
/// anything else meanwhile — and **start again when the view comes back**,
/// since SwiftUI recycles the rows a representable lives in. The preview layer
/// also has to be resized by hand, being a `CALayer` that takes no part in Auto
/// Layout.
///
/// SwiftUI has no native camera preview on iOS 18, so this is UIKit by
/// necessity rather than preference.
final class QRScannerController: UIViewController {
    /// Called once per distinct code, on the main actor.
    var onCode: ((String) -> Void)?

    private let scanner = ScannerSession()
    /// The last code handed up, so holding the camera on one QR does not fire
    /// the callback sixty times a second.
    private var lastCode: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.addSublayer(scanner.previewLayer)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Starting here rather than once in `viewDidLoad` is what makes the
        // preview survive being detached and re-attached. Started once, a
        // recycled row came back permanently black — and the view above has no
        // state for "camera stopped", so it would show a viewfinder that could
        // never fire.
        scanner.start(delegate: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scanner.previewLayer.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scanner.stop()
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
