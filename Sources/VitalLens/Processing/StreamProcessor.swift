import Foundation
import AVFoundation
import UIKit

actor StreamProcessor {
    
    // MARK: - Dependencies
    private let camera: CameraSource
    private let detector: FaceDetector
    private let processor: ImageProcessor
    private let client: APIClient
    private let bufferManager: BufferManager
    
    // MARK: - Configuration
    private var config: ModelConfig?
    private let detectionInterval: TimeInterval = 1
    
    // MARK: - State
    private var lastFaceRect: CGRect?
    private var lastDetectionTime: Date = .distantPast
    private var isSending: Bool = false
    
    // Output
    private var outputContinuation: AsyncStream<VitalLensResult>.Continuation?
    
    // MARK: - Initialization
    
    init(apiKey: String?, proxyURL: URL?) {
        self.camera = CameraSource()
        self.detector = FaceDetector()
        self.processor = ImageProcessor()
        self.client = APIClient(apiKey: apiKey, proxyURL: proxyURL)
        self.bufferManager = BufferManager()
    }
    
    // MARK: - Public API
    
    func start(preview: UIView?) async throws -> AsyncStream<VitalLensResult> {
        // 1. Resolve Config
        let resolution = try await client.resolveModel(requestedModel: nil)
        self.config = resolution.config
        
        // 2. Setup Preview (Main Thread required for UI)
        if let view = preview {
            await MainActor.run {
                camera.showPreview(on: view)
            }
        }
        
        // 3. Start Camera
        try await camera.start()
        
        // 4. Output Stream
        return AsyncStream { continuation in
            self.outputContinuation = continuation
            Task { await self.processStream() }
        }
    }
    
    func stop() {
        camera.stop()
        outputContinuation?.finish()
        outputContinuation = nil
        Task { await bufferManager.reset() }
        isSending = false
    }
    
    // MARK: - Processing Loop
    
    private func processStream() async {
        guard let config = self.config else { return }
        
        for await buffer in camera.stream {
            let now = Date()
            
            // 1. Run Face Detection (Periodic)
            if now.timeIntervalSince(lastDetectionTime) > detectionInterval {
                if let rect = try? await detector.detectFace(in: buffer) {
                    self.lastFaceRect = rect
                    self.lastDetectionTime = now
                }
            }
            
            // 2. Buffer Management
            let activeROIs = await bufferManager.updateAndGetActiveROIs(
                faceRect: lastFaceRect,
                config: config
            )
            
            if activeROIs.isEmpty { continue }
            
            // 3. Process Frame
            for item in activeROIs {
                if let rawBytes = try? processor.process(
                    pixelBuffer: buffer,
                    roi: item.roi,
                    targetSize: config.inputSize
                ) {
                    await bufferManager.append(bufferId: item.id, data: rawBytes)
                }
            }
            
            // 4. Trigger Network Loop
            if !isSending {
                // TODO: is this blocking
                await checkAndSend()
            }
        }
    }
    
    private func checkAndSend() async {
        guard let config = self.config else { return }
        
        // 1. Get the best ready buffer
        guard let buffer = await bufferManager.getReadyBuffer() else {
            return
        }
        
        // 2. Consume Data
        guard let payload = await buffer.consume() else { return }
        
        self.isSending = true
        
        // 3. Get State
        let state = await bufferManager.getState()
        
        do {
            // 4. Send
            let result = try await client.sendStreamBatch(
                rawRGBBytes: payload,
                state: state,
                model: nil
            )
            
            // 5. Update State
            if let stateData = result.state?.data,
               let decodedData = Data(base64Encoded: stateData) {
                let newState = decodedData.withUnsafeBytes {
                    Array($0.bindMemory(to: Float.self))
                }
                await bufferManager.updateState(newState)
            }
            
            outputContinuation?.yield(result)
            
        } catch {
            print("VitalLens Stream Error: \(error)")
        }
        
        self.isSending = false
        
        // Check immediately if we have more data ready
        // TODO: What is the purpose of this
        await checkAndSend()
    }
}