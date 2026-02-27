import XCTest
import AVFoundation
import CoreVideo
import VitalLensCore
import VitalLensInference
@testable import VitalLens

final class FileProcessorTests: XCTestCase {
    
    var tempURL: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        tempURL = try await createTemporaryVideoFile(frameCount: 30)
    }
    
    override func tearDown() async throws {
        if let url = tempURL {
            try? FileManager.default.removeItem(at: url)
        }
        try await super.tearDown()
    }
    
    // MARK: - Integration Tests
    
    func testProcess_SuccessfulPipeline() async throws {
        let mockDetector = MockFaceDetector(rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        let mockStrategy = MockStrategy()
        
        let processor = FileProcessor(url: tempURL, detector: mockDetector)
        
        print("[Test] Starting Process...")
        
        let result = try await processor.process(strategy: mockStrategy)
        
        print("[Test] Finished Process. Result samples: \(result.sampleCount ?? -1)")
        
        XCTAssertTrue(mockStrategy.resolveConfigCalled, "Should have resolved config")
        
        let calls = mockStrategy.inferCallCount
        XCTAssertGreaterThan(calls, 0, "Inference should have been called (Count: \(calls))")
        
        XCTAssertEqual(result.fps ?? 0.0, 30.0, accuracy: 1.0, "FPS should match source video")
        
        let samples = result.sampleCount ?? 0
        XCTAssertGreaterThan(samples, 5, "Should have produced multiple stitched samples")
        
        XCTAssertEqual(result.time.count, samples, "Time array should match sample count")
        
        if let lastTime = result.time.last {
            XCTAssertGreaterThan(lastTime, 0.5, "Result duration should be roughly the video length")
        }
    }
    
    func testProcess_NoFaceDetected_ThrowsError() async throws {
        let mockDetector = MockFaceDetector(rect: nil)
        let mockStrategy = MockStrategy()
        
        let processor = FileProcessor(url: tempURL, detector: mockDetector)
        
        do {
            _ = try await processor.process(strategy: mockStrategy)
            XCTFail("Should have thrown error")
        } catch let error as VitalLensError {
            if case .processingError(let msg) = error {
                XCTAssertTrue(msg.contains("No face detected"))
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
    
    func testProcess_AppliesGlobalROI() async throws {
        let explicitROI = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let spyDetector = MockFaceDetector(rect: nil)
        
        let mockStrategy = MockStrategy()
        let processor = FileProcessor(url: tempURL, detector: spyDetector)
        
        let result = try await processor.process(strategy: mockStrategy, globalROI: explicitROI)
        
        XCTAssertGreaterThan(mockStrategy.inferCallCount, 0)
        XCTAssertGreaterThan(result.sampleCount ?? 0, 0)
    }

    // MARK: - Mocks
    
    actor MockFaceDetector: FaceDetecting {
        let rect: CGRect?
        init(rect: CGRect?) { self.rect = rect }
        
        func detectFace(
            in pixelBuffer: SendablePixelBuffer, 
            orientation: CGImagePropertyOrientation, 
            isMirrored: Bool
        ) async throws -> CGRect? {
            return rect
        }
    }
    
    final class MockStrategy: InferenceStrategy, @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.vitallens.test.mockstrategy")
        private var _resolveConfigCalled = false
        private var _inferCallCount = 0
        private var _currentTime: Double = 0.0
        
        var resolveConfigCalled: Bool { queue.sync { _resolveConfigCalled } }
        var inferCallCount: Int { queue.sync { _inferCallCount } }

        nonisolated var bufferConfig: BufferConfig {
            return BufferConfig(minNoState: 4, minWithState: 2, streamMax: 10, fileMax: 10, overlap: 1)
        }
        
        func resolveConfig() async throws -> ModelConfig {
            queue.sync { _resolveConfigCalled = true }
            return ModelConfig(
                nInputs: 2,
                inputSize: 40,
                fpsTarget: 30.0,
                roiMethod: "face",
                supportedVitals: ["heart_rate"]
            )
        }
        
        func infer(window: [(InferenceUnit, InferenceContext)], state: (any InferenceState)?, mode: InferenceMode, model: String?) async throws -> (result: VitalLensResult, newState: (any InferenceState)?) {
            
            let count = window.count
            var times: [Double] = []
            var datas: [Float] = []
            var confs: [Float] = []
            
            let startT: Double = queue.sync {
                _inferCallCount += 1
                let t = _currentTime
                _currentTime += (Double(count) / 30.0)
                return t
            }
            
            for i in 0..<count {
                times.append(startT + Double(i) / 30.0)
                datas.append(72.0)
                confs.append(1.0)
            }
            
            let result = VitalLensResult(
                face: FaceData(coordinates: nil, confidence: nil, note: nil),
                vitals: ["heart_rate": Vital(value: 72.0, confidence: 1.0, unit: "bpm")],
                waveforms: [:],
                time: times,
                fps: 30.0,
                modelUsed: "mock",
                state: nil,
                message: nil,
                sampleCount: count
            )
            return (result, state)
        }
    }
    
    // MARK: - Video Generation Helper
    
    private func createTemporaryVideoFile(frameCount: Int) async throws -> URL {
        let filename = UUID().uuidString + ".mp4"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 128,
            AVVideoHeightKey: 128
        ]
        
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        
        if writer.canAdd(input) { writer.add(input) }
        
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        let fps: Int32 = 30
        
        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if let buffer = createSolidPixelBuffer() {
                let time = CMTime(value: Int64(i), timescale: fps)
                adaptor.append(buffer, withPresentationTime: time)
            }
        }
        
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }
    
    private func createSolidPixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA, nil, &buffer)
        
        if let pixelBuffer = buffer {
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, 255, CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        
        return buffer
    }
}