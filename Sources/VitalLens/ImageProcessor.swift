import Foundation
import CoreVideo
@preconcurrency import Accelerate
import VitalLensCore

/// A high-performance image processor using the Accelerate framework (vImage).
/// It handles cropping, scaling, and format conversion (YUV/BGRA -> RGB) efficiently.
final class ImageProcessor: @unchecked Sendable {
    
    // MARK: - Reusable Buffers
    // We hold these to avoid re-allocating memory every frame (30fps).
    
    /// Intermediate buffer for Scaled Y plane (Device)
    private var scaledYBuffer = vImage_Buffer()
    /// Intermediate buffer for Scaled UV plane (Device)
    private var scaledUVBuffer = vImage_Buffer()
    /// Intermediate buffer for Scaled ARGB (Device & Simulator)
    private var scaledARGBBuffer = vImage_Buffer()
    /// Final buffer for RGB (API Input)
    private var finalRGBBuffer = vImage_Buffer()
    
    /// Cached conversion info for YpCbCr -> ARGB
    private var conversionInfo: vImage_YpCbCrToARGB?
    
    /// Track the current buffer size to detect when we need to re-allocate
    private var currentTargetSize: Int = 0
    
    init() {
        initConversionInfo()
    }
    
    deinit {
        freeBuffers()
    }
    
    /// Processes a video frame: Crops to ROI, Scales to target, Converts to RGB Data.
    ///
    /// - Parameters:
    ///   - pixelBuffer: Source CVPixelBuffer (NV12 on Device, BGRA on Simulator).
    ///   - roi: Normalized ROI (0.0-1.0). Top-Left origin.
    ///   - targetSize: Output dimension (e.g. 40).
    /// - Returns: Raw RGB bytes (flat array) wrapped in Data.
    func process(
        pixelBuffer: CVPixelBuffer,
        roi: CGRect,
        targetSize: Int
    ) throws -> Data {
        
        // 1. Prepare buffers if target size changed
        if targetSize != currentTargetSize {
            freeBuffers()
            try allocateBuffers(size: targetSize)
            currentTargetSize = targetSize
        }
        
        // 2. Lock Base Address
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            return try processBiPlanarYUV(pixelBuffer, roi: roi, size: targetSize)
        } else if format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB {
            return try processBGRA(pixelBuffer, roi: roi, size: targetSize)
        } else {
            throw VitalLensError.processingError("Unsupported pixel format: \(format)")
        }
    }
    
    // MARK: - Processing Pipelines
    
    private func processBiPlanarYUV(_ pixelBuffer: CVPixelBuffer, roi: CGRect, size: Int) throws -> Data {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // 1. Calculate Crop Rects (Y Plane)
        let cropX = Int(roi.origin.x * CGFloat(width))
        let cropY = Int(roi.origin.y * CGFloat(height))
        let cropW = Int(roi.width * CGFloat(width))
        let cropH = Int(roi.height * CGFloat(height))
        
        // Validation
        guard cropX >= 0, cropY >= 0, cropX + cropW <= width, cropY + cropH <= height else {
            throw VitalLensError.processingError("ROI out of bounds")
        }
        
        // 2. Scale Y Plane
        // We create a vImage_Buffer pointing DIRECTLY to the CVPixelBuffer memory (zero copy crop)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            throw VitalLensError.processingError("Could not access Y plane")
        }
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let yOffset = cropY * yBytesPerRow + cropX
        
        var sourceY = vImage_Buffer(
            data: yBase.advanced(by: yOffset),
            height: vImagePixelCount(cropH),
            width: vImagePixelCount(cropW),
            rowBytes: yBytesPerRow
        )
        
        // Scale Y -> scaledYBuffer
        var error = vImageScale_Planar8(&sourceY, &scaledYBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else { throw VitalLensError.processingError("vImage Scale Y failed: \(error)") }
        
        // 3. Scale UV Plane
        // UV plane is half resolution
        guard let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw VitalLensError.processingError("Could not access UV plane")
        }
        let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        // Note: UV is interleaved, 2 bytes per pixel, but half width/height
        let uvOffset = (cropY / 2) * uvBytesPerRow + (cropX & ~1) // Ensure even X alignment
        
        var sourceUV = vImage_Buffer(
            data: uvBase.advanced(by: uvOffset),
            height: vImagePixelCount(cropH / 2),
            width: vImagePixelCount(cropW / 2),
            rowBytes: uvBytesPerRow
        )
        
        // Scale UV -> scaledUVBuffer
        error = vImageScale_CbCr8(&sourceUV, &scaledUVBuffer, nil, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { throw VitalLensError.processingError("vImage Scale UV failed: \(error)") }
        
        // 4. Convert Y+UV -> ARGB
        guard var info = conversionInfo else { throw VitalLensError.processingError("Conversion info missing") }
        error = vImageConvert_420Yp8_CbCr8ToARGB8888(
            &scaledYBuffer,
            &scaledUVBuffer,
            &scaledARGBBuffer,
            &info,
            nil,
            255,
            vImage_Flags(kvImageNoFlags)
        )
        guard error == kvImageNoError else { throw VitalLensError.processingError("vImage YUV->ARGB failed: \(error)") }
        
        // 5. Convert ARGB -> RGB (Drop Alpha)
        // Note: The API expects RGB interleaved.
        // vImageConvert_ARGB8888toRGB888 automatically handles the channel drop.
        error = vImageConvert_ARGB8888toRGB888(
            &scaledARGBBuffer,
            &finalRGBBuffer,
            vImage_Flags(kvImageNoFlags)
        )
        guard error == kvImageNoError else { throw VitalLensError.processingError("vImage ARGB->RGB failed: \(error)") }
        
        // 6. Copy to Data
        return Data(bytes: finalRGBBuffer.data, count: size * size * 3)
    }
    
    private func processBGRA(_ pixelBuffer: CVPixelBuffer, roi: CGRect, size: Int) throws -> Data {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // 1. Calculate Crop Rects
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
        let offset = cropY * bytesPerRow + cropX * 4
        
        var sourceBuffer = vImage_Buffer(
            data: base.advanced(by: offset),
            height: vImagePixelCount(cropH),
            width: vImagePixelCount(cropW),
            rowBytes: bytesPerRow
        )
        
        // 2. Scale to ARGB (Reusing scaledARGBBuffer)
        let error = vImageScale_ARGB8888(&sourceBuffer, &scaledARGBBuffer, nil, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { throw VitalLensError.processingError("vImage Scale BGRA failed") }
        
        // 3. Convert BGRA/ARGB -> RGB
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if format == kCVPixelFormatType_32BGRA {
            vImageConvert_BGRA8888toRGB888(&scaledARGBBuffer, &finalRGBBuffer, vImage_Flags(kvImageNoFlags))
        } else {
            vImageConvert_ARGB8888toRGB888(&scaledARGBBuffer, &finalRGBBuffer, vImage_Flags(kvImageNoFlags))
        }
        
        return Data(bytes: finalRGBBuffer.data, count: size * size * 3)
    }
    
    // MARK: - Helper Methods
    
    private func initConversionInfo() {
        var pixelRange = vImage_YpCbCrPixelRange(
            Yp_bias: 16, CbCr_bias: 128,
            YpRangeMax: 235, CbCrRangeMax: 240,
            YpMax: 235, YpMin: 16,
            CbCrMax: 240, CbCrMin: 16
        )
        var info = vImage_YpCbCrToARGB()
        
        // This force-unwrap is safe because the symbol is a constant defined by Accelerate.
        // @preconcurrency import above suppresses strict check errors.
        vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_601_4!,
            &pixelRange,
            &info,
            kvImage420Yp8_CbCr8,
            kvImageARGB8888,
            vImage_Flags(kvImageNoFlags)
        )
        self.conversionInfo = info
    }
    
    private func allocateBuffers(size: Int) throws {
        // Y Buffer: size * size * 1 byte
        try alloc(&scaledYBuffer, w: size, h: size, bpp: 1)
        
        // UV Buffer: (size/2) * (size/2) * 2 bytes
        // Note: UV is interleaved (Cb, Cr), so width is size/2, but bytes per pixel is 2.
        // effectively rowBytes = size.
        try alloc(&scaledUVBuffer, w: size/2, h: size/2, bpp: 2)
        
        // ARGB Buffer: size * size * 4 bytes
        try alloc(&scaledARGBBuffer, w: size, h: size, bpp: 4)
        
        // RGB Buffer: size * size * 3 bytes
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
        if let d = scaledARGBBuffer.data { free(d); scaledARGBBuffer.data = nil }
        if let d = finalRGBBuffer.data { free(d); finalRGBBuffer.data = nil }
    }
}