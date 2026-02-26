import Foundation
import ImageIO
import CoreVideo
@preconcurrency import Accelerate
import VitalLensInference

#if canImport(UIKit)
import UIKit
#endif

/// A high-performance image processor using the Accelerate framework (vImage).
/// It handles cropping, scaling, format conversion, rotation, and reflection efficiently.
public final class ImageProcessor: @unchecked Sendable {
    
    private var scaledYBuffer = vImage_Buffer()
    private var scaledUVBuffer = vImage_Buffer()
    private var argbBuffer1 = vImage_Buffer()
    private var argbBuffer2 = vImage_Buffer()
    private var finalRGBBuffer = vImage_Buffer()

    public var lastProcessedCGImage: CGImage?
    public var debugMode: Bool

    /// Cached conversion info for YpCbCr -> ARGB
    private var conversionInfo: vImage_YpCbCrToARGB?
    
    /// Track the current buffer size to detect when we need to re-allocate
    private var currentTargetSize: Int = 0
    
    /// Initializes a new ImageProcessor.
    ///
    /// - Parameter debugMode: If true, caches a `CGImage` of the final crop for debugging.
    public init(debugMode: Bool = false) {
        self.debugMode = debugMode
        initConversionInfo()
    }
    
    deinit {
        freeBuffers()
    }
    
    /// Processes a video frame for the remote API.
    /// It crops, scales, rotates, reflects, and converts the pixel buffer to packed RGB data.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The raw camera frame.
    ///   - roi: The normalized Region of Interest (0.0-1.0).
    ///   - targetSize: The required width and height for the output image.
    ///   - orientation: The original orientation of the frame.
    ///   - isMirrored: Whether the frame is horizontally mirrored.
    /// - Returns: Flattened RGB `Data` ready for network transmission.
    /// - Throws: `VitalLensError` if processing or memory allocation fails.
    public func process(
        pixelBuffer: CVPixelBuffer,
        roi: CGRect,
        targetSize: Int,
        orientation: CGImagePropertyOrientation,
        isMirrored: Bool
    ) throws -> Data {
        
        try checkAndReallocate(targetSize: targetSize)
        
        let rawROI = roi.mappedToRaw(orientation: orientation, isMirrored: isMirrored)
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            try extractBiPlanarYUV(pixelBuffer, roi: rawROI, size: targetSize, destARGB: &argbBuffer1)
        } else if format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB {
            try extractBGRA(pixelBuffer, roi: rawROI, size: targetSize, destARGB: &argbBuffer1)
        } else {
            throw VitalLensError.processingError("Unsupported pixel format: \(format)")
        }
        
        try applyRotationAndReflection(source: &argbBuffer1, dest: &argbBuffer2, orientation: orientation, isMirrored: isMirrored)
        
        if debugMode {
            self.lastProcessedCGImage = createCGImage(from: argbBuffer2)
        }

        let error = vImageConvert_ARGB8888toRGB888(&argbBuffer2, &finalRGBBuffer, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { throw VitalLensError.processingError("vImage ARGB->RGB failed: \(error)") }
        
        return Data(bytes: finalRGBBuffer.data, count: targetSize * targetSize * 3)
    }

    /// An optimized pipeline designed for local CoreML inference.
    /// Extracts the ROI and outputs a 32ARGB `CVPixelBuffer`.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The raw camera frame (must be YpCbCr BiPlanar).
    ///   - roi: The normalized Region of Interest (0.0-1.0).
    ///   - targetSize: The required width and height for the output image.
    ///   - orientation: The original orientation of the frame.
    ///   - isMirrored: Whether the frame is horizontally mirrored.
    /// - Returns: A cropped and rotated `CVPixelBuffer` in 32ARGB format.
    /// - Throws: `VitalLensError` if processing or memory allocation fails.
    public func processToPixelBuffer(
        pixelBuffer: CVPixelBuffer,
        roi: CGRect,
        targetSize: Int,
        orientation: CGImagePropertyOrientation,
        isMirrored: Bool
    ) throws -> CVPixelBuffer {
        
        try checkAndReallocate(targetSize: targetSize)

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
              format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            throw VitalLensError.processingError("Unsupported format for optimized CoreML path: \(format)")
        }

        let rawROI = roi.mappedToRaw(orientation: orientation, isMirrored: isMirrored)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        try extractBiPlanarYUV(pixelBuffer, roi: rawROI, size: targetSize, destARGB: &argbBuffer1)
        
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, targetSize, targetSize, kCVPixelFormatType_32ARGB, nil, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let destBuffer = outputPixelBuffer else {
            throw VitalLensError.processingError("Output buffer creation failed")
        }
        
        CVPixelBufferLockBaseAddress(destBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(destBuffer, []) }
        guard let destData = CVPixelBufferGetBaseAddress(destBuffer) else { return destBuffer }
        
        var destVImage = vImage_Buffer(
            data: destData,
            height: vImagePixelCount(targetSize),
            width: vImagePixelCount(targetSize),
            rowBytes: CVPixelBufferGetBytesPerRow(destBuffer)
        )
        
        try applyRotationAndReflection(source: &argbBuffer1, dest: &destVImage, orientation: orientation, isMirrored: isMirrored)
        
        return destBuffer
    }
    
    /// Extracts a cropped region from a YUV BiPlanar buffer, scales it, and converts it to ARGB.
    private func extractBiPlanarYUV(_ pixelBuffer: CVPixelBuffer, roi: CGRect, size: Int, destARGB: inout vImage_Buffer) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        let cropX = Int(roi.origin.x * CGFloat(width))
        let cropY = Int(roi.origin.y * CGFloat(height))
        let cropW = Int(roi.width * CGFloat(width))
        let cropH = Int(roi.height * CGFloat(height))
        
        guard cropX >= 0, cropY >= 0, cropX + cropW <= width, cropY + cropH <= height else {
            throw VitalLensError.processingError("ROI out of bounds")
        }
        
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw VitalLensError.processingError("Plane access failed")
        }
        
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        
        var sourceY = vImage_Buffer(data: yBase.advanced(by: cropY * yBytesPerRow + cropX), height: vImagePixelCount(cropH), width: vImagePixelCount(cropW), rowBytes: yBytesPerRow)
        var sourceUV = vImage_Buffer(data: uvBase.advanced(by: (cropY / 2) * uvBytesPerRow + (cropX & ~1)), height: vImagePixelCount(cropH / 2), width: vImagePixelCount(cropW / 2), rowBytes: uvBytesPerRow)
        
        var error = vImageScale_Planar8(&sourceY, &scaledYBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else { throw VitalLensError.processingError("vImage Scale Y failed") }
        
        error = vImageScale_CbCr8(&sourceUV, &scaledUVBuffer, nil, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { throw VitalLensError.processingError("vImage Scale UV failed") }
        
        guard var info = conversionInfo else { throw VitalLensError.processingError("Conversion info missing") }
        error = vImageConvert_420Yp8_CbCr8ToARGB8888(&scaledYBuffer, &scaledUVBuffer, &destARGB, &info, nil, 255, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { throw VitalLensError.processingError("vImage YUV->ARGB failed") }
    }
    
    /// Extracts a cropped region from a BGRA/ARGB buffer and scales it.
    private func extractBGRA(_ pixelBuffer: CVPixelBuffer, roi: CGRect, size: Int, destARGB: inout vImage_Buffer) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        let cropX = Int(roi.origin.x * CGFloat(width))
        let cropY = Int(roi.origin.y * CGFloat(height))
        let cropW = Int(roi.width * CGFloat(width))
        let cropH = Int(roi.height * CGFloat(height))
        
        guard cropX >= 0, cropY >= 0, cropX + cropW <= width, cropY + cropH <= height else {
            throw VitalLensError.processingError("ROI out of bounds")
        }
        
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw VitalLensError.processingError("Could not access pixels")
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var sourceBuffer = vImage_Buffer(data: base.advanced(by: cropY * bytesPerRow + cropX * 4), height: vImagePixelCount(cropH), width: vImagePixelCount(cropW), rowBytes: bytesPerRow)
        
        var error = vImageScale_ARGB8888(&sourceBuffer, &destARGB, nil, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { throw VitalLensError.processingError("vImage Scale BGRA failed") }
        
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if format == kCVPixelFormatType_32BGRA {
            error = vImagePermuteChannels_ARGB8888(&destARGB, &destARGB, [3, 2, 1, 0], vImage_Flags(kvImageNoFlags))
            guard error == kvImageNoError else { throw VitalLensError.processingError("vImage Permute BGRA->ARGB failed") }
        }
    }
    
    /// Applies 90-degree rotations and horizontal reflections based on metadata.
    private func applyRotationAndReflection(source: inout vImage_Buffer, dest: inout vImage_Buffer, orientation: CGImagePropertyOrientation, isMirrored: Bool) throws {
        let rotation = rotationConstant(for: orientation)
        var bgColor: [UInt8] = [0,0,0,0]
        
        if isMirrored {
            if rotation == 0 {
                let error = vImageHorizontalReflect_ARGB8888(&source, &dest, vImage_Flags(kvImageNoFlags))
                guard error == kvImageNoError else { throw VitalLensError.processingError("Reflect failed") }
            } else {
                let error = vImageRotate90_ARGB8888(&source, &dest, rotation, &bgColor, vImage_Flags(kvImageNoFlags))
                guard error == kvImageNoError else { throw VitalLensError.processingError("Rotate failed") }
                let error2 = vImageHorizontalReflect_ARGB8888(&dest, &dest, vImage_Flags(kvImageNoFlags))
                guard error2 == kvImageNoError else { throw VitalLensError.processingError("Reflect failed") }
            }
        } else {
            if rotation == 0 {
                let error = vImageCopyBuffer(&source, &dest, 4, vImage_Flags(kvImageNoFlags))
                guard error == kvImageNoError else { throw VitalLensError.processingError("Copy failed") }
            } else {
                let error = vImageRotate90_ARGB8888(&source, &dest, rotation, &bgColor, vImage_Flags(kvImageNoFlags))
                guard error == kvImageNoError else { throw VitalLensError.processingError("Rotate failed") }
            }
        }
    }

    private func rotationConstant(for orientation: CGImagePropertyOrientation) -> UInt8 {
        switch orientation {
        case .left, .leftMirrored: return 1
        case .down, .downMirrored: return 2
        case .right, .rightMirrored: return 3
        default: return 0
        }
    }
        
    private func checkAndReallocate(targetSize: Int) throws {
        if targetSize != currentTargetSize {
            freeBuffers()
            try allocateBuffers(size: targetSize)
            currentTargetSize = targetSize
        }
    }
    
    private func allocateBuffers(size: Int) throws {
        try alloc(&scaledYBuffer, w: size, h: size, bpp: 1)
        try alloc(&scaledUVBuffer, w: size/2, h: size/2, bpp: 2)
        try alloc(&argbBuffer1, w: size, h: size, bpp: 4)
        try alloc(&argbBuffer2, w: size, h: size, bpp: 4)
        try alloc(&finalRGBBuffer, w: size, h: size, bpp: 3)
    }
    
    private func alloc(_ buffer: inout vImage_Buffer, w: Int, h: Int, bpp: Int) throws {
        let rowBytes = w * bpp
        let dataSize = rowBytes * h
        guard let data = malloc(dataSize) else {
            throw VitalLensError.processingError("Memory allocation failed")
        }
        buffer.data = data
        buffer.width = vImagePixelCount(w)
        buffer.height = vImagePixelCount(h)
        buffer.rowBytes = rowBytes
    }
    
    private func freeBuffers() {
        if let d = scaledYBuffer.data { free(d); scaledYBuffer.data = nil }
        if let d = scaledUVBuffer.data { free(d); scaledUVBuffer.data = nil }
        if let d = argbBuffer1.data { free(d); argbBuffer1.data = nil }
        if let d = argbBuffer2.data { free(d); argbBuffer2.data = nil }
        if let d = finalRGBBuffer.data { free(d); finalRGBBuffer.data = nil }
    }
    
    private func initConversionInfo() {
        var pixelRange = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        var info = vImage_YpCbCrToARGB()
        vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4!, &pixelRange, &info, kvImage420Yp8_CbCr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
        self.conversionInfo = info
    }

    /// Creates a debug CGImage from the intermediate ARGB vImage buffer.
    private func createCGImage(from vBuffer: vImage_Buffer) -> CGImage? {
        var mutableBuffer = vBuffer
        
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
        
        var error = kvImageNoError
        return vImageCreateCGImageFromBuffer(&mutableBuffer, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error)?.takeRetainedValue()
    }
}
