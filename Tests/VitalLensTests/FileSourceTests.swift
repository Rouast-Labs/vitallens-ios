import XCTest
import AVFoundation
import CoreVideo
@testable import VitalLens

final class FileSourceTests: XCTestCase {
    
    // MARK: - Integration Tests
    
    func testInit_WithNonExistentFile_ThrowsError() async {
        do {
            let _ = try await FileSource.from(url: URL(fileURLWithPath: "/path/to/nowhere.mp4"))
            XCTFail("Should have thrown error for missing file")
        } catch {
        }
    }
    
    func testGeneratedVideo_Properties() async throws {
        let url = try await createTemporaryVideoFile()
        defer { try? FileManager.default.removeItem(at: url) }
        
        let source = try await FileSource.from(url: url)
        
        XCTAssertEqual(source.naturalSize.width, 128, accuracy: 1.0)
        XCTAssertEqual(source.naturalSize.height, 128, accuracy: 1.0)
        XCTAssertGreaterThan(source.nominalFrameRate, 20.0)
        XCTAssertEqual(source.orientation, .up)
    }
    
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
                
                XCTAssertEqual(format, kCVPixelFormatType_32BGRA, "Output format should be BGRA")
                XCTAssertEqual(width, 128)
                XCTAssertEqual(height, 128)
                firstFrameChecked = true
            }
        }
        
        XCTAssertEqual(frameCount, 30)
    }
    
    func testReadingSpeed() async throws {
        let url = try await createTemporaryVideoFile()
        defer { try? FileManager.default.removeItem(at: url) }
        
        let source = try await FileSource.from(url: url)
        
        let start = Date()
        var count = 0
        for await _ in source.frames() {
            count += 1
        }
        let duration = Date().timeIntervalSince(start)
        
        XCTAssertEqual(count, 30)
        XCTAssertLessThan(duration, 2.0) 
    }

    func testCancellationStopsReading() async throws {
        let url = try await createTemporaryVideoFile()
        defer { try? FileManager.default.removeItem(at: url) }
        
        let source = try await FileSource.from(url: url)
        
        var count = 0
        for await _ in source.frames() {
            count += 1
            if count == 5 { break }
        }
        
        XCTAssertEqual(count, 5)
    }

    // MARK: - Test Data Generation Helpers
    
    private func createTemporaryVideoFile() async throws -> URL {
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
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw writer.error ?? NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Writer failed unexpectedly"])
                }
                try await Task.sleep(nanoseconds: 10_000_000)
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
                pixelStart[0] = b
                pixelStart[1] = g
                pixelStart[2] = r
                pixelStart[3] = 255
            }
        }
        
        return pixelBuffer
    }
}