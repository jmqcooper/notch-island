import AVFoundation
import SwiftUI

/// Front camera preview. Only runs while the Mirror tab is visible, so the camera light
/// is on exactly when you can see yourself.
final class CameraMirror: ObservableObject {
    let session = AVCaptureSession()
    @Published private(set) var denied = false
    private let queue = DispatchQueue(label: "NotchIsland.camera")
    private var configured = false

    @MainActor
    func start() {
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                Log.write("camera access denied")
                denied = true
                return
            }
            denied = false
            queue.async { [self] in
                configureIfNeeded()
                if !session.isRunning { session.startRunning() }
                Log.write("camera running: \(session.isRunning)")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            Log.write("camera running: \(session.isRunning)")
        }
    }

    private func configureIfNeeded() {
        guard !configured,
              let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        configured = true
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        // Mirror it, like a real mirror.
        layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
