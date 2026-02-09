import XCTest
import CoreVideo
@testable import VitalLens
@testable import VitalLensCore

#if canImport(UIKit)
import UIKit
#endif

final class VitalLensTests: XCTestCase {

    // Reuse mocks to verify the client sets up the pipeline correctly
    func testStartStream_InitializesAndStartsProcessor() async throws {
        // 1. Setup Mock Processor
        let strategy = MockStrategy()
        let detector = MockFaceDetector()

        let mockCamera = MockCameraSource()
        let processor = StreamProcessor(strategy: strategy, detector: detector, camera: mockCamera)
        
        // Manually inject config to bypass API resolution in test
        let config = try await strategy.resolveConfig()
        await processor._setConfig(config)
        
        // 2. Setup Client with Injected Processor
        let client = VitalLens(processor: processor)
        
        // 3. Start Stream
        let stream = try await client.startStream()
        
        // 4. Simulate Data Flow
        // Create a buffer and feed it to the processor manually (bypassing camera)
        var cvBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &cvBuffer)
        let buffer = SendablePixelBuffer(cvBuffer!)
        
        await detector.setFace(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        
        // Feed frames in a detached task so we can consume the stream below
        Task {
            for _ in 0..<20 {
                await processor.processFrame(buffer)
            }
        }
        
        // 5. Verify Results
        // We expect at least one result
        var resultCount = 0
        for await _ in stream {
            resultCount += 1
            if resultCount >= 1 { break } // Exit after first result
        }
        
        XCTAssertGreaterThan(resultCount, 0, "Client should yield results from the processor")
        
        #if canImport(UIKit)
        XCTAssertEqual(mockCamera.startCallCount, 1, "Camera should have been started")
        #endif
        
        // 6. Stop
        client.stopStream()
        
        // Give a moment for the async stop to propagate
        try await Task.sleep(nanoseconds: 100_000_000)
        
        #if canImport(UIKit)
        XCTAssertEqual(mockCamera.stopCallCount, 1, "Camera should have been stopped")
        #endif
    }
    
    #if canImport(UIKit)
    func testLifecycle_BackgroundingPausesCamera() async throws {
        // 1. Setup
        let strategy = MockStrategy()
        let mockCamera = MockCameraSource()
        let processor = StreamProcessor(strategy: strategy, detector: MockFaceDetector(), camera: mockCamera)
        let config = try await strategy.resolveConfig()
        await processor._setConfig(config)
        
        let client = VitalLens(processor: processor)
        _ = try await client.startStream()
        
        // Initial State
        XCTAssertEqual(mockCamera.startCallCount, 1)
        XCTAssertEqual(mockCamera.stopCallCount, 0)
        
        // 2. Simulate Backgrounding
        // VitalLens observes this on the Main Queue, so we post it there
        await MainActor.run {
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        }
        
        // Wait for async actor propagation
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // Should have called stop() on camera
        XCTAssertEqual(mockCamera.stopCallCount, 1, "Camera should stop on background")
        
        // 3. Simulate Foregrounding
        await MainActor.run {
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        
        // Wait for async actor propagation
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // Should have called start() on camera again
        XCTAssertEqual(mockCamera.startCallCount, 2, "Camera should restart on foreground")
    }
    #endif
    
    func testInitialization_SetsPublicProperties() {
        let url = URL(string: "https://proxy.com")
        let client = VitalLens(
            apiKey: "key",
            method: .vitalLens2,
            faceDetectionFrequency: 2.0,
            proxyURL: url
        )
        
        XCTAssertEqual(client.apiKey, "key")
        XCTAssertEqual(client.method, .vitalLens2)
        XCTAssertEqual(client.faceDetectionFrequency, 2.0)
        XCTAssertEqual(client.proxyURL, url)
    }
}

// MARK: - Mocks

final class MockCameraSource: CameraStreaming, @unchecked Sendable {
    private var continuation: AsyncStream<SendablePixelBuffer>.Continuation?
    
    // Use serial queue instead of NSLock for async safety in Swift 6 mode
    private let queue = DispatchQueue(label: "com.vitallens.mockcamera")
    
    private var _startCallCount = 0
    var startCallCount: Int {
        queue.sync { _startCallCount }
    }
    
    private var _stopCallCount = 0
    var stopCallCount: Int {
        queue.sync { _stopCallCount }
    }
    
    var stream: AsyncStream<SendablePixelBuffer> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    
    func start() async throws {
        queue.sync { _startCallCount += 1 }
        
        // Simulate the camera producing frames
        Task {
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 33_000_000)
                if let buffer = createDummyBuffer() {
                    continuation?.yield(SendablePixelBuffer(buffer))
                }
            }
        }
    }
    
    func stop() {
        queue.sync { _stopCallCount += 1 }
        continuation?.finish()
    }
    
    #if canImport(UIKit)
    @MainActor func showPreview(on view: UIView) {}
    #endif
    
    private func createDummyBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer
    }
}
