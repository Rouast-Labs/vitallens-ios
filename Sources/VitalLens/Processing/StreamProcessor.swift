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
    private let vitalsEstimator: VitalsEstimateManager
    
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
        self.vitalsEstimator = VitalsEstimateManager()
    }
    
    // MARK: - Public API
    
    func start(preview: UIView?) async throws -> AsyncStream<VitalLensResult> {
        // 1. Resolve Config
        let resolution = try await client.resolveModel(requestedModel: nil)
        self.config = resolution.config
        
        // 2. Setup Preview
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
        
        // Reset stateful components
        Task {
            await bufferManager.reset()
            await vitalsEstimator.reset() 
        }
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
            // 4. Send to Cloud
            let rawResult = try await client.sendStreamBatch(
                rawRGBBytes: payload,
                state: state,
                model: nil
            )
            
            // 5. Update State
            if let stateData = rawResult.state?.data,
               let decodedData = Data(base64Encoded: stateData) {
                let newState = decodedData.withUnsafeBytes {
                    Array($0.bindMemory(to: Float.self))
                }
                await bufferManager.updateState(newState)
            }
            
            // 6. Estimate Vitals
            let refinedResult = await vitalsEstimator.process(chunk: rawResult, config: config)
            
            // 7. Yield Refined Result
            outputContinuation?.yield(refinedResult)
            
        } catch {
            print("VitalLens Stream Error: \(error)")
        }
        
        self.isSending = false
        
        // Check immediately if we have more data ready
        // TODO: What is the purpose of this
        await checkAndSend()
    }
}