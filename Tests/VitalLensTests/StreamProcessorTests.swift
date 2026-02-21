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
    var currentROI: CGRect? = nil
    
    func setROI(_ roi: CGRect?) {
        self.currentROI = roi
    }
    
    func determineROI(in buffer: SendablePixelBuffer, orientation: CGImagePropertyOrientation) async -> CGRect? {
        return currentROI
    }
}

actor MockInferenceStrategy: InferenceStrategy {
    var inferCallCount = 0
    var lastReceivedState: (any InferenceState)?
    var stateHistory: [(any InferenceState)?] = []
    private var shouldFail = false
    
    func resolveConfig() async throws -> ModelConfig {
        return ModelConfig(
            nInputs: 2,
            inputSize: 40,
            fpsTarget: 30,
            roiMethod: "face",
            supportedVitals: ["heart_rate"]
        )
    }
    
    nonisolated var bufferConfig: BufferConfig {
        return BufferConfig(minNoState: 4, minWithState: 2, streamMax: 10, fileMax: 10, overlap: 1)
    }
    
    func setShouldFail(_ fail: Bool) {
        self.shouldFail = fail
    }
    
    func clearHistory() {
        self.stateHistory.removeAll()
    }
    
    func infer(
        window: [(InferenceUnit, InferenceContext)],
        state: (any InferenceState)?,
        mode: InferenceMode,
        model: String?
    ) async throws -> (result: VitalLensResult, newState: (any InferenceState)?) {
        
        self.lastReceivedState = state
        self.stateHistory.append(state) // 2. Record it
        self.inferCallCount += 1
        
        if shouldFail {
            throw VitalLensError.serverError(statusCode: 500, message: "Mock Failure")
        }
        
        let result = VitalLensResult(
            face: FaceData(coordinates: nil, confidence: nil, note: nil),
            vitals: [:],
            waveforms: [
                "ppg_waveform": Waveform(data: [0.1, 0.2, 0.3, 0.4], confidence: [1.0, 1.0, 1.0, 1.0], unit: "unitless", note: nil)
            ],
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
        await roiStrategy.setROI(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        
        for i in 0..<10 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let count = await strategy.inferCallCount
        XCTAssertGreaterThan(count, 0, "Strategy should be called when buffer fills")
    }
    
    func testProcessFrame_NoROI_DoesNotCallStrategy() async throws {
        await roiStrategy.setROI(nil)
        
        for i in 0..<10 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let count = await strategy.inferCallCount
        XCTAssertEqual(count, 0, "Strategy should NOT be called if no ROIs detected")
    }
    
    func testResilience_BackoffAndRecovery() async throws {
        await roiStrategy.setROI(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        
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
        await roiStrategy.setROI(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        
        // 1. Establish initial state
        for i in 0..<6 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        try await Task.sleep(nanoseconds: 300_000_000)
        let stateBefore = await strategy.lastReceivedState
        XCTAssertNotNil(stateBefore, "Should have established state")
        
        // 2. Trigger failures
        await strategy.setShouldFail(true)
        for i in 10..<60 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        
        // Wait for the final error to propagate and trigger the internal reset
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // 3. Recover and clear history so we only record new inferences
        await strategy.setShouldFail(false)
        await strategy.clearHistory()
        
        // 4. Send new valid frames
        for i in 100..<110 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let history = await strategy.stateHistory
        
        // Assert the FIRST inference after the reset had a nil state
        XCTAssertFalse(history.isEmpty, "Should have performed at least one successful inference after recovery")
        if !history.isEmpty {
            XCTAssertNil(history[0], "The FIRST inference after max retries MUST have a nil state due to the internal reset.")
        }
    }
    
    // MARK: - New Coverage
    
    func testPauseResume_ControlsFrameFlow() async throws {
        await roiStrategy.setROI(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        
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
        let failingTransformer: FrameTransformer = { _, _, _, _, _ in
            throw VitalLensError.processingError("Simulated Transform Fail")
        }
        
        let failProcessor = StreamProcessor(
            strategy: strategy,
            roiStrategy: roiStrategy,
            camera: MockCamera(),
            transformer: failingTransformer
        )
        _ = try await failProcessor.start()
        
        await roiStrategy.setROI(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        
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

    func testStateFlow_ContinuityBetweenInferences() async throws {
        await roiStrategy.setROI(CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1))
        
        // Push frames to trigger TWO separate inference calls
        // Buffer overlap is 1, min frames with state is 2.
        for i in 0..<15 {
            await processor.processFrame(makeFrame(at: Double(i) * 0.033))
            // Small pause to let the actor process the first batch and update state
            if i == 5 { try await Task.sleep(nanoseconds: 100_000_000) } 
        }
        
        try await Task.sleep(nanoseconds: 300_000_000)
        
        let history = await strategy.stateHistory
        XCTAssertGreaterThanOrEqual(history.count, 2)
        
        if history.count >= 2 {
            XCTAssertNil(history[0], "The very first inference state must be nil")
            XCTAssertNotNil(history[1], "The second inference should have received the state from the first")
            let secondBatchState = history[1] as? MockState
            XCTAssertEqual(secondBatchState?.id, "state_1")
        }
    }

    func testBufferPruning_OnFaceLoss() async throws {
        _ = try await processor.start()
        await strategy.clearHistory()
        
        // 1. Detect a face at T=1.0 to create an active buffer
        await roiStrategy.setROI(CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        await processor.processFrame(makeFrame(at: 1.0))
        
        // 2. Lose the face
        await roiStrategy.setROI(nil)
        
        // 3. Send a frame at T=7.0 (exceeding the 5.0s timeout)
        await processor.processFrame(makeFrame(at: 7.0))
        
        // 4. Wait for the actor's background loop to catch up and prune
        try await Task.sleep(nanoseconds: 300_000_000)
        
        // If pruning worked, the buffer was dropped during the poll at T=7.0
        // so no inference should have been triggered.
        let count = await strategy.inferCallCount
        XCTAssertEqual(count, 0, "Stale buffers must be pruned before inference can be triggered")
    }
}