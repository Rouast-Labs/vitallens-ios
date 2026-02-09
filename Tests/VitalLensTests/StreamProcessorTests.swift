import XCTest
import CoreVideo
@testable import VitalLens
@testable import VitalLensCore

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

final class StreamProcessorTests: XCTestCase {
    
    var strategy: MockStrategy!
    var detector: MockFaceDetector!
    var processor: StreamProcessor!
    var buffer: SendablePixelBuffer!
    
    override func setUp() async throws {
        strategy = MockStrategy()
        detector = MockFaceDetector()
        processor = StreamProcessor(strategy: strategy, detector: detector)
        
        // We must call start() to initialize the background loop
        _ = try await processor.start()
        
        var cvBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &cvBuffer)
        buffer = SendablePixelBuffer(cvBuffer!)
    }
    
    override func tearDown() async throws {
        await processor.stop()
        strategy = nil
        detector = nil
        processor = nil
    }
    
    func testProcessFrame_HappyPath_CallsStrategy() async throws {
        await detector.setFace(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        
        // Push frames fast
        for _ in 0..<20 {
            await processor.processFrame(buffer)
        }
        
        // Give the background loop a moment to wake up and process
        try await Task.sleep(nanoseconds: 200 * 1_000_000)
        
        let count = await strategy.processCalledCount
        XCTAssertGreaterThan(count, 0, "Strategy should be called by the background loop")
    }
    
    func testProcessFrame_NoFace_DoesNotCallStrategy() async throws {
        await detector.setFace(nil)
        
        for _ in 0..<20 {
            await processor.processFrame(buffer)
        }
        
        try await Task.sleep(nanoseconds: 200 * 1_000_000)
        
        let count = await strategy.processCalledCount
        XCTAssertEqual(count, 0, "Strategy should NOT be called when no face is detected (BufferManager returns no ROIs)")
    }
    
    func testProcessFrame_StrategyFailure_RecoversAndContinues() async throws {
        await detector.setFace(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        
        // 1. Induce Failure
        await strategy.setShouldFail(true)
        
        for _ in 0..<20 { await processor.processFrame(buffer) }
        try await Task.sleep(nanoseconds: 200 * 1_000_000)
        
        // 2. Heal
        await strategy.setShouldFail(false)
        
        // 3. Continue Processing
        for _ in 0..<20 { await processor.processFrame(buffer) }
        try await Task.sleep(nanoseconds: 200 * 1_000_000)
        
        let count = await strategy.processCalledCount
        XCTAssertGreaterThan(count, 0, "Processor should recover and process subsequent frames after an error")
    }
    
    func testStop_KillsBackgroundLoop() async throws {
        await detector.setFace(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        
        // 1. Process some frames
        for _ in 0..<10 { await processor.processFrame(buffer) }
        try await Task.sleep(nanoseconds: 100 * 1_000_000)
        
        let countBefore = await strategy.processCalledCount
        
        // 2. Stop
        await processor.stop()
        
        // 3. Try to process more (Inference Loop should be dead)
        for _ in 0..<50 { await processor.processFrame(buffer) }
        try await Task.sleep(nanoseconds: 200 * 1_000_000)
        
        let countAfter = await strategy.processCalledCount
        
        // Even though frames were pushed, the loop was cancelled, so count should not increase significantly
        // (It might increase by 1 if a request was already in flight, but not 50 frames worth)
        XCTAssertEqual(countAfter, countBefore, "Strategy calls should stop after processor.stop()")
    }
}