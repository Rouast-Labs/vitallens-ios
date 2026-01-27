import Foundation
import AVFoundation

/// A wrapper around AVCaptureSession that exposes a video stream as an AsyncStream.
class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    
    // MARK: - Properties
    
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.vitallens.camera", qos: .userInitiated)
    
    /// The stream of video frames.
    /// Buffering policy: Unbounded (but AVFoundation drops late frames automatically).
    var stream: AsyncStream<CMSampleBuffer> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    
    private var continuation: AsyncStream<CMSampleBuffer>.Continuation?
    
    // MARK: - Initialization
    
    override init() {
        super.init()
    }
    
    // MARK: - Public API
    
    /// Configures and starts the camera session.
    ///
    /// - Throws: `VitalLensError` if camera access is denied or setup fails.
    func start() async throws {
        // Check Permissions
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw VitalLensError.processingError("Camera access denied") }
        default:
            throw VitalLensError.processingError("Camera access restricted")
        }
        
        // Configure Session on background queue
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else { return }
                do {
                    try self.configureSession()
                    self.session.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Stops the camera session.
    func stop() {
        queue.async { [weak self] in
            self?.session.stopRunning()
            self?.continuation?.finish()
            self?.continuation = nil
        }
    }
    
    // MARK: - Private Configuration
    
    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        session.sessionPreset = .high
        
        // 1. Input: Front Camera
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw VitalLensError.processingError("No front camera found")
        }
        
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw VitalLensError.processingError("Could not add camera input")
        }
        session.addInput(input)
        
        // 2. Output: Video Data
        if session.canAddOutput(output) {
            session.addOutput(output)
            // Discard late frames to prevent latency buildup
            output.alwaysDiscardsLateVideoFrames = true
            // VitalLens uses RGB; '32BGRA' is standard for efficient mapping
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            output.setSampleBufferDelegate(self, queue: queue)
        } else {
            throw VitalLensError.processingError("Could not add video output")
        }
        
        // 3. Orientation & Mirroring
        if let connection = output.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }
    }
    
    // MARK: - Delegate
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Forward the frame to the AsyncStream
        continuation?.yield(sampleBuffer)
    }
}