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
        // Red in BGRA is: B=0, G=0, R=255
        let buffer = try createBGRAPixelBuffer(width: 100, height: 100, r: 255, g: 0, b: 0)
        
        let targetSize = 10
        let data = try processor.process(
            pixelBuffer: buffer,
            roi: CGRect(x: 0, y: 0, width: 1, height: 1),
            targetSize: targetSize
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
            targetSize: targetSize
        )
        
        let midIndex = (targetSize * targetSize / 2) * 3
        XCTAssertEqual(greenData[midIndex], 0)
        XCTAssertEqual(greenData[midIndex+1], 255)
        XCTAssertEqual(greenData[midIndex+2], 0)
    }
    
    // MARK: - YUV Tests (Device Path)
    
    func testProcessYUV_SolidColor_ReturnsCorrectSize() throws {
        // Solid Gray
        let buffer = try createYUVPixelBuffer(width: 100, height: 100, y: 128, u: 128, v: 128)
        
        let targetSize = 40
        let data = try processor.process(
            pixelBuffer: buffer,
            roi: CGRect(x: 0, y: 0, width: 1, height: 1),
            targetSize: targetSize
        )
        
        XCTAssertEqual(data.count, targetSize * targetSize * 3)
        // Basic check to ensure not empty/black
        XCTAssertGreaterThan(data[0], 100)
    }
    
    // MARK: - Robustness & Edge Cases
    
    func testProcess_DynamicResizing_DoesNotCrash() throws {
        let buffer = try createBGRAPixelBuffer(width: 100, height: 100, r: 255, g: 0, b: 0)
        
        // 1. Process at size 40
        _ = try processor.process(pixelBuffer: buffer, roi: .init(x: 0, y: 0, width: 1, height: 1), targetSize: 40)
        
        // 2. Resize to 20 (Triggers freeBuffers -> allocateBuffers logic)
        let dataSmall = try processor.process(pixelBuffer: buffer, roi: .init(x: 0, y: 0, width: 1, height: 1), targetSize: 20)
        
        XCTAssertEqual(dataSmall.count, 20 * 20 * 3)
        
        // 3. Resize UP to 60
        let dataLarge = try processor.process(pixelBuffer: buffer, roi: .init(x: 0, y: 0, width: 1, height: 1), targetSize: 60)
        
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
        
        XCTAssertThrowsError(try processor.process(pixelBuffer: validBuffer, roi: .init(x: 0, y: 0, width: 1, height: 1), targetSize: 40)) { error in
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
        
        XCTAssertThrowsError(try processor.process(pixelBuffer: buffer, roi: badROI, targetSize: 40))
    }
    
    // MARK: - Helpers
    
    private func createBGRAPixelBuffer(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = buffer!
        
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
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = buffer!
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
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        let pixelBuffer = buffer!
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
}