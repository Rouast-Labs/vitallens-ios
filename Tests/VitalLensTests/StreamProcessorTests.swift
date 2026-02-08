import XCTest
import CoreVideo
@testable import VitalLens
@testable import VitalLensCore

// MARK: - Mocks

actor MockStrategy: InferenceStrategy {
    var processCalledCount = 0
    
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
    
    func setFace(_ rect: CGRect) {
        self.forcedRect = rect
    }
}

// MARK: - Tests

final class StreamProcessorTests: XCTestCase {
    
    func testProcessFrame_SendsDataToStrategy() async throws {
        // 1. Setup
        let strategy = MockStrategy()
        let detector = MockFaceDetector()
        let processor = StreamProcessor(strategy: strategy, detector: detector)
        
        // Inject config directly to skip API resolution
        let config = try await strategy.resolveConfig()
        await processor._setConfig(config)
        
        // 2. Setup Dummy Face & Buffer
        await detector.setFace(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let cvBuffer = try createPixelBuffer()
        let buffer = SendablePixelBuffer(cvBuffer)
        
        // 3. Process frames
        // The API requires a minimum of 16 frames for the first batch (Cold Start)
        // to establish RNN state. We send 20 to ensure we cross this threshold.
        for _ in 0..<20 {
            await processor.processFrame(buffer)
        }
        
        // 4. Verify
        // Allow time for the detached 'checkAndSend' task to execute
        try await Task.sleep(nanoseconds: 500 * 1_000_000) // 0.5s
        
        let count = await strategy.processCalledCount
        XCTAssertGreaterThan(count, 0, "Strategy.process should have been called after buffering enough frames")
    }
    
    private func createPixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }
}