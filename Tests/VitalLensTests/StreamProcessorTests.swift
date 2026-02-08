import XCTest
import CoreVideo
@testable import VitalLens
@testable import VitalLensCore

// MARK: - Mocks

actor MockStrategy: InferenceStrategy {
    var processCalledCount = 0
    private var shouldFail = false
    
    func setShouldFail(_ value: Bool) {
        self.shouldFail = value
    }
    
    func resolveConfig() async throws -> ModelConfig {
        return ModelConfig(
            nInputs: 4,
            inputSize: 40,
            fpsTarget: 30,
            roiMethod: "upper_body_cropped",
            supportedVitals: ["heart_rate"]
        )
    }
    
    func process(frames: Data, state: [Float]?, meta: [String : String]) async throws -> VitalLensResult {
        if shouldFail {
            throw VitalLensError.serverError(statusCode: 500, message: "Mock Failure")
        }
        processCalledCount += 1
        return VitalLensResult(
            face: FaceData(coordinates: [], confidence: [], note: nil),
            signals: ["heart_rate": TimeSeries(data: [72.0], confidence: [0.9], unit: "bpm", note: "")],
            time: [Date().timeIntervalSince1970]
        )
    }
}

actor MockFaceDetector: FaceDetecting {
    var forcedRect: CGRect?
    
    func detectFace(in pixelBuffer: SendablePixelBuffer) async throws -> CGRect? {
        return forcedRect
    }
    
    func setFace(_ rect: CGRect?) {
        self.forcedRect = rect
    }
}

// MARK: - Tests

final class StreamProcessorTests: XCTestCase {
    
    var strategy: MockStrategy!
    var detector: MockFaceDetector!
    var processor: StreamProcessor!
    var buffer: SendablePixelBuffer!
    
    override func setUp() async throws {
        strategy = MockStrategy()
        detector = MockFaceDetector()
        processor = StreamProcessor(strategy: strategy, detector: detector)
        
        // Inject config
        let config = try await strategy.resolveConfig()
        await processor._setConfig(config)
        
        // Create dummy buffer
        var cvBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &cvBuffer)
        buffer = SendablePixelBuffer(cvBuffer!)
    }
    
    func testProcessFrame_HappyPath_CallsStrategy() async throws {
        await detector.setFace(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        
        // Send 20 frames (needs > 16 for cold start)
        for _ in 0..<20 {
            await processor.processFrame(buffer)
        }
        
        // Wait for async processing
        try await Task.sleep(nanoseconds: 200 * 1_000_000)
        
        let count = await strategy.processCalledCount
        XCTAssertGreaterThan(count, 0, "Strategy should be called when face is present")
    }
    
    func testProcessFrame_NoFace_DoesNotCallStrategy() async throws {
        // Ensure no face is detected
        await detector.setFace(nil)
        
        // Send frames
        for _ in 0..<20 {
            await processor.processFrame(buffer)
        }
        
        try await Task.sleep(nanoseconds: 200 * 1_000_000)
        
        let count = await strategy.processCalledCount
        XCTAssertEqual(count, 0, "Strategy should NOT be called when no face is detected")
    }
    
    func testProcessFrame_StrategyFailure_RecoversAndContinues() async throws {
        await detector.setFace(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        
        // 1. Force Failure
        await strategy.setShouldFail(true)
        
        // Send batch that will fail
        for _ in 0..<20 { await processor.processFrame(buffer) }
        try await Task.sleep(nanoseconds: 200 * 1_000_000)
        
        // 2. Heal
        await strategy.setShouldFail(false)
        
        // Send another batch
        // The processor should not be stuck in "isSending" state.
        for _ in 0..<20 { await processor.processFrame(buffer) }
        try await Task.sleep(nanoseconds: 200 * 1_000_000)
        
        let count = await strategy.processCalledCount
        XCTAssertGreaterThan(count, 0, "Processor should recover and process subsequent frames after an error")
    }
    
    func testStop_ResetsState() async throws {
        await detector.setFace(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        
        // Send some frames to fill buffer partially
        for _ in 0..<10 { await processor.processFrame(buffer) }
        
        // Stop
        await processor.stop()
        
        // Send more frames (should be ignored or start fresh)
        for _ in 0..<10 { await processor.processFrame(buffer) }
        
        try await Task.sleep(nanoseconds: 200 * 1_000_000)
        
        let count = await strategy.processCalledCount
        XCTAssertEqual(count, 0, "Strategy should not be called immediately after stop/reset (buffer was cleared)")
    }
}