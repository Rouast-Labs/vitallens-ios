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
    
    func determineROI(
        in buffer: SendablePixelBuffer, 
        orientation: CGImagePropertyOrientation, 
        isMirrored: Bool, 
        roiMethod: String
    ) async -> CGRect? {
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
        self.stateHistory.append(state)
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
        
        var cvBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &cvBuffer)
        
        CVPixelBufferLockBaseAddress(cvBuffer!, [])
        if let base = CVPixelBufferGetBaseAddress(cvBuffer!) {
            memset(base, 255, CVPixelBufferGetDataSize(cvBuffer!))
        }
        CVPixelBufferUnlockBaseAddress(cvBuffer!, [])
        
        baseBuffer = SendablePixelBuffer(cvBuffer!)
        
        _ = try await processor.start()
    }
    
    override func tearDown() async throws {
        await processor.stop()
        strategy = nil
        roiStrategy = nil
        processor = nil
    }
    
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
        
        for i in 0..<5 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let initialCount = await strategy.inferCallCount
        XCTAssertGreaterThan(initialCount, 0)
        
        await strategy.setShouldFail(true)
        
        for i in 10..<20 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        try await Task.sleep(nanoseconds: 300_000_000)
        
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
        
        for i in 0..<6 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let stateBefore = await strategy.lastReceivedState
        XCTAssertNotNil(stateBefore, "Should have established state")
        
        await strategy.setShouldFail(true)
        for i in 10..<60 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        await strategy.setShouldFail(false)
        await strategy.clearHistory()
        
        for i in 100..<110 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        let history = await strategy.stateHistory
        
        XCTAssertFalse(history.isEmpty, "Should have performed at least one successful inference after recovery")
        if !history.isEmpty {
            XCTAssertNil(history[0], "The FIRST inference after max retries MUST have a nil state due to the internal reset.")
        }
    }
    
    // MARK: - New Coverage
    
    func testPauseResume_ControlsFrameFlow() async throws {
        await roiStrategy.setROI(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        
        await processor.pause()
        
        for i in 0..<10 {
            let frame = makeFrame(at: Double(i) * 0.033)
            await processor.processFrame(frame)
        }
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let countPaused = await strategy.inferCallCount
        XCTAssertEqual(countPaused, 0, "Strategy should NOT be called while paused")
        
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
        
        for i in 0..<15 {
            await processor.processFrame(makeFrame(at: Double(i) * 0.033))
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
        
        await roiStrategy.setROI(CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        await processor.processFrame(makeFrame(at: 1.0))
        
        await roiStrategy.setROI(nil)        
        await processor.processFrame(makeFrame(at: 7.0))
        
        try await Task.sleep(nanoseconds: 300_000_000)
        
        let count = await strategy.inferCallCount
        XCTAssertEqual(count, 0, "Stale buffers must be pruned before inference can be triggered")
    }

    func testProcessFrame_FaceStateCallback_And_BufferReset() async throws {
        actor CallbackTracker {
            var changes: [Bool] = []
            func append(_ val: Bool) { changes.append(val) }
            func get() -> [Bool] { changes }
        }
        let tracker = CallbackTracker()
        
        await processor.setFaceStateCallback { isPresent in
            Task { await tracker.append(isPresent) }
        }
        
        await roiStrategy.setROI(CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1))
        await processor.processFrame(makeFrame(at: 1.0))
        
        try await Task.sleep(nanoseconds: 10_000_000) 
        var states = await tracker.get()
        XCTAssertEqual(states.count, 1)
        XCTAssertTrue(states.last == true, "Callback should fire with true when face appears")
        
        await processor.processFrame(makeFrame(at: 1.1))
        await processor.processFrame(makeFrame(at: 1.2))
        
        try await Task.sleep(nanoseconds: 10_000_000)
        states = await tracker.get()
        XCTAssertEqual(states.count, 1, "Callback should NOT fire again if state hasn't changed")
        
        await roiStrategy.setROI(nil)
        await processor.processFrame(makeFrame(at: 1.3))
        
        try await Task.sleep(nanoseconds: 10_000_000)
        states = await tracker.get()
        XCTAssertEqual(states.count, 2)
        XCTAssertFalse(states.last == true, "Callback should fire with false when face is lost")
        
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = await strategy.inferCallCount
        XCTAssertEqual(count, 0, "API calls should not have been made because the buffer was purged on face loss")
    }

    func testProcessFrame_WithCustomTransformer_UsesCustomLogic() async throws {
        let expectation = XCTestExpectation(description: "Custom transformer called")
        
        let customTransformer: FrameTransformer = { buffer, roi, config, orientation, isMirrored in
            expectation.fulfill()
            return .rgbData(Data([0xFF, 0x00, 0x00]))
        }
        
        let mockROI = MockROIStrategy()
        await mockROI.setROI(CGRect(x: 0, y: 0, width: 1, height: 1))
        
        let processor = StreamProcessor(
            strategy: MockInferenceStrategy(),
            roiStrategy: mockROI,
            transformer: customTransformer
        )
        
        _ = try await processor.start()
        
        await processor.processFrame(makeFrame(at: 1.0))
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }
}