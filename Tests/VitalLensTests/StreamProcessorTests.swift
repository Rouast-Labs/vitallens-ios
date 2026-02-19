import XCTest
import CoreVideo
import ImageIO
import AVFoundation
import VitalLensCore
import VitalLensInference
@testable import VitalLens

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Mocks

actor MockROIStrategy: ROIStrategy {
    var currentROIs: [CGRect] = []
    
    func setROIs(_ rois: [CGRect]) {
        self.currentROIs = rois
    }
    
    func determineROIs(in buffer: SendablePixelBuffer, orientation: CGImagePropertyOrientation) async -> [CGRect] {
        return currentROIs
    }
}

actor MockInferenceStrategy: InferenceStrategy {
    var inferCallCount = 0
    var lastReceivedState: (any InferenceState)?
    private var shouldFail = false
    
    func resolveConfig() async throws -> ModelConfig {
        return ModelConfig(
            nInputs: 4,
            inputSize: 40,
            fpsTarget: 30,
            roiMethod: "face",
            supportedVitals: ["heart_rate"]
        )
    }
    
    nonisolated var batchConstraints: BatchConstraints {
        return BatchConstraints(minNoState: 16, minWithState: 4, streamMax: 10)
    }
    
    func setShouldFail(_ fail: Bool) {
        self.shouldFail = fail
    }
    
    func infer(
        window: [(InferenceUnit, InferenceContext)],
        state: (any InferenceState)?,
        mode: InferenceMode,
        model: String?
    ) async throws -> (result: VitalLensResult, newState: (any InferenceState)?) {
        
        self.lastReceivedState = state
        self.inferCallCount += 1
        
        if shouldFail {
            throw VitalLensError.serverError(statusCode: 500, message: "Mock Failure")
        }
        
        let result = VitalLensResult(
            face: FaceData(coordinates: nil, confidence: nil, note: nil),
            signals: ["heart_rate": TimeSeries(data: [72.0], confidence: [1.0], unit: "bpm", note: nil)],
            time: [Date().timeIntervalSince1970],
            fps: 30.0,
            modelUsed: "mock",
            state: nil,
            message: nil,
            sampleCount: 1
        )
        
        let newState = MockState(id: "state_\(inferCallCount)")
        return (result, newState)
    }
}

struct MockState: InferenceState {
    let id: String
}

class MockCamera: CameraStreaming, @unchecked Sendable {
    var stream: AsyncStream<InputFrame> { AsyncStream { _ in } }
    func start() async throws {}
    func stop() {}
    #if canImport(UIKit)
    func showPreview(on view: UIView) {}
    #endif
}

// MARK: - Tests

final class StreamProcessorTests: XCTestCase {
    
    var strategy: MockInferenceStrategy!
    var roiStrategy: MockROIStrategy!
    var processor: StreamProcessor!
    var baseBuffer: SendablePixelBuffer!
    
    override func setUp() async throws {
        strategy = MockInferenceStrategy()
        roiStrategy = MockROIStrategy()
        let camera = MockCamera()
        
        processor = StreamProcessor(
            strategy: strategy,
            roiStrategy: roiStrategy,
            camera: camera
        )
        
        // Create a reusable dummy buffer
        var cvBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &cvBuffer)
        
        // Fill buffer to be safe
        CVPixelBufferLockBaseAddress(cvBuffer!, [])
        if let base = CVPixelBufferGetBaseAddress(cvBuffer!) {
            memset(base, 255, CVPixelBufferGetDataSize(cvBuffer!))
        }
        CVPixelBufferUnlockBaseAddress(cvBuffer!, [])
        
        baseBuffer = SendablePixelBuffer(cvBuffer!)
        
        // Start processor
        _ = try await processor.start()
    }
    
    override func tearDown() async throws {
        await processor.stop()
        strategy = nil
        roiStrategy = nil
        processor = nil
    }
    
    // Helper to create frames with explicit timestamps
    private func makeFrame(at time: Double) -> InputFrame {
        InputFrame(
            buffer: baseBuffer,
            orientation: .up,
            isMirrored: true,
            timestamp: time
        )
    }
    
    // MARK: - Test Cases
    
    func testProcessFrame_HappyPath_CallsStrategy() async throws {
        await roiStrategy.setROIs([CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)])
        
        for i in 0..<10 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let count = await strategy.inferCallCount
        XCTAssertGreaterThan(count, 0, "Strategy should be called when buffer fills")
    }
    
    func testProcessFrame_NoROI_DoesNotCallStrategy() async throws {
        await roiStrategy.setROIs([])
        
        for i in 0..<10 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let count = await strategy.inferCallCount
        XCTAssertEqual(count, 0, "Strategy should NOT be called if no ROIs detected")
    }
    
    func testResilience_BackoffAndRecovery() async throws {
        await roiStrategy.setROIs([CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)])
        
        // 1. Initial Success
        for i in 0..<5 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let initialCount = await strategy.inferCallCount
        XCTAssertGreaterThan(initialCount, 0)
        
        // 2. Trigger Failure
        await strategy.setShouldFail(true)
        
        for i in 10..<20 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        // Wait for backoff
        try await Task.sleep(nanoseconds: 300_000_000)
        
        // 3. Recovery
        await strategy.setShouldFail(false)
        
        for i in 20..<30 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        try await Task.sleep(nanoseconds: 300_000_000)
        
        let finalCount = await strategy.inferCallCount
        XCTAssertGreaterThan(finalCount, initialCount + 1, "Should recover after failure")
    }
    
    func testResilience_MaxRetries_ResetsState() async throws {
        await roiStrategy.setROIs([CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)])
        
        // 1. Establish State (Success)
        // Pump enough frames for at least one batch
        for i in 0..<6 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        // Wait for inference to run once
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let stateBefore = await strategy.lastReceivedState
        XCTAssertNotNil(stateBefore, "Should have established state")
        
        // 2. Trigger Max Retries (Failure)
        await strategy.setShouldFail(true)
        
        // We need to keep feeding the buffer so the loop has data to "fail" on multiple times.
        // We pump frames slowly over a longer period to span across the backoff windows.
        // Backoff: 0.1s -> 0.2s -> 0.4s. Total ~0.7s to hit 3 failures.
        
        for i in 10..<60 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
            // Sleep 25ms between frames = 50 frames * 25ms = 1.25s total duration.
            // This ensures the loop is kept alive and retrying well past the 0.7s mark.
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        
        // 3. Verify Reset
        // At this point, the processor should have hit 3 failures and called reset().
        
        // Enable success again
        await strategy.setShouldFail(false)
        
        // Pump fresh frames (Needs 4 for new batch)
        for i in 100..<110 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        // Wait for the successful inference
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let stateAfter = await strategy.lastReceivedState
        
        // If reset happened, the state passed to this new successful inference MUST be nil.
        XCTAssertNil(stateAfter, "State should be nil after max retries triggered a reset. Got: \(String(describing: stateAfter))")
    }
    
    // MARK: - New Coverage
    
    func testPauseResume_ControlsFrameFlow() async throws {
        await roiStrategy.setROIs([CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)])
        
        // 1. Pause
        await processor.pause()
        
        for i in 0..<10 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let countPaused = await strategy.inferCallCount
        XCTAssertEqual(countPaused, 0, "Strategy should NOT be called while paused")
        
        // 2. Resume
        try await processor.resume()
        
        for i in 10..<20 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let countResumed = await strategy.inferCallCount
        XCTAssertGreaterThan(countResumed, 0, "Strategy SHOULD be called after resume")
    }
    
    func testTransformerError_DoesNotCrashLoop() async throws {
        let failingTransformer: FrameTransformer = { _, _, _ in
            throw VitalLensError.processingError("Simulated Transform Fail")
        }
        
        let failProcessor = StreamProcessor(
            strategy: strategy,
            roiStrategy: roiStrategy,
            camera: MockCamera(),
            transformer: failingTransformer
        )
        _ = try await failProcessor.start()
        
        await roiStrategy.setROIs([CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)])
        
        for i in 0..<10 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await failProcessor.processFrame(frame)
        }
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let count = await strategy.inferCallCount
        XCTAssertEqual(count, 0, "Inference should not run if transformation fails")
        
        await failProcessor.stop()
    }
    
    func testRapidStartStop_DoesNotDeadlock() async throws {
        await processor.stop()
        _ = try await processor.start()
        await processor.stop()
        _ = try await processor.start()
        await processor.stop()
        
        XCTAssertTrue(true)
    }
}