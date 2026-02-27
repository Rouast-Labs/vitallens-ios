import XCTest
import CoreVideo
import VitalLensInference
@testable import VitalLens

#if canImport(UIKit)
import UIKit
#endif

final class VitalLensTests: XCTestCase {

    // MARK: - Integration Tests
    
    func testStartStream_InitializesAndStartsProcessor() async throws {
        let strategy = MockInferenceStrategy()
        let roiStrategy = MockROIStrategy()
        let mockCamera = MockCameraSource()
        
        let processor = StreamProcessor(
            strategy: strategy,
            roiStrategy: roiStrategy,
            camera: mockCamera
        )
        
        let client = VitalLens(processor: processor)
        
        let stream = try await client.startStream()
        
        let buffer = createDummyBuffer()
        let baseTime = Date().timeIntervalSince1970
        
        await roiStrategy.setROI(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        
        Task {
            for i in 0..<20 {
                let frame = InputFrame(
                    buffer: buffer,
                    orientation: .up,
                    isMirrored: true,
                    timestamp: baseTime + (Double(i) * 0.033)
                )
                await processor.processFrame(frame)
            }
        }
        
        var resultCount = 0
        for await _ in stream {
            resultCount += 1
            if resultCount >= 1 { break } 
        }
        
        XCTAssertGreaterThan(resultCount, 0, "Client should yield results from the processor")
        
        #if canImport(UIKit)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mockCamera.startCallCount, 1, "Camera should have been started")
        #endif
        
        client.stopStream()
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        #if canImport(UIKit)
        XCTAssertEqual(mockCamera.stopCallCount, 1, "Camera should have been stopped")
        #endif
    }
    
    #if canImport(UIKit)
    func testLifecycle_BackgroundingPausesCamera() async throws {
        let strategy = MockInferenceStrategy()
        let roiStrategy = MockROIStrategy()
        let mockCamera = MockCameraSource()
        
        let processor = StreamProcessor(
            strategy: strategy,
            roiStrategy: roiStrategy,
            camera: mockCamera
        )
        
        let client = VitalLens(processor: processor)
        _ = try await client.startStream()
        
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mockCamera.startCallCount, 1)
        
        await MainActor.run {
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        }
        
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mockCamera.stopCallCount, 1, "Camera should stop on background")
        
        await MainActor.run {
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mockCamera.startCallCount, 2, "Camera should restart on foreground")
    }
    #endif
    
    func testInitialization_SetsPublicProperties() {
        let client = VitalLens(apiKey: "key", method: "vitallens-2.0")
        XCTAssertEqual(client.apiKey, "key")
        XCTAssertEqual(client.method, "vitallens-2.0")
    }

    func testOnFaceStateChanged_CallbackPropagatesToProcessor() async throws {
        let strategy = MockInferenceStrategy()
        let roiStrategy = MockROIStrategy()
        let mockCamera = MockCameraSource()
        
        let processor = StreamProcessor(
            strategy: strategy,
            roiStrategy: roiStrategy,
            camera: mockCamera
        )
        
        let client = VitalLens(processor: processor)
        
        let expectation = XCTestExpectation(description: "Face state callback triggered")
        
        client.onFaceStateChanged = { isPresent in
            if isPresent {
                expectation.fulfill()
            }
        }
        
        _ = try await client.startStream()
        
        await roiStrategy.setROI(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        
        let buffer = createDummyBuffer()
        let frame = InputFrame(buffer: buffer, orientation: .up, isMirrored: false, timestamp: 1.0)
        
        await processor.processFrame(frame)
        
        await fulfillment(of: [expectation], timeout: 2.0)
    }
    
    // MARK: - Helpers
    
    private func createDummyBuffer() -> SendablePixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &buffer)
        
        CVPixelBufferLockBaseAddress(buffer!, [])
        if let base = CVPixelBufferGetBaseAddress(buffer!) {
            memset(base, 255, CVPixelBufferGetDataSize(buffer!))
        }
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        
        return SendablePixelBuffer(buffer!)
    }
}

// MARK: - Local Mocks Only

final class MockCameraSource: CameraStreaming, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.vitallens.mockcamera")
    private var _startCallCount = 0
    private var _stopCallCount = 0
    
    var startCallCount: Int { queue.sync { _startCallCount } }
    var stopCallCount: Int { queue.sync { _stopCallCount } }
    
    var stream: AsyncStream<InputFrame> { AsyncStream { _ in } }
    
    func start() async throws {
        queue.sync { _startCallCount += 1 }
    }
    
    func stop() {
        queue.sync { _stopCallCount += 1 }
    }
    
    #if canImport(UIKit)
    @MainActor func showPreview(on view: UIView) {}
    #endif
}