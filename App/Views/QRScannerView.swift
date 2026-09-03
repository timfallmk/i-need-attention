import AVFoundation
import SwiftUI
import UIKit

/// Lightweight AVFoundation-based QR scanner. Only fires `onCode` once per mount —
/// the parent dismisses or transitions to a new state immediately so no debouncing needed.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    /// Called when the capture session can't be built at all. The parent has already
    /// checked `CameraAccess`, so reaching this means something further down refused —
    /// a camera in use by another app, a session iOS declined to configure. Either way
    /// the alternative is a black rectangle, so it is reported rather than swallowed.
    var onUnavailable: () -> Void = {}
    /// Bumping this from the parent re-arms the scanner so it'll fire `onCode` again.
    var resetToken: Int = 0

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCode = onCode
        vc.onUnavailable = onUnavailable
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
        uiViewController.onCode = onCode
        uiViewController.onUnavailable = onUnavailable
        if uiViewController.resetToken != resetToken {
            uiViewController.resetToken = resetToken
            uiViewController.rearm()
        }
    }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onUnavailable: (() -> Void)?
    var resetToken: Int = 0
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var didFire = false
    private var isConfigured = false

    func rearm() {
        didFire = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        isConfigured = configure()
        if !isConfigured {
            // After the view is in the hierarchy, so the parent's state change lands in
            // a normal SwiftUI update rather than during `makeUIViewController`.
            DispatchQueue.main.async { [weak self] in self?.onUnavailable?() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isConfigured, !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        self.preview = layer
        return true
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didFire,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        didFire = true
        Haptics.success()
        onCode?(value)
    }
}
