import Foundation
import ImageIO
import CoreVideo
@preconcurrency import Accelerate
import VitalLensInference

/// A high-performance image processor using the Accelerate framework (vImage).
/// It handles cropping, scaling, format conversion, rotation, and reflection efficiently.
public final class ImageProcessor: @unchecked Sendable {
    
    // Unified buffers
    private var scaledYBuffer = vImage_Buffer()
    private var scaledUVBuffer = vImage_Buffer()
    private var argbBuffer1 = vImage_Buffer()
    private var argbBuffer2 = vImage_Buffer()
    private var finalRGBBuffer = vImage_Buffer()
    
    /// Cached conversion info for YpCbCr -> ARGB
    private var conversionInfo: vImage_YpCbCrToARGB?
    
    /// Track the current buffer size to detect when we need to re-allocate
    private var currentTargetSize: Int = 0
    
    public init() {
        initConversionInfo()
    }
    
    deinit {
        freeBuffers()
    }
    
    // MARK: - Main Processing Functions
    
    /// Processes a video frame for the remote API: Crops, ccales, rotates, reflects, and converts to RGB data.
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
        
        // Extract and standardize to ARGB in argbBuffer1
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            try extractBiPlanarYUV(pixelBuffer, roi: rawROI, size: targetSize, destARGB: &argbBuffer1)
        } else if format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB {
            try extractBGRA(pixelBuffer, roi: rawROI, size: targetSize, destARGB: &argbBuffer1)
        } else {
            throw VitalLensError.processingError("Unsupported pixel format: \(format)")
        }
        
        // Apply rotation and reflection into argbBuffer2
        try applyRotationAndReflection(source: &argbBuffer1, dest: &argbBuffer2, orientation: orientation, isMirrored: isMirrored)
        
        // Convert finalized ARGB to RGB
        let error = vImageConvert_ARGB8888toRGB888(&argbBuffer2, &finalRGBBuffer, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { throw VitalLensError.processingError("vImage ARGB->RGB failed: \(error)") }
        
        return Data(bytes: finalRGBBuffer.data, count: targetSize * targetSize * 3)
    }

    /// Optimized pipeline for Local CoreML. Outputs a CVPixelBuffer (kCVPixelFormatType_32ARGB).
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
        
        // Extract and standardize to ARGB in argbBuffer1
        try extractBiPlanarYUV(pixelBuffer, roi: rawROI, size: targetSize, destARGB: &argbBuffer1)
        
        // Prepare output pixel buffer
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
        
        // Deposit directly into the target pixel buffer
        try applyRotationAndReflection(source: &argbBuffer1, dest: &destVImage, orientation: orientation, isMirrored: isMirrored)
        
        return destBuffer
    }
    
    // MARK: - Extraction Helpers
    
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
        
        // Scale to destination
        var error = vImageScale_ARGB8888(&sourceBuffer, &destARGB, nil, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { throw VitalLensError.processingError("vImage Scale BGRA failed") }
        
        // Ensure format is ARGB. If BGRA, permute channels in place: B(0)->A(3), G(1)->R(2), R(2)->G(1), A(3)->B(0)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if format == kCVPixelFormatType_32BGRA {
            error = vImagePermuteChannels_ARGB8888(&destARGB, &destARGB, [3, 2, 1, 0], vImage_Flags(kvImageNoFlags))
            guard error == kvImageNoError else { throw VitalLensError.processingError("vImage Permute BGRA->ARGB failed") }
        }
    }
    
    // MARK: - Transformation Helpers

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
    
    // MARK: - Memory Management
    
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
}