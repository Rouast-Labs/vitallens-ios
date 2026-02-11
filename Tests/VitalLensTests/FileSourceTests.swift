import XCTest
import AVFoundation
import CoreVideo
@testable import VitalLens

final class FileSourceTests: XCTestCase {
    
    // MARK: - Integration Tests
    
    /// Verifies that the source correctly throws an error when the file does not exist.
    func testInit_WithNonExistentFile_ThrowsError() async {
        do {
            let _ = try await FileSource.from(url: URL(fileURLWithPath: "/path/to/nowhere.mp4"))
            XCTFail("Should have thrown error for missing file")
        } catch {
            // Success: Error was thrown
        }
    }
    
    /// Verifies that video metadata (Resolution, FPS) is parsed correctly.
    func testGeneratedVideo_Properties() async throws {
        let url = try await createTemporaryVideoFile()
        defer { try? FileManager.default.removeItem(at: url) }
        
        let source = try await FileSource.from(url: url)
        
        // H.264 encoder usually respects the input dimensions (128x128)
        XCTAssertEqual(source.naturalSize.width, 128, accuracy: 1.0)
        XCTAssertEqual(source.naturalSize.height, 128, accuracy: 1.0)
        
        // Ensure FPS is reasonable (we wrote it at 30 timescale)
        XCTAssertGreaterThan(source.nominalFrameRate, 20.0)

        // Generated video should default to .up
        XCTAssertEqual(source.orientation, .up)
    }
    
    /// Verifies that every frame written to the file can be read back with the correct format.
    func testGeneratedVideo_FrameExtraction() async throws {
        let url = try await createTemporaryVideoFile()
        defer { try? FileManager.default.removeItem(at: url) }
        
        let source = try await FileSource.from(url: url)
        
        var frameCount = 0
        var firstFrameChecked = false
        
        for await bufferWrapper in source.frames() {
            let buffer = bufferWrapper.buffer
            frameCount += 1
            
            if !firstFrameChecked {
                let format = CVPixelBufferGetPixelFormatType(buffer)
                let width = CVPixelBufferGetWidth(buffer)
                let height = CVPixelBufferGetHeight(buffer)
                
                // FileSource explicitly requests BGRA output from the AssetReader
                XCTAssertEqual(format, kCVPixelFormatType_32BGRA, "Output format should be BGRA")
                XCTAssertEqual(width, 128)
                XCTAssertEqual(height, 128)
                firstFrameChecked = true
            }
        }
        
        // We generated exactly 30 frames
        XCTAssertEqual(frameCount, 30)
    }
    
    /// Benchmarks the reading speed to ensure no performance regressions.
    func testReadingSpeed() async throws {
        let url = try await createTemporaryVideoFile()
        defer { try? FileManager.default.removeItem(at: url) }
        
        let source = try await FileSource.from(url: url)
        
        let start = Date()
        var count = 0
        // Consume the stream as fast as possible
        for await _ in source.frames() {
            count += 1
        }
        let duration = Date().timeIntervalSince(start)
        
        XCTAssertEqual(count, 30)
        // 30 frames should be read almost instantly (< 2s even on slow CI)
        XCTAssertLessThan(duration, 2.0) 
    }

    func testCancellationStopsReading() async throws {
        let url = try await createTemporaryVideoFile()
        defer { try? FileManager.default.removeItem(at: url) }
        
        let source = try await FileSource.from(url: url)
        
        var count = 0
        // Consume only 5 frames then break
        for await _ in source.frames() {
            count += 1
            if count == 5 { break }
        }
        
        // If we broke the loop, the AsyncStream continuation should be terminated.
        // The internal AVAssetReader should be cancelled.
        // While we can't easily introspect the private reader, we can assert we didn't crash
        // and that we successfully stopped receiving frames.
        XCTAssertEqual(count, 5)
    }

    // MARK: - Test Data Generation Helpers
    
    /// Generates a temporary H.264 video file at 128x128 resolution.
    /// This resolution is chosen to ensure compatibility with hardware encoders on all platforms.
    private func createTemporaryVideoFile() async throws -> URL {
        let filename = UUID().uuidString + ".mp4"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        
        // Ensure clean state
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
        
        if writer.canAdd(input) {
            writer.add(input)
        } else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add input to writer"])
        }
        
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        let fps: Int32 = 30
        let frameCount = 30
        
        for i in 0..<frameCount {
            // Spin-wait safely for writer readiness to avoid dropping frames
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw writer.error ?? NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Writer failed unexpectedly"])
                }
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
            
            if let buffer = createSolidPixelBuffer(width: 128, height: 128, r: 255, g: 0, b: 0) {
                let time = CMTime(value: Int64(i), timescale: fps)
                adaptor.append(buffer, withPresentationTime: time)
            }
        }
        
        input.markAsFinished()
        await writer.finishWriting()
        
        if writer.status == .failed {
            throw writer.error ?? NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Writer failed at finish"])
        }
        
        return url
    }
    
    private func createSolidPixelBuffer(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        for y in 0..<height {
            let rowStart = baseAddress.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixelStart = rowStart.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
                // BGRA format
                pixelStart[0] = b
                pixelStart[1] = g
                pixelStart[2] = r
                pixelStart[3] = 255 // Alpha
            }
        }
        
        return pixelBuffer
    }
}