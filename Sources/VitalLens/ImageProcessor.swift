import Foundation
import CoreImage
import CoreVideo
import VitalLensCore

/// A stateless helper to handle image manipulation: Cropping, Resizing, and Raw Byte extraction.
struct ImageProcessor {
    
    // Using a shared CIContext is recommended for performance (caches intermediate textures).
    // disabling software renderer ensures we stay on the GPU.
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    
    /// Processes a video frame: Crops to the ROI, scales to the target size, and extracts raw RGB bytes.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The source video frame (usually YCbCr or BGRA).
    ///   - roi: The **normalized** region of interest (0.0 - 1.0) with **Top-Left** origin.
    ///   - targetSize: The dimension required by the API (e.g., 40 for a 40x40 image).
    /// - Returns: A `Data` object containing raw RGB bytes (flat array: R, G, B, R, G, B...).
    /// - Throws: If the image cannot be rendered.
    func process(
        pixelBuffer: CVPixelBuffer,
        roi: CGRect,
        targetSize: Int
    ) throws -> Data {
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        
        // 1. Convert Normalized Top-Left ROI to Absolute CoreImage Coordinates (Bottom-Left)
        // ROI (Top-Left): x, y, w, h
        // CI (Bottom-Left): x, height - y - h, w, h
        let cropRect = CGRect(
            x: roi.origin.x * width,
            y: (1.0 - roi.origin.y - roi.height) * height,
            width: roi.width * width,
            height: roi.height * height
        )
        
        // 2. Crop (clamped to extent)
        let croppedImage = ciImage.cropped(to: cropRect)
        
        // 3. Translate to Origin (0,0) for scaling
        let translatedImage = croppedImage.transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
        
        // 4. Scale to Target Size (e.g. 40x40)
        let scaleX = CGFloat(targetSize) / cropRect.width
        let scaleY = CGFloat(targetSize) / cropRect.height
        let scaledImage = translatedImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        // 5. Render to Intermediate RGBA Buffer (4 bytes per pixel)
        // CIContext requires 32-bit alignment (RGBA8)
        let rgbaBytesPerPixel = 4
        let rgbaRowBytes = targetSize * rgbaBytesPerPixel
        let rgbaTotalBytes = rgbaRowBytes * targetSize
        
        var rgbaData = Data(count: rgbaTotalBytes)
        
        rgbaData.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            guard let baseAddress = ptr.baseAddress else { return }
            
            context.render(
                scaledImage,
                toBitmap: baseAddress,
                rowBytes: rgbaRowBytes,
                bounds: CGRect(x: 0, y: 0, width: CGFloat(targetSize), height: CGFloat(targetSize)),
                format: .RGBA8, // Use standard 32-bit format
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
            )
        }
        
        // 6. Compact to RGB (3 bytes per pixel) for API
        // Strip the Alpha channel
        let rgbBytesPerPixel = 3
        let rgbTotalBytes = targetSize * targetSize * rgbBytesPerPixel
        var rgbData = Data(count: rgbTotalBytes)
        
        rgbData.withUnsafeMutableBytes { rgbPtr in
            rgbaData.withUnsafeBytes { rgbaPtr in
                guard let src = rgbaPtr.bindMemory(to: UInt8.self).baseAddress,
                      let dst = rgbPtr.bindMemory(to: UInt8.self).baseAddress else { return }
                
                let pixelCount = targetSize * targetSize
                var srcOffset = 0
                var dstOffset = 0
                
                for _ in 0..<pixelCount {
                    dst[dstOffset]     = src[srcOffset]     // R
                    dst[dstOffset + 1] = src[srcOffset + 1] // G
                    dst[dstOffset + 2] = src[srcOffset + 2] // B
                    // Skip Alpha (src[srcOffset + 3])
                    
                    srcOffset += 4
                    dstOffset += 3
                }
            }
        }
        
        return rgbData
    }
}