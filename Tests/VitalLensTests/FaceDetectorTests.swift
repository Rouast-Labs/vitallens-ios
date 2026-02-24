import XCTest
import AVFoundation
import Vision
import CoreVideo
import VitalLensInference
@testable import VitalLens

final class FaceDetectorTests: XCTestCase {
    
    var detector: FaceDetector!
    
    override func setUp() {
        super.setUp()
        detector = FaceDetector()
    }
    
    override func tearDown() {
        detector = nil
        super.tearDown()
    }
    
    // MARK: - Integration Tests
    
    func testDetectFace_InRealVideoFrame_ReturnsResult() async throws {
        // 1. Get the bundled video resource
        guard let url = Bundle.module.url(forResource: "sample_video_2", withExtension: "mp4") else {
            print("⚠️ Skipping testDetectFace_InRealVideoFrame: sample_video_2.mp4 not found in bundle.")
            return 
        }
        
        // 2. Extract the first frame safely
        let pixelBuffer: CVPixelBuffer
        
        do {
            let asset = AVAsset(url: url)
            
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else {
                XCTFail("Video asset has no video tracks")
                return
            }
            
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .positiveInfinity
            
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            pixelBuffer = try buffer(from: cgImage)
            
        } catch {
            let nsError = error as NSError
            if nsError.domain == AVFoundationErrorDomain {
                // Code -11800 is a generic "Operation could not be completed" which often wraps the underlying -17913
                throw XCTSkip("⚠️ Hardware video decoding unavailable in this environment. Skipping integration test.")
            }
            throw error // Rethrow legitimate failures (e.g. file not found)
        }
        
        let sendableBuffer = SendablePixelBuffer(pixelBuffer)
        
        // 3. Run Detection
        let result = try await detector.detectFace(in: sendableBuffer, orientation: .up)
        
        // 4. Verify
        XCTAssertNotNil(result, "Should detect a face in the sample video")
        
        if let rect = result {
            XCTAssertGreaterThanOrEqual(rect.origin.x, 0.0)
            XCTAssertLessThanOrEqual(rect.origin.x, 1.0)
            XCTAssertGreaterThanOrEqual(rect.origin.y, 0.0)
            XCTAssertLessThanOrEqual(rect.origin.y, 1.0)
            
            XCTAssertGreaterThan(rect.width, 0.05)
            XCTAssertLessThan(rect.width, 0.9)
            XCTAssertGreaterThan(rect.height, 0.05)
            XCTAssertLessThan(rect.height, 0.9)
        }
    }
    
    func testDetectFace_InBlankImage_ReturnsNil() async throws {
        // 1. Create a black frame (100x100)
        let buffer = try createSolidPixelBuffer(width: 100, height: 100, color: 0)
        let sendable = SendablePixelBuffer(buffer)
        
        // 2. Run Detection
        let result = try await detector.detectFace(in: sendable, orientation: .up)
        
        // 3. Verify
        XCTAssertNil(result, "Should not detect face in black noise")
    }

    func testDetectFace_Mirroring_FlipsXAxis() async throws {
        // 1. Setup resource
        guard let url = Bundle.module.url(forResource: "sample_video_2", withExtension: "mp4") else { return }
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        let cgImage: CGImage
        do {
            cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
        } catch {
            throw XCTSkip("⚠️ Hardware decoding unavailable.")
        }
        
        let buffer = try buffer(from: cgImage)
        let sendable = SendablePixelBuffer(buffer)
        
        // 2. Run Detection twice (Normal and Mirrored)
        let unmirroredRect = try await detector.detectFace(in: sendable, orientation: .up, isMirrored: false)
        let mirroredRect = try await detector.detectFace(in: sendable, orientation: .up, isMirrored: true)
        
        XCTAssertNotNil(unmirroredRect)
        XCTAssertNotNil(mirroredRect)
        
        // 3. Verify the horizontal flip math
        // If unmirrored X is 0.1 and width is 0.2, mirrored X must be 0.7 (1.0 - 0.1 - 0.2)
        let expectedMirroredX = 1.0 - unmirroredRect!.origin.x - unmirroredRect!.width
        
        XCTAssertEqual(mirroredRect!.origin.x, expectedMirroredX, accuracy: 0.0001)
        XCTAssertEqual(mirroredRect!.origin.y, unmirroredRect!.origin.y, accuracy: 0.0001, "Y axis should not change during horizontal mirroring")
        XCTAssertEqual(mirroredRect!.width, unmirroredRect!.width, accuracy: 0.0001)
        XCTAssertEqual(mirroredRect!.height, unmirroredRect!.height, accuracy: 0.0001)
    }
    
    // MARK: - Helpers
    
    private func buffer(from image: CGImage) throws -> CVPixelBuffer {
        let width = image.width
        let height = image.height
        
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CVPixelBuffer"])
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }
        
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
    
    private func createSolidPixelBuffer(width: Int, height: Int, color: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let pixelBuffer = buffer else { throw NSError(domain: "Test", code: -1) }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, Int32(color), CVPixelBufferGetDataSize(pixelBuffer))
        }
        return pixelBuffer
    }
}