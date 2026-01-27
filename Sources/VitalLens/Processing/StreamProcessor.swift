import Foundation
import AVFoundation
import CoreImage

/// The central coordinator that ties Camera, Face Detection, Image Processing, and Networking together.
actor StreamProcessor {
    
    // MARK: - Dependencies
    private let camera: CameraSource
    private let detector: FaceDetector
    private let processor: ImageProcessor
    private let client: APIClient
    private let bufferManager: BufferManager
    
    // MARK: - Configuration
    private var config: ModelConfig?
    private let detectionInterval: TimeInterval = 0.5 // More frequent detection to catch drift fast
    
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
    
    func start() async throws -> AsyncStream<VitalLensResult> {
        // 1. Resolve Config
        let resolution = try await client.resolveModel(requestedModel: nil)
        self.config = resolution.config
        
        // 2. Start Camera
        try await camera.start()
        
        // 3. Output Stream
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
            // We update 'lastFaceRect' which drives the buffer logic
            if now.timeIntervalSince(lastDetectionTime) > detectionInterval {
                if let rect = try? await detector.detectFace(in: buffer) {
                    self.lastFaceRect = rect
                    self.lastDetectionTime = now
                }
                // If detection fails, we keep the old rect for a bit (smoothing) or let it persist
            }
            
            // 2. Buffer Management: Get Active ROIs
            // We pass the current face rect. BufferManager decides if we need new buffers
            // and returns a list of ALL buffers that need data from this frame.
            let activeROIs = await bufferManager.updateAndGetActiveROIs(
                faceRect: lastFaceRect,
                config: config
            )
            
            // If no buffers are active (no face ever found), skip
            if activeROIs.isEmpty { continue }
            
            // 3. Process Frame for EACH Active Buffer
            // This ensures each buffer gets the frame cropped to ITS specific ROI.
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
    
    // MARK: - Network Loop
    
    private func checkAndSend() async {
        guard let config = self.config else { return }
        
        // 1. Get the best ready buffer
        guard let buffer = await bufferManager.getReadyBuffer() else {
            return
        }
        
        // 2. Consume Data (this keeps the overlap context in the buffer)
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