import XCTest
import CoreVideo
import Accelerate
import ImageIO
@testable import VitalLens
@testable import VitalLensInference

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#endif

final class ImageProcessorTests: XCTestCase {
    
    var processor: ImageProcessor!
    
    override func setUp() {
        super.setUp()
        processor = ImageProcessor()
    }
    
    override func tearDown() {
        processor = nil
        super.tearDown()
    }
    
    // MARK: - BGRA Tests (API / Simulator Path)
    
    func testProcessBGRA_SolidRed_ReturnsCorrectRGB() throws {
        // Red in BGRA is: B=0, G=0, R=255
        let buffer = try createBGRAPixelBuffer(width: 100, height: 100, r: 255, g: 0, b: 0)
        
        let targetSize = 10
        let data = try processor.process(
            pixelBuffer: buffer,
            roi: CGRect(x: 0, y: 0, width: 1, height: 1),
            targetSize: targetSize,
            orientation: .up,
            isMirrored: false
        )
        
        XCTAssertEqual(data.count, targetSize * targetSize * 3)
        // Verify R, G, B
        XCTAssertEqual(data[0], 255)
        XCTAssertEqual(data[1], 0)
        XCTAssertEqual(data[2], 0)
    }
    
    func testProcessBGRA_QuadrantROI_CropsCorrectly() throws {
        // Quadrants: TL:Red, TR:Green, BL:Blue, BR:White
        let buffer = try createQuadrantBGRAPixelBuffer(width: 100, height: 100)
        let targetSize = 10
        
        // Crop Top-Right (Should be Green)
        let greenData = try processor.process(
            pixelBuffer: buffer,
            roi: CGRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5),
            targetSize: targetSize,
            orientation: .up,
            isMirrored: false
        )
        
        // Check the middle pixel of the result
        let midIndex = (targetSize * targetSize / 2) * 3
        XCTAssertEqual(greenData[midIndex], 0)
        XCTAssertEqual(greenData[midIndex+1], 255)
        XCTAssertEqual(greenData[midIndex+2], 0)
    }
    
    func testProcessBGRA_OrientationRight_CorrectsToUpright() throws {
        // Create a buffer that is physically "rotated" 90 degrees CW (.right)
        // Raw quadrants: TL:Red, TR:Green, BL:Blue, BR:White
        let rawSidewaysBuffer = try createQuadrantBGRAPixelBuffer(width: 100, height: 100)
        let targetSize = 10
        
        // When we pass .right, the processor applies a 90 CW rotation to correct it.
        // Resulting upright image should be:
        // TL: Blue (was BL)
        // TR: Red (was TL)
        // BL: White (was BR)
        // BR: Green (was TR)
        
        let data = try processor.process(
            pixelBuffer: rawSidewaysBuffer,
            roi: CGRect(x: 0, y: 0, width: 1, height: 1), // Full image
            targetSize: targetSize,
            orientation: .right,
            isMirrored: false
        )
        
        // Check Top-Left pixel (Should be Blue)
        let tlIndex = 0
        XCTAssertEqual(data[tlIndex], 0)
        XCTAssertEqual(data[tlIndex+1], 0)
        XCTAssertEqual(data[tlIndex+2], 255)
        
        // Check Bottom-Left pixel (Should be White)
        let blIndex = ((targetSize - 1) * targetSize) * 3
        XCTAssertEqual(data[blIndex], 255)
        XCTAssertEqual(data[blIndex+1], 255)
        XCTAssertEqual(data[blIndex+2], 255)
    }

    func testProcessBGRA_Mirrored_CorrectsToUnmirrored() throws {
        // Raw quadrants: TL:Red, TR:Green, BL:Blue, BR:White
        let rawMirroredBuffer = try createQuadrantBGRAPixelBuffer(width: 100, height: 100)
        let targetSize = 10
        
        // If we tell the processor it is mirrored, it should flip it horizontally.
        // Resulting unmirrored image should be:
        // TL: Green (was TR)
        // TR: Red (was TL)
        
        let data = try processor.process(
            pixelBuffer: rawMirroredBuffer,
            roi: CGRect(x: 0, y: 0, width: 1, height: 1), // Full image
            targetSize: targetSize,
            orientation: .up,
            isMirrored: true
        )
        
        // Check Top-Left pixel (Should be Green)
        let tlIndex = 0
        XCTAssertEqual(data[tlIndex], 0)
        XCTAssertEqual(data[tlIndex+1], 255)
        XCTAssertEqual(data[tlIndex+2], 0)
        
        // Check Top-Right pixel (Should be Red)
        let trIndex = (targetSize - 1) * 3
        XCTAssertEqual(data[trIndex], 255)
        XCTAssertEqual(data[trIndex+1], 0)
        XCTAssertEqual(data[trIndex+2], 0)
    }

    func testProcessBGRA_WithOrientationAndMirroring_DoesNotCrash() throws {
        let buffer = try createQuadrantBGRAPixelBuffer(width: 100, height: 100)
        let targetSize = 20
        
        // Exercise the vImage rotation and reflection pathways together
        let data = try processor.process(
            pixelBuffer: buffer,
            roi: CGRect(x: 0, y: 0, width: 1, height: 1),
            targetSize: targetSize,
            orientation: .left,
            isMirrored: true
        )
        
        XCTAssertEqual(data.count, targetSize * targetSize * 3)
    }
    
    // MARK: - YUV Tests (API / Device Path)
    
    func testProcessYUV_SolidColor_ReturnsCorrectSize() throws {
        // Solid Gray
        let buffer = try createYUVPixelBuffer(width: 100, height: 100, y: 128, u: 128, v: 128)
        
        let targetSize = 40
        let data = try processor.process(
            pixelBuffer: buffer,
            roi: CGRect(x: 0, y: 0, width: 1, height: 1),
            targetSize: targetSize,
            orientation: .up,
            isMirrored: false
        )
        
        XCTAssertEqual(data.count, targetSize * targetSize * 3)
        // Basic check to ensure not empty/black
        XCTAssertGreaterThan(data[0], 100)
    }
    
    // MARK: - Robustness & Edge Cases
    
    func testProcess_DynamicResizing_DoesNotCrash() throws {
        let buffer = try createBGRAPixelBuffer(width: 100, height: 100, r: 255, g: 0, b: 0)
        
        // 1. Process at size 40
        _ = try processor.process(pixelBuffer: buffer, roi: .init(x: 0, y: 0, width: 1, height: 1), targetSize: 40, orientation: .up, isMirrored: false)
        
        // 2. Resize to 20 (Triggers freeBuffers -> allocateBuffers logic)
        let dataSmall = try processor.process(pixelBuffer: buffer, roi: .init(x: 0, y: 0, width: 1, height: 1), targetSize: 20, orientation: .up, isMirrored: false)
        
        XCTAssertEqual(dataSmall.count, 20 * 20 * 3)
        
        // 3. Resize UP to 60
        let dataLarge = try processor.process(pixelBuffer: buffer, roi: .init(x: 0, y: 0, width: 1, height: 1), targetSize: 60, orientation: .up, isMirrored: false)
        
        XCTAssertEqual(dataLarge.count, 60 * 60 * 3)
    }
    
    func testProcess_UnsupportedFormat_ThrowsError() throws {
        // Use 32RGBA. This is a valid OS format, but our ImageProcessor 
        // explicitly only supports BGRA, ARGB, and BiPlanar YUV.
        let unsupportedFormat = kCVPixelFormatType_32RGBA
        
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, unsupportedFormat, nil, &buffer)
        
        // Ensure the buffer actually exists before testing the processor
        guard status == kCVReturnSuccess, let validBuffer = buffer else {
            print("⚠️ Skipping testProcess_UnsupportedFormat_ThrowsError: CVPixelBufferCreate failed for format \(unsupportedFormat)")
            return
        }
        
        XCTAssertThrowsError(try processor.process(pixelBuffer: validBuffer, roi: .init(x: 0, y: 0, width: 1, height: 1), targetSize: 40, orientation: .up, isMirrored: false)) { error in
            guard let e = error as? VitalLensError, case .processingError(let msg) = e else {
                XCTFail("Wrong error type received: \(error)")
                return
            }
            XCTAssertTrue(msg.contains("Unsupported pixel format"), "Error message should mention format issue. Got: \(msg)")
        }
    }
    
    func testProcess_OutOfBoundsROI_ThrowsError() throws {
        let buffer = try createBGRAPixelBuffer(width: 100, height: 100, r: 0, g: 0, b: 0)
        let badROI = CGRect(x: 1.1, y: 0, width: 0.5, height: 0.5)
        
        XCTAssertThrowsError(try processor.process(pixelBuffer: buffer, roi: badROI, targetSize: 40, orientation: .up, isMirrored: false))
    }

    func testProcess_ReturnsTightlyPackedRGB() throws {
        // Arrange
        let width = 64
        let height = 64
        let targetSize = 40
        // Use solid red for this test
        let pixelBuffer = try createBGRAPixelBuffer(width: width, height: height, r: 255, g: 0, b: 0)
        let roi = CGRect(x: 0, y: 0, width: 1, height: 1) // Full frame
        
        // Act
        let data = try processor.process(pixelBuffer: pixelBuffer, roi: roi, targetSize: targetSize, orientation: .up, isMirrored: false)
        
        // Assert
        let expectedBytes = targetSize * targetSize * 3
        XCTAssertEqual(data.count, expectedBytes, "Output data size must match width * height * 3 exactly")
    }

    // MARK: - Legacy App Support Tests (CoreML Path)
    
    func testProcessToPixelBuffer_FormatAndOrientation() throws {
        // CoreML path REQUIRES YUV input according to the implementation check
        // Let's create a YUV buffer with "Red" (Y=76, U=84, V=255)
        let buffer = try createYUVPixelBuffer(width: 100, height: 100, y: 76, u: 84, v: 255)
        
        // 1. Process with NO rotation
        let outputUp = try processor.processToPixelBuffer(
            pixelBuffer: buffer,
            roi: CGRect(x: 0, y: 0, width: 1, height: 1),
            targetSize: 40,
            orientation: .up,
            isMirrored: false
        )
        
        XCTAssertEqual(CVPixelBufferGetWidth(outputUp), 40)
        XCTAssertEqual(CVPixelBufferGetHeight(outputUp), 40)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(outputUp), kCVPixelFormatType_32ARGB, "Legacy path must return ARGB")
        
        // 2. Process with Rotation (Left)
        let outputLeft = try processor.processToPixelBuffer(
            pixelBuffer: buffer,
            roi: CGRect(x: 0, y: 0, width: 1, height: 1),
            targetSize: 40,
            orientation: .left,
            isMirrored: false
        )
        
        // Verify rotation didn't corrupt dimensions
        XCTAssertEqual(CVPixelBufferGetWidth(outputLeft), 40)
        
        // 3. Process with Mirroring
        let outputMirrored = try processor.processToPixelBuffer(
            pixelBuffer: buffer,
            roi: CGRect(x: 0, y: 0, width: 1, height: 1),
            targetSize: 40,
            orientation: .up,
            isMirrored: true
        )
        XCTAssertNotNil(outputMirrored)
    }
    
    func testProcessToPixelBuffer_UnsupportedInput_Throws() throws {
        // Feed BGRA to the legacy path (which expects YUV)
        let bgraBuffer = try createBGRAPixelBuffer(width: 100, height: 100, r: 255, g: 0, b: 0)
        
        XCTAssertThrowsError(try processor.processToPixelBuffer(
            pixelBuffer: bgraBuffer,
            roi: .init(x: 0, y: 0, width: 1, height: 1),
            targetSize: 40,
            orientation: .up,
            isMirrored: false
        )) { error in
            if let e = error as? VitalLensError, case .processingError(let msg) = e {
                XCTAssertTrue(msg.contains("Unsupported format"), "Should reject non-YUV inputs for this path")
            } else {
                XCTFail("Wrong error: \(error)")
            }
        }
    }

    func testProcess_DebugMode_ControlsCGImageCreation() throws {
        // 1. Test Debug OFF (Default)
        let prodProcessor = ImageProcessor(debugMode: false)
        let buffer1 = createSolidColorBuffer(width: 40, height: 40)
        
        _ = try prodProcessor.process(pixelBuffer: buffer1, roi: CGRect(x: 0, y: 0, width: 1, height: 1), targetSize: 40, orientation: .up, isMirrored: false)
        XCTAssertNil(prodProcessor.lastProcessedCGImage, "CGImage should NOT be created in production mode")
        
        // 2. Test Debug ON
        let debugProcessor = ImageProcessor(debugMode: true)
        let buffer2 = createSolidColorBuffer(width: 40, height: 40)
        
        _ = try debugProcessor.process(pixelBuffer: buffer2, roi: CGRect(x: 0, y: 0, width: 1, height: 1), targetSize: 40, orientation: .up, isMirrored: false)
        XCTAssertNotNil(debugProcessor.lastProcessedCGImage, "CGImage MUST be created in debug mode")
    }
    
    // MARK: - Helpers
    
    private func createBGRAPixelBuffer(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        // Standardize keys for test buffers to ensure compatibility
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CVPixelBuffer"])
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return pixelBuffer }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        for y in 0..<height {
            let rowStart = baseAddress.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixelStart = rowStart.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
                pixelStart[0] = b; pixelStart[1] = g; pixelStart[2] = r; pixelStart[3] = 255
            }
        }
        return pixelBuffer
    }
    
    private func createQuadrantBGRAPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        
        guard let pixelBuffer = buffer else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CVPixelBuffer"])
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let midX = width / 2; let midY = height / 2
        
        for y in 0..<height {
            let rowStart = baseAddress.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixelStart = rowStart.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
                if x < midX && y < midY { pixelStart[0] = 0; pixelStart[1] = 0; pixelStart[2] = 255 } // TL: Red
                else if x >= midX && y < midY { pixelStart[0] = 0; pixelStart[1] = 255; pixelStart[2] = 0 } // TR: Green
                else if x < midX && y >= midY { pixelStart[0] = 255; pixelStart[1] = 0; pixelStart[2] = 0 } // BL: Blue
                else { pixelStart[0] = 255; pixelStart[1] = 255; pixelStart[2] = 255 } // BR: White
                pixelStart[3] = 255
            }
        }
        return pixelBuffer
    }
    
    private func createYUVPixelBuffer(width: Int, height: Int, y: UInt8, u: UInt8, v: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        // Attributes not strictly necessary for YUV test logic but good for consistency
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &buffer
        )
        guard let pixelBuffer = buffer else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CVPixelBuffer"])
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            for r in 0..<height { memset(yBase.advanced(by: r * yBytesPerRow), Int32(y), width) }
        }
        if let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            for r in 0..<height/2 {
                let rowStart = uvBase.advanced(by: r * uvBytesPerRow).assumingMemoryBound(to: UInt8.self)
                for c in 0..<width/2 { rowStart[c * 2] = u; rowStart[c * 2 + 1] = v }
            }
        }
        return pixelBuffer
    }

    private func createSolidColorBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        let pixelBuffer = buffer!
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        
        // Hardcode a fill color (e.g., Red) using CGColor to avoid UIKit/AppKit
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        return pixelBuffer
    }
}