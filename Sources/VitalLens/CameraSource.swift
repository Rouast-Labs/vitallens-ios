import Foundation
import AVFoundation
import VitalLensCore
import CoreVideo

#if canImport(UIKit)
import UIKit

class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, CameraStreaming, @unchecked Sendable {
    
    private let queue = DispatchQueue(label: "com.vitallens.camera", qos: .userInitiated)
    
    // Real Camera Properties
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    // Simulator Properties
    private var simulatorTask: Task<Void, Never>?
    
    /// The stream of video frames.
    var stream: AsyncStream<SendablePixelBuffer> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    
    private var continuation: AsyncStream<SendablePixelBuffer>.Continuation?
    
    override init() {
        super.init()
    }
    
    /// Configures and starts the camera session.
    func start() async throws {
        
        // 1. SIMULATOR PATH
        #if targetEnvironment(simulator)
        print("[CameraSource] Running on Simulator. Starting synthetic stream.")
        startSimulatorStream()
        return
        #else
        
        // 2. DEVICE PATH
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
    
    /// Stops the camera session.
    func stop() {
        // Stop Simulator Stream
        #if targetEnvironment(simulator)
        simulatorTask?.cancel()
        simulatorTask = nil
        #endif
        
        // Stop Real Stream
        queue.async { [weak self] in
            if self?.session.isRunning == true {
                self?.session.stopRunning()
            }
            self?.continuation?.finish()
            self?.continuation = nil
        }
    }

    /// Attaches the camera preview to a UIView.
    @MainActor
    func showPreview(on view: UIView) {
        #if targetEnvironment(simulator)
        // On simulator, just show a placeholder color so we know layout is working
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
    
    // MARK: - Device Configuration
    
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
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        continuation?.yield(SendablePixelBuffer(pixelBuffer))
    }
    
    // MARK: - Simulator Fallback
    
    #if targetEnvironment(simulator)
    private func startSimulatorStream() {
        guard simulatorTask == nil else { return }
        
        simulatorTask = Task {
            while !Task.isCancelled {
                // Generate 30 FPS
                try? await Task.sleep(nanoseconds: 33_333_333)
                
                if let buffer = createSimulatorBuffer() {
                    continuation?.yield(SendablePixelBuffer(buffer))
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
        
        // Fill with a moving color to simulate "liveness"
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            // Just fill it with gray for performance
            for y in 0..<height {
                memset(baseAddress.advanced(by: y * bytesPerRow), 128, width * 4)
            }
        }
        return pixelBuffer
    }
    #endif
}
#endif