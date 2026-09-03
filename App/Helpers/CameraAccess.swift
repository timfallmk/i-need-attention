import AVFoundation

/// Whether the QR scanner can run, as four states rather than a Bool.
///
/// The distinction that matters is `denied` versus `unavailable`: one is recoverable by
/// the user in Settings and the other is not, and offering an Open Settings button for a
/// simulator with no camera is worse than offering nothing. `ScannerViewController` used
/// to collapse all of this into a bare `return`, which rendered as a black rectangle —
/// the symptom SETUP.md records as "Pairing QR scan does nothing".
enum CameraAccess {
    enum Status: Equatable {
        /// Ready to scan.
        case authorized
        /// The user turned the camera off, or a device policy did. Settings can undo it.
        case denied
        /// There is no camera to ask about, or the capture session refused to configure.
        /// Nothing the user can do here; the paste-a-link path is the way through.
        case unavailable
    }

    /// Resolves to a terminal state, prompting if iOS hasn't asked yet.
    ///
    /// The prompt belongs here rather than in `AVCaptureSession.startRunning`, which
    /// triggers one implicitly and then hands back a session that quietly produces no
    /// frames if the answer was no. Asking first means the answer is a value we can
    /// render.
    static func resolve() async -> Status {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        case .denied, .restricted:
            return .denied
        @unknown default:
            // A status this build doesn't know about is not a reason to claim the camera
            // works. Unavailable degrades to the fallback; authorized degrades to a black
            // rectangle.
            return .unavailable
        }
    }
}
