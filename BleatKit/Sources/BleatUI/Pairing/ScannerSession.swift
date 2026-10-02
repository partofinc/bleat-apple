#if canImport(UIKit) && !os(watchOS)
import AVFoundation

/// The capture session, and everything attached to it.
///
/// It exists so the session can be handed between the main actor and the queue
/// that runs it without any of AVFoundation's classes crossing that line.
/// `AVCaptureSession`, `AVCaptureDeviceInput` and `AVCaptureMetadataOutput` are
/// not `Sendable` and cannot be — they predate the concurrency model — so
/// capturing them in a `@Sendable` closure is a diagnostic every time.
///
/// The fix is not `@preconcurrency import AVFoundation`, which silences the
/// question for the whole file rather than answering it. Instead these objects
/// are **owned here and never handed out**: the closures capture `self`, which
/// is `Sendable`, and the invariant `@unchecked` stands for is that everything
/// touching the session happens on `queue`. That serialisation is what
/// AVFoundation asks for anyway — its own documentation is explicit that
/// session configuration must not be done concurrently.
///
/// `nonisolated` because `BleatUI` is main-actor by default, and a main-actor
/// class whose properties are read from a background queue is the same problem
/// in a different shape.
nonisolated final class ScannerSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "team.partof.bleat.scanner")
    private let session = AVCaptureSession()
    private let output = AVCaptureMetadataOutput()
    /// Guarded by `queue`, like everything else here.
    private var isConfigured = false

    /// The layer to put in a view. Reading it is the one thing that happens on
    /// the main actor, and it is only ever read.
    let previewLayer: AVCaptureVideoPreviewLayer

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
    }

    /// Attaches the camera if it is not attached yet, and starts running.
    ///
    /// Safe to call again — the view calls it on every appearance, which is
    /// what lets a preview come back after the row it lives in was recycled.
    ///
    /// - Parameter delegate: Set here, synchronously, because the conformance
    ///   is main-actor isolated and handing it to `queue` is not allowed.
    func start(delegate: any AVCaptureMetadataOutputObjectsDelegate) {
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        queue.async { [self] in
            configureIfNeeded()
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Stops, releasing the camera. iOS will not hand it to anything else while
    /// a session holds it, so a sheet that goes away must let go.
    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        // Failure is silent by design: the view above decides what to say when
        // no preview appears, and it can already say it for the case that
        // actually happens — permission refused. A simulator, or a device whose
        // camera another app holds, lands in the same place.
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        // `availableMetadataObjectTypes` is empty until the output has joined a
        // session, so asking for `.qr` any earlier silently matches nothing —
        // the camera runs and no code is ever seen.
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
    }
}
#endif
