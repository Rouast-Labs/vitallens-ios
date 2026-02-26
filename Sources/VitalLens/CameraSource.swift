import Foundation
import AVFoundation
import VitalLensInference
import CoreVideo

#if canImport(UIKit)
import UIKit

/// A camera source that captures video frames using AVFoundation and provides an async stream of `InputFrame` objects.
class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, CameraStreaming, @unchecked Sendable {
    
    private let queue = DispatchQueue(label: "com.vitallens.camera", qos: .userInitiated)
    
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    private var simulatorTask: Task<Void, Never>?
    
    /// The asynchronous stream of captured video frames and metadata.
    public let stream: AsyncStream<InputFrame>
    private var continuation: AsyncStream<InputFrame>.Continuation?

    private let orientationLock = NSLock()
    private var _latestOrientation: UIDeviceOrientation = .portrait
    private var latestOrientation: UIDeviceOrientation {
        get { orientationLock.withLock { _latestOrientation } }
        set { orientationLock.withLock { _latestOrientation = newValue } }
    }
    
    override init() {
        let (s, c) = AsyncStream.makeStream(of: InputFrame.self)
        self.stream = s
        self.continuation = c
        super.init()
        
        Task { @MainActor in
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            self.latestOrientation = UIDevice.current.orientation
            NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.latestOrientation = UIDevice.current.orientation
                }
            }
        }
    }
    
    /// Configures and starts the camera session. Requests camera permissions if not already granted.
    ///
    /// - Throws: `VitalLensError` if camera access is denied, restricted, or configuration fails.
    func start() async throws {
        
        #if targetEnvironment(simulator)
        print("[CameraSource] Running on Simulator. Starting synthetic stream.")
        startSimulatorStream()
        return
        #else
        
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw VitalLensError.processingError("Camera access denied") }
        default:
            throw VitalLensError.processingError("Camera access restricted")
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else { return }
                do {
                    if self.session.inputs.isEmpty {
                        try self.configureSession()
                    }
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        #endif
    }
    
    /// Stops the active camera session and terminates the frame stream.
    func stop() {
        #if targetEnvironment(simulator)
        simulatorTask?.cancel()
        simulatorTask = nil
        #endif
        
        queue.async { [weak self] in
            if self?.session.isRunning == true {
                self?.session.stopRunning()
            }
            self?.continuation?.finish()
            self?.continuation = nil
        }
    }

    /// Attaches the live camera preview to the provided view.
    ///
    /// - Parameter view: The `UIView` to which the camera preview layer will be added.
    @MainActor
    func showPreview(on view: UIView) {
        #if targetEnvironment(simulator)
        view.backgroundColor = .darkGray
        #else
        if previewLayer == nil {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            self.previewLayer = layer
        } else {
            self.previewLayer?.frame = view.bounds
            if let layer = self.previewLayer, layer.superlayer != view.layer {
                layer.removeFromSuperlayer()
                view.layer.insertSublayer(layer, at: 0)
            }
        }
        #endif
    }
    
    // MARK: - Session Configuration
    
    /// Configures the capture session inputs, outputs, and pixel formats.
    ///
    /// - Throws: `VitalLensError` if a suitable camera or output cannot be added.
    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        session.sessionPreset = .high
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw VitalLensError.processingError("No front camera found")
        }
        
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw VitalLensError.processingError("Could not add camera input")
        }
        session.addInput(input)
        
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            output.setSampleBufferDelegate(self, queue: queue)
        } else {
            throw VitalLensError.processingError("Could not add video output")
        }
        
        if let connection = output.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }
    
    // MARK: - Frame Capture
    
    /// Dynamically determines the current device orientation to map sideways faces back to upright
    private var currentDeviceOrientation: CGImagePropertyOrientation {
        switch latestOrientation {
        case .landscapeLeft:
            return .right
        case .landscapeRight:
            return .left
        case .portraitUpsideDown:
            return .down
        case .portrait, .faceUp, .faceDown, .unknown:
            fallthrough
        @unknown default:
            return .up
        }
    }
    
    /// Processes captured sample buffers and yields them to the async stream.
    ///
    /// - Parameters:
    ///   - output: The capture output.
    ///   - sampleBuffer: The captured video frame.
    ///   - connection: The connection from which the video was received.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let frame = InputFrame(
            buffer: SendablePixelBuffer(pixelBuffer),
            orientation: currentDeviceOrientation,
            isMirrored: true,
            timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        )
        
        continuation?.yield(frame)
    }
    
    // MARK: - Simulator Support
    
    #if targetEnvironment(simulator)
    private func startSimulatorStream() {
        guard simulatorTask == nil else { return }
        
        simulatorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_333_333)
                
                if let buffer = createSimulatorBuffer() {
                    let frame = InputFrame(
                        buffer: SendablePixelBuffer(buffer),
                        orientation: .up,
                        isMirrored: true,
                        timestamp: Date().timeIntervalSince1970
                    )
                    continuation?.yield(frame)
                }
            }
        }
    }
    
    private func createSimulatorBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let width = 480
        let height = 640
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<height {
                memset(baseAddress.advanced(by: y * bytesPerRow), 128, width * 4)
            }
        }
        return pixelBuffer
    }
    #endif
}
#endif
