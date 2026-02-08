import XCTest
import CoreVideo
import Accelerate
@testable import VitalLens
@testable import VitalLensCore

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
    
    // MARK: - BGRA Tests (Simulator Path)
    
    func testProcessBGRA_SolidRed_ReturnsCorrectRGB() throws {
        // 1. Create a 100x100 solid Red buffer (BGRA)
        // Red in BGRA is: B=0, G=0, R=255, A=255
        let buffer = try createBGRAPixelBuffer(width: 100, height: 100, r: 255, g: 0, b: 0)
        
        // 2. Process full frame to 10x10
        let targetSize = 10
        let data = try processor.process(
            pixelBuffer: buffer,
            roi: CGRect(x: 0, y: 0, width: 1, height: 1),
            targetSize: targetSize
        )
        
        // 3. Verify Size
        let expectedBytes = targetSize * targetSize * 3 // RGB
        XCTAssertEqual(data.count, expectedBytes, "Output data size should be width * height * 3")
        
        // 4. Verify Pixels (Expect R=255, G=0, B=0)
        // Check the first pixel
        XCTAssertEqual(data[0], 255, "Red channel should be 255")
        XCTAssertEqual(data[1], 0, "Green channel should be 0")
        XCTAssertEqual(data[2], 0, "Blue channel should be 0")
        
        // Check the last pixel
        let lastIdx = expectedBytes - 3
        XCTAssertEqual(data[lastIdx], 255, "Red channel should be 255")
        XCTAssertEqual(data[lastIdx+1], 0, "Green channel should be 0")
        XCTAssertEqual(data[lastIdx+2], 0, "Blue channel should be 0")
    }
    
    func testProcessBGRA_QuadrantROI_CropsCorrectly() throws {
        // 1. Create 100x100 buffer with 4 quadrants:
        // TL: Red, TR: Green
        // BL: Blue, BR: White
        let buffer = try createQuadrantBGRAPixelBuffer(width: 100, height: 100)
        
        let targetSize = 10
        
        // 2. Crop Top-Right (Should be Green: 0, 255, 0)
        // ROI: x=0.5, y=0.0, w=0.5, h=0.5
        let greenData = try processor.process(
            pixelBuffer: buffer,
            roi: CGRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5),
            targetSize: targetSize
        )
        
        // Sample center of output to avoid edge interpolation artifacts
        let midIndex = (targetSize * targetSize / 2) * 3
        XCTAssertEqual(greenData[midIndex], 0, "TR Crop R should be 0")
        XCTAssertEqual(greenData[midIndex+1], 255, "TR Crop G should be 255")
        XCTAssertEqual(greenData[midIndex+2], 0, "TR Crop B should be 0")
        
        // 3. Crop Bottom-Left (Should be Blue: 0, 0, 255)
        // ROI: x=0.0, y=0.5, w=0.5, h=0.5
        let blueData = try processor.process(
            pixelBuffer: buffer,
            roi: CGRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5),
            targetSize: targetSize
        )
        
        XCTAssertEqual(blueData[midIndex], 0, "BL Crop R should be 0")
        XCTAssertEqual(blueData[midIndex+1], 0, "BL Crop G should be 0")
        XCTAssertEqual(blueData[midIndex+2], 255, "BL Crop B should be 255")
    }
    
    // MARK: - YUV Tests (Device Path)
    
    func testProcessYUV_SolidColor_ReturnsCorrectSize() throws {
        // 1. Create a 100x100 YUV buffer (Solid Gray)
        // Y=128, U=128, V=128
        let buffer = try createYUVPixelBuffer(width: 100, height: 100, y: 128, u: 128, v: 128)
        
        // 2. Process
        let targetSize = 40
        let data = try processor.process(
            pixelBuffer: buffer,
            roi: CGRect(x: 0, y: 0, width: 1, height: 1),
            targetSize: targetSize
        )
        
        // 3. Verify Size
        XCTAssertEqual(data.count, targetSize * targetSize * 3)
        
        // 4. Verify Color (Approximate)
        // Y=128, U=128, V=128 roughly maps to RGB(128, 128, 128) +/- conversion math
        // We just check bounds to ensure it processed valid data and isn't garbage/empty
        let r = data[0]
        XCTAssertGreaterThan(r, 120)
        XCTAssertLessThan(r, 136)
    }
    
    // MARK: - Error Handling
    
    func testProcess_OutOfBoundsROI_ThrowsError() throws {
        let buffer = try createBGRAPixelBuffer(width: 100, height: 100, r: 0, g: 0, b: 0)
        
        // ROI completely outside
        let badROI = CGRect(x: 1.1, y: 0, width: 0.5, height: 0.5)
        
        XCTAssertThrowsError(try processor.process(pixelBuffer: buffer, roi: badROI, targetSize: 40)) { error in
            guard let vlError = error as? VitalLensError,
                  case .processingError(let msg) = vlError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            XCTAssertTrue(msg.contains("out of bounds"))
        }
    }
    
    // MARK: - Helpers
    
    private func createBGRAPixelBuffer(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
            throw VitalLensError.processingError("Failed to create pixel buffer")
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return pixelBuffer }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        // Fill pixels
        for y in 0..<height {
            let rowStart = baseAddress.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixelStart = rowStart.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
                pixelStart[0] = b // Blue
                pixelStart[1] = g // Green
                pixelStart[2] = r // Red
                pixelStart[3] = 255 // Alpha
            }
        }
        
        return pixelBuffer
    }
    
    private func createQuadrantBGRAPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = buffer!
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return pixelBuffer }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        let midX = width / 2
        let midY = height / 2
        
        for y in 0..<height {
            let rowStart = baseAddress.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixelStart = rowStart.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
                
                if x < midX && y < midY { // TL: Red
                    pixelStart[0] = 0; pixelStart[1] = 0; pixelStart[2] = 255
                } else if x >= midX && y < midY { // TR: Green
                    pixelStart[0] = 0; pixelStart[1] = 255; pixelStart[2] = 0
                } else if x < midX && y >= midY { // BL: Blue
                    pixelStart[0] = 255; pixelStart[1] = 0; pixelStart[2] = 0
                } else { // BR: White
                    pixelStart[0] = 255; pixelStart[1] = 255; pixelStart[2] = 255
                }
                pixelStart[3] = 255 // Alpha
            }
        }
        return pixelBuffer
    }
    
    private func createYUVPixelBuffer(width: Int, height: Int, y: UInt8, u: UInt8, v: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange = '420v'
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        let pixelBuffer = buffer!
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        // Plane 0: Y
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            for r in 0..<height {
                let rowStart = yBase.advanced(by: r * yBytesPerRow)
                memset(rowStart, Int32(y), width)
            }
        }
        
        // Plane 1: UV (Interleaved)
        if let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let halfHeight = height / 2
            let halfWidth = width / 2
            
            for r in 0..<halfHeight {
                let rowStart = uvBase.advanced(by: r * uvBytesPerRow).assumingMemoryBound(to: UInt8.self)
                for c in 0..<halfWidth {
                    rowStart[c * 2] = u     // Cb
                    rowStart[c * 2 + 1] = v // Cr
                }
            }
        }
        
        return pixelBuffer
    }
}