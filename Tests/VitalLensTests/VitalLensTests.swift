import XCTest
import CoreVideo
@testable import VitalLens
@testable import VitalLensCore

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
        
        // 6. Stop
        client.stopStream()
    }
    
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

final class MockCameraSource: CameraStreaming, @unchecked Sendable {
    private var continuation: AsyncStream<SendablePixelBuffer>.Continuation?
    
    var stream: AsyncStream<SendablePixelBuffer> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    
    func start() async throws {
        // Simulate the camera producing frames
        Task {
            for _ in 0..<30 {
                // 30fps simulation
                try? await Task.sleep(nanoseconds: 33_000_000)
                
                if let buffer = createDummyBuffer() {
                    continuation?.yield(SendablePixelBuffer(buffer))
                }
            }
        }
    }
    
    func stop() {
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