import SwiftUI
import AVFoundation
import Combine

/// A view model responsible for camera configuration and face tracking.
///
/// This type owns the full AVCapture-based face tracking pipeline:
/// - camera session creation
/// - front camera input selection
/// - metadata-based face detection
/// - publishing face bounds for UI overlay rendering
/// - publishing control signals for robot motion
///
/// Design note:
/// This type does not send BLE commands directly.
/// It only produces tracking output. Command orchestration belongs elsewhere.
@MainActor
final class FaceTrackerViewModel: NSObject, ObservableObject {
    /// A high-level status string for the user interface.
    @Published var status: String = "Starting camera..."

    /// A human-readable control decision string.
    @Published var commandText: String = "Idle"

    /// Indicates whether a target face is currently detected.
    @Published var hasTarget: Bool = false

    /// Horizontal turn signal in the approximate range `-1 ... 1`.
    ///
    /// Interpretation:
    /// - negative: face is to the left
    /// - positive: face is to the right
    @Published var turnSignal: Double = 0

    /// A forward/backward drive signal reserved for future use.
    ///
    /// The current single-motor version does not actively use this value
    /// for navigation, but it is still computed for diagnostics and future expansion.
    @Published var driveSignal: Double = 0

    /// The latest detected face bounds in metadata coordinate space.
    ///
    /// This rectangle is normalized and must be converted through the preview layer
    /// before being displayed on screen.
    @Published var detectedFaceBounds: CGRect?
    
    // Motor kontrol durumu - ContentView tarafından kullanılır
    var stopTask: Task<Void, Never>? = nil
    
    var lastTurnDirection: Double = 0
    
    var lastMoveTime: Date = .distantPast

    /// The shared camera capture session.
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let metadataQueue = DispatchQueue(label: "camera.metadata.queue")
    private let metadataOutput = AVCaptureMetadataOutput()

    private var didConfigureSession = false
    private var lastCommandTime = Date.distantPast
    private var lastFaceLogTime = Date.distantPast
    private var lastNoFaceLogTime = Date.distantPast

    /// Starts camera access and begins the capture session.
    ///
    /// Steps:
    /// 1. Request camera permission
    /// 2. Configure the session once
    /// 3. Start the session on a background queue
    func start() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
            status = "Camera permission denied"
            print("[FaceTracker] Camera permission denied")
            return
        }

        print("[FaceTracker] start() called")
        configureSessionIfNeeded()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning {
                print("[FaceTracker] session.startRunning()")
                self.session.startRunning()
            } else {
                print("[FaceTracker] session already running")
            }
        }

        status = "Searching for first face..."
    }

    /// Configures the `AVCaptureSession` a single time.
    ///
    /// This method:
    /// - attaches the front camera input
    /// - attaches metadata output
    /// - enables face metadata detection
    /// - applies mirroring when supported
    private func configureSessionIfNeeded() {
        guard !didConfigureSession else {
            print("[FaceTracker] configureSessionIfNeeded skipped")
            return
        }

        didConfigureSession = true
        print("[FaceTracker] configuring session...")

        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            status = "Front camera not found"
            print("[FaceTracker] Front camera not found")
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                print("[FaceTracker] front camera input added")
            } else {
                status = "Cannot add camera input"
                print("[FaceTracker] Cannot add camera input")
                session.commitConfiguration()
                return
            }
        } catch {
            status = "Camera input error: \(error.localizedDescription)"
            print("[FaceTracker] Camera input error:", error.localizedDescription)
            session.commitConfiguration()
            return
        }

        guard session.canAddOutput(metadataOutput) else {
            status = "Cannot add metadata output"
            print("[FaceTracker] Cannot add metadata output")
            session.commitConfiguration()
            return
        }

        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
        metadataOutput.rectOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)

        let available = metadataOutput.availableMetadataObjectTypes
        print("[FaceTracker] available metadata types:", available.map(\.rawValue))

        if available.contains(.face) {
            metadataOutput.metadataObjectTypes = [.face]
            print("[FaceTracker] metadata type set to .face")
        } else {
            status = "Face metadata not supported"
            print("[FaceTracker] Face metadata not supported")
        }

        // ── NEW: set orientation + mirroring on the metadata connection ──
        if let connection = metadataOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .landscapeRight
                print("[FaceTracker] metadata connection orientation set to landscapeRight")
            } else {
                print("[FaceTracker] metadata orientation not supported")
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
                print("[FaceTracker] metadata connection mirrored")
            } else {
                print("[FaceTracker] metadata mirroring not supported")
            }
        } else {
            print("[FaceTracker] metadata connection is nil")
        }
        // ────────────────────────────────────────────────────────────────

        session.commitConfiguration()
        print("[FaceTracker] session configuration committed")
    }

    /// Updates the published state when a face is detected.
    ///
    /// - Parameter rect: The normalized metadata-space rectangle for the detected face.
    private func handleDetectedFace(_ rect: CGRect) {
        // Ekran dışı veya anlamsız koordinatları reddet
        guard rect.midX > 0.05 && rect.midX < 0.95,
              rect.midY > 0.05 && rect.midY < 0.95,
              rect.width > 0.02 && rect.width < 0.8 else {
            logNoFace()
            handleNoFace()
            return
        }

        hasTarget = true
        detectedFaceBounds = rect
        status = "Tracking face"
        updateSignals(from: rect)
    }

    /// Resets the tracking-related state when no face is present.
    private func handleNoFace() {
        hasTarget = false
        detectedFaceBounds = nil
        turnSignal = 0
        driveSignal = 0
        commandText = "Idle"
        status = "Searching for first face..."
    }

    /// Computes motor control signals from the detected face rectangle.
    ///
    /// Logic:
    /// - `midX` controls horizontal turning
    /// - `width` provides a rough apparent-size estimate for distance
    ///
    /// - Parameter rect: The detected face rectangle in normalized metadata space.
    private func updateSignals(from rect: CGRect) {
        let centerX = rect.midX
        let width = rect.width

        let horizontalError = centerX - 0.5
        let rawTurn = horizontalError * 0.6  // 1.2'den 0.6'ya
        turnSignal = max(-1, min(1, rawTurn))

        let targetFaceWidth: CGFloat = 0.22
        let sizeError = targetFaceWidth - width
        let rawDrive = sizeError * 5.0
        driveSignal = max(-1, min(1, rawDrive))

        commandText = makeCommandText(turn: turnSignal, drive: driveSignal)
        throttleCommandOutput()
    }

    /// Builds a human-readable text summary of the current control signals.
    ///
    /// - Parameters:
    ///   - turn: The horizontal turn signal.
    ///   - drive: The forward/backward drive signal.
    /// - Returns: A textual summary for debugging and UI display.
    private func makeCommandText(turn: Double, drive: Double) -> String {
        let turnText: String
        if turn > 0.15 {
            turnText = "Turn right"
        } else if turn < -0.15 {
            turnText = "Turn left"
        } else {
            turnText = "Centered"
        }

        let driveText: String
        if drive > 0.15 {
            driveText = "Forward"
        } else if drive < -0.15 {
            driveText = "Back"
        } else {
            driveText = "Hold"
        }

        return "\(driveText) | \(turnText)"
    }

    /// Reduces log spam by rate-limiting printed motor signal output.
    private func throttleCommandOutput() {
        let now = Date()
        guard now.timeIntervalSince(lastCommandTime) > 0.15 else { return }
        lastCommandTime = now

        let leftMotor = max(-1, min(1, driveSignal - turnSignal))
        let rightMotor = max(-1, min(1, driveSignal + turnSignal))
        print("left=\(String(format: "%.2f", leftMotor)) right=\(String(format: "%.2f", rightMotor)) turn=\(String(format: "%.2f", turnSignal))")
    }

    /// Logs a detected face rectangle at a limited frequency.
    ///
    /// - Parameter bounds: The normalized face rectangle.
    private func logFace(_ bounds: CGRect) {
        let now = Date()
        guard now.timeIntervalSince(lastFaceLogTime) > 0.5 else { return }
        lastFaceLogTime = now
        print("[FaceTracker] Face detected:", bounds)
    }

    /// Logs a no-face state at a limited frequency.
    private func logNoFace() {
        let now = Date()
        guard now.timeIntervalSince(lastNoFaceLogTime) > 1.0 else { return }
        lastNoFaceLogTime = now
        print("[FaceTracker] No face detected")
    }
}

extension FaceTrackerViewModel: AVCaptureMetadataOutputObjectsDelegate {
    /// Receives metadata detection callbacks from AVCapture.
    ///
    /// Important implementation detail:
    /// The `AVMetadataObject` itself is not moved into the main actor.
    /// Instead, only the extracted `CGRect` is forwarded into main-actor state updates.
    ///
    /// - Parameters:
    ///   - output: The metadata output instance.
    ///   - metadataObjects: The detected metadata objects.
    ///   - connection: The capture connection associated with the callback.
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let faceBounds = metadataObjects.first?.bounds

        Task { @MainActor [weak self] in
            guard let self else { return }

            guard let faceBounds else {
                self.logNoFace()
                self.handleNoFace()
                return
            }

            self.logFace(faceBounds)
            self.handleDetectedFace(faceBounds)
        }
    }
}

/// A SwiftUI wrapper around the UIKit-based preview view.
struct CameraPreviewView: UIViewRepresentable {
    /// The camera session to render.
    let session: AVCaptureSession

    /// The latest normalized face rectangle to visualize.
    let detectedFaceBounds: CGRect?

    /// Creates the preview view.
    ///
    /// - Parameter context: The representable context.
    /// - Returns: A configured `PreviewUIView`.
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.attach(session: session)
        view.updateFaceBox(detectedFaceBounds)
        return view
    }

    /// Updates the preview view whenever SwiftUI state changes.
    ///
    /// - Parameters:
    ///   - uiView: The existing preview view.
    ///   - context: The representable context.
    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.attach(session: session)
        uiView.updateFaceBox(detectedFaceBounds)
    }
}

/// A UIKit view backed by `AVCaptureVideoPreviewLayer`.
///
/// This view is responsible for:
/// - showing the camera preview
/// - drawing the green detected face box
/// - drawing a fixed red debug box
final class PreviewUIView: UIView {
    /// The green rectangle used to show the detected face area.
    private let faceView: UIView = {
        let v = UIView()
        v.layer.borderColor = UIColor.green.cgColor
        v.layer.borderWidth = 3
        v.backgroundColor = .clear
        v.isHidden = true
        return v
    }()


    private weak var attachedSession: AVCaptureSession?
    private var lastRectLogTime = Date.distantPast

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    /// Typed access to the backing preview layer.
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    /// Performs one-time view setup.
    private func commonInit() {
        addSubview(faceView)
        clipsToBounds = true
    }

    /// Attaches a capture session to the preview layer.
    ///
    /// This method is safe to call repeatedly.
    /// It also retries mirroring setup because the preview connection
    /// may not exist on the earliest render passes.
    ///
    /// - Parameter session: The camera session to attach.
    func attach(session: AVCaptureSession) {
        if attachedSession !== session {
            attachedSession = session
            videoPreviewLayer.session = session
            videoPreviewLayer.videoGravity = .resizeAspectFill
            print("[PreviewUIView] attached session")
        }

        if let connection = videoPreviewLayer.connection {
            // Set orientation to landscape right (or left — try both if mirrored)
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .landscapeRight
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }

    /// Updates the visible green face rectangle.
    ///
    /// The metadata bounds are normalized and must be converted into view coordinates
    /// through the preview layer using `layerRectConverted(fromMetadataOutputRect:)`.
    ///
    /// - Parameter metadataBounds: The latest normalized metadata rectangle, if any.
    func updateFaceBox(_ metadataBounds: CGRect?) {
        guard let metadataBounds else {
            faceView.isHidden = true
            return
        }

        let converted = videoPreviewLayer.layerRectConverted(fromMetadataOutputRect: metadataBounds)
        let rect = converted.integral

        let now = Date()
        if now.timeIntervalSince(lastRectLogTime) > 0.5 {
            lastRectLogTime = now
            print("[PreviewUIView] converted rect =", rect)
        }

        if rect.isNull || rect.isInfinite || rect.width < 2 || rect.height < 2 {
            faceView.isHidden = true
            return
        }

        faceView.frame = rect
        faceView.isHidden = false

        bringSubviewToFront(faceView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoPreviewLayer.frame = bounds
        bringSubviewToFront(faceView)
    }
}
